import Foundation
import JSONSchema
import SwangerCore

private typealias Pointer = SwangerCore.JSONPointer

/// Turns swift-json-schema's error tree into ``ValidationIssue``s.
///
/// Only the leaves become issues: summaries such as "`properties` failed" are explained by the
/// errors under them. Messages are worded here from the failing keyword's value in the compiled
/// document and the payload, not taken from the library. A failed `oneOf` or `anyOf` reports the
/// variant the payload was most likely meant to be, and a condition branch with a `description`
/// uses it as the message.
struct IssueReader {
  /// The compiled document, which `absoluteKeywordLocation`s point into.
  let document: JSONValue
  let payload: JSONValue

  /// An issue, with the values and types it was worded from, so a choice's variants can be
  /// compared and their issues merged.
  private struct Found {
    var issue: ValidationIssue
    var allowedValues: [JSONValue]?
    var expectedTypes: [String]?

    var kind: ValidationIssue.Kind { issue.kind }
    var pointer: Pointer { issue.pointer }
  }

  func issues(in result: ValidationResult) -> [ValidationIssue] {
    let found = (result.errors ?? []).flatMap { read($0, branch: nil) }
    return tidy(found.map(\.issue))
  }

  // MARK: - Reading the tree

  /// - Parameter branch: The `description` of the condition branch the error is inside, if any.
  private func read(_ error: ValidationError, branch: String?) -> [Found] {
    let children = error.errors ?? []
    switch error.keyword {
    case "oneOf" where !children.isEmpty, "anyOf" where !children.isEmpty:
      return choose(error, children: children, branch: branch)
    case "oneOf":
      let total = schemaValue(of: error)?.array?.count ?? 0
      let message = "matches more than one of the \(Wording.count(total, "option"))"
      return [found(.ruleNotMet, at: error, message + ", but must match exactly one", branch)]
    case "then" where !children.isEmpty, "else" where !children.isEmpty:
      let description = schemaValue(of: error)?.object?["description"]?.string
      return children.flatMap { read($0, branch: description ?? branch) }
    case "propertyNames":
      return [found(.ruleNotMet, at: error, "field names must match `propertyNames`", branch)]
    default:
      if !children.isEmpty { return children.flatMap { read($0, branch: branch) } }
      return leaf(error, branch: branch)
    }
  }

  /// The issues of the variant `payload` was most likely meant to be: the only one whose fixed
  /// values and type it has. When it has none of them, what they'd need instead.
  private func choose(
    _ error: ValidationError, children: [ValidationError], branch: String?
  ) -> [Found] {
    let depth = keywordTokens(of: error).count
    var variants: [Int: [Found]] = [:]
    for child in children {
      let tokens = keywordTokens(of: child)
      let index = tokens.count > depth ? Int(tokens[depth]) ?? -1 : -1
      variants[index, default: []] += read(child, branch: branch)
    }
    let instance = pointer(error.instanceLocation)
    // A wrong discriminator: a fixed value of one of the value's own fields.
    let wrongValue = { (found: Found) in
      found.kind == .notAllowedValue && found.allowedValues != nil
        && found.pointer.tokens.dropLast() == instance.tokens[...]
    }
    let wrongType = { (found: Found) in found.kind == .wrongType && found.pointer == instance }
    let ordered = variants.sorted { $0.key < $1.key }.map(\.value)
    // Variants that matched report nothing, so a `oneOf` with fewer failures than variants
    // matched more than one.
    let total = schemaValue(of: error)?.array?.count ?? ordered.count
    if error.keyword == "oneOf", ordered.count < total {
      let matched = total - ordered.count
      let message =
        "matches \(matched) of the \(Wording.count(total, "option")), but must match exactly one"
      return [found(.ruleNotMet, at: error, message, branch)]
    }
    let remaining = ordered.filter {
      !$0.contains(where: wrongValue) && !$0.contains(where: wrongType)
    }

    if remaining.count == 1 { return remaining[0] }
    // Only fields missing, such as `oneOf: [{required: [email]}, {required: [phone]}]`: the
    // fields it could have.
    if remaining.count > 1,
      remaining.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.kind == .missing } })
    {
      let options = remaining.map { variant in
        let names = variant.compactMap { $0.pointer.tokens.last.map(Wording.code) }
        return switch names.count {
        case 1: names[0]
        case 2: "both \(list(names, "and"))"
        default: "all of \(list(names, "and"))"
        }
      }
      let message = "needs \(list(options, "or"))"
      let issue = ValidationIssue(
        kind: .missing, pointer: remaining[0][0].pointer, message: branch ?? sentence(message))
      return [Found(issue: issue)]
    }
    if remaining.count > 1 {
      let fewest = remaining.map(\.count).min()!
      let best = remaining.filter { $0.count == fewest }
      if best.count == 1 { return best[0] }
    } else {
      let values = ordered.flatMap { $0.filter(wrongValue) }
      if !values.isEmpty, Set(values.map(\.pointer)).count == 1 {
        var allowed: [JSONValue] = []
        for value in values.flatMap({ $0.allowedValues ?? [] }) where !allowed.contains(value) {
          allowed.append(value)
        }
        let issue = ValidationIssue(
          kind: .notAllowedValue, pointer: values[0].pointer,
          message: branch ?? sentence(Wording.allowedValues(allowed)))
        return [Found(issue: issue, allowedValues: allowed)]
      }
      let types = ordered.flatMap { $0.filter(wrongType) }
      if values.isEmpty, !types.isEmpty {
        var expected: [String] = []
        for type in types.flatMap({ $0.expectedTypes ?? [] }) where !expected.contains(type) {
          expected.append(type)
        }
        let issue = ValidationIssue(
          kind: .wrongType, pointer: instance,
          message: branch ?? typeMessage(expected: expected, at: instance))
        return [Found(issue: issue, expectedTypes: expected)]
      }
    }
    let count = Wording.count(ordered.count, "option")
    let message =
      error.keyword == "oneOf"
      ? "must match exactly one of the \(count)" : "must match at least one of the \(count)"
    return [found(.ruleNotMet, at: error, message, branch)]
  }

  // MARK: - Leaves

  private func leaf(_ error: ValidationError, branch: String?) -> [Found] {
    let value = schemaValue(of: error)
    let instance = pointer(error.instanceLocation)
    let number = value?.numberLiteral?.rawValue ?? ""
    func issue(_ kind: ValidationIssue.Kind, _ message: String) -> [Found] {
      [found(kind, at: error, message, branch)]
    }

    switch error.keyword {
    case "type":
      let expected = value?.string.map { [$0] } ?? value?.array?.compactMap(\.string) ?? []
      let issue = ValidationIssue(
        kind: .wrongType, pointer: instance,
        message: branch ?? typeMessage(expected: expected, at: instance))
      return [Found(issue: issue, expectedTypes: expected)]
    case "enum", "const":
      let allowed = error.keyword == "const" ? value.map { [$0] } ?? [] : value?.array ?? []
      let issue = ValidationIssue(
        kind: .notAllowedValue, pointer: instance,
        message: branch ?? sentence(Wording.allowedValues(allowed)))
      return [Found(issue: issue, allowedValues: allowed)]
    case "format":
      return issue(.wrongFormat, Wording.format(value?.string ?? ""))
    case "pattern":
      return issue(.wrongFormat, "must match \(Wording.code(value?.string ?? ""))")
    case "minLength":
      return issue(.outOfRange, "needs at least \(count(value, "character"))")
    case "maxLength":
      return issue(.outOfRange, "allows at most \(count(value, "character"))")
    case "minimum":
      return issue(.outOfRange, "must be at least \(number)")
    case "maximum":
      return issue(.outOfRange, "must be at most \(number)")
    case "exclusiveMinimum":
      return issue(.outOfRange, "must be more than \(number)")
    case "exclusiveMaximum":
      return issue(.outOfRange, "must be less than \(number)")
    case "multipleOf":
      return issue(.outOfRange, "must be a multiple of \(number)")
    case "minItems":
      return issue(.outOfRange, "needs at least \(count(value, "item"))")
    case "maxItems":
      return issue(.outOfRange, "allows at most \(count(value, "item"))")
    case "minProperties":
      return issue(.outOfRange, "needs at least \(count(value, "field"))")
    case "maxProperties":
      return issue(.outOfRange, "allows at most \(count(value, "field"))")
    case "uniqueItems":
      return issue(.ruleNotMet, "items must all be different")
    case "contains":
      return issue(.ruleNotMet, "needs at least one item matching `contains`")
    case "minContains":
      return issue(.ruleNotMet, "needs at least \(count(value, "item")) matching `contains`")
    case "maxContains":
      return issue(.ruleNotMet, "allows at most \(count(value, "item")) matching `contains`")
    case "required":
      let present = payload(at: instance)?.object
      return (value?.array ?? []).compactMap(\.string).filter { present?[$0] == nil }.map {
        missing($0, in: instance, Wording.required([$0]), branch)
      }
    case "dependentRequired":
      let present = payload(at: instance)?.object ?? [:]
      var found: [Found] = []
      for (key, names) in value?.object ?? [:] where present[key] != nil {
        for name in names.array?.compactMap(\.string) ?? [] where present[name] == nil {
          let message = "\(Wording.required([name])) when \(Wording.code(key)) is present"
          found.append(missing(name, in: instance, message, branch))
        }
      }
      return found
    case "not":
      return issue(.ruleNotMet, notMessage(value))
    case "boolean":
      return falseSchema(error, branch: branch)
    default:
      return issue(.ruleNotMet, error.message.isEmpty ? "isn't valid here" : error.message)
    }
  }

  /// The `false` schema, worded by where it is: a field that isn't allowed, an extra array item,
  /// or nothing allowed at all.
  private func falseSchema(_ error: ValidationError, branch: String?) -> [Found] {
    // `$ref` and `allOf` apply in place, so `{allOf: [false]}` or a `$ref` to `false` mean the
    // same as `false` where they're written.
    var tokens = keywordTokens(of: error)[...]
    while let last = tokens.last {
      if last == "$ref" {
        tokens.removeLast()
      } else if tokens.count >= 2, tokens[tokens.endIndex - 2] == "allOf", Int(last) != nil {
        tokens.removeLast(2)
      } else {
        break
      }
    }
    let last = tokens.last
    let parent = tokens.count >= 2 ? tokens[tokens.endIndex - 2] : nil
    let name = pointer(error.instanceLocation).tokens.last ?? ""
    if last == "additionalProperties" || last == "unevaluatedProperties"
      || parent == "properties" || parent == "patternProperties"
    {
      return [found(.unexpectedField, at: error, Wording.forbidden([name]), branch)]
    }
    if last == "items" || last == "unevaluatedItems" || parent == "prefixItems" {
      return [found(.unexpectedField, at: error, "there are more items than allowed", branch)]
    }
    return [found(.ruleNotMet, at: error, "nothing is allowed here", branch)]
  }

  // MARK: - Wording

  /// "Must be a string or null, not a number".
  private func typeMessage(expected: [String], at instance: Pointer) -> String {
    let actual: String
    switch payload(at: instance) {
    case .null, nil: actual = "null"
    case .boolean: actual = "boolean"
    case .string: actual = "string"
    case .numberLiteral: actual = "number"
    case .array: actual = "array"
    case .object: actual = "object"
    }
    return sentence("must be \(Wording.types(expected)), not \(Wording.types([actual]))")
  }

  /// "mustn't have `a`", "mustn't be null", or "mustn't match `not`" when it's more than one
  /// simple keyword.
  private func notMessage(_ schema: JSONValue?) -> String {
    guard let keywords = schema?.object, keywords.count == 1,
      let (name, value) = keywords.elements.first
    else { return "mustn't match `not`" }
    switch name {
    case "required":
      let names = value.array?.compactMap(\.string).map(Wording.code) ?? []
      if names.count == 1 { return "mustn't have \(names[0])" }
      if !names.isEmpty { return "mustn't have all of \(list(names, "and"))" }
    case "type":
      let types = value.string.map { [$0] } ?? value.array?.compactMap(\.string) ?? []
      if !types.isEmpty { return "mustn't be \(Wording.types(types))" }
    case "const":
      return "mustn't be \(Wording.literal(value))"
    case "enum":
      if let values = value.array, !values.isEmpty {
        return "mustn't be \(list(values.map(Wording.literal), "or"))"
      }
    default:
      break
    }
    return "mustn't match `not`"
  }

  private func count(_ value: JSONValue?, _ noun: String) -> String {
    let raw = value?.numberLiteral?.rawValue ?? "?"
    return Int(raw).map { Wording.count($0, noun) } ?? "\(raw) \(noun)s"
  }

  /// "must be a string" as "Must be a string".
  private func sentence(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }

  private func found(
    _ kind: ValidationIssue.Kind, at error: ValidationError, _ message: String, _ branch: String?
  ) -> Found {
    Found(
      issue: ValidationIssue(
        kind: kind, pointer: pointer(error.instanceLocation),
        message: branch ?? sentence(message)))
  }

  private func missing(_ name: String, in object: Pointer, _ message: String, _ branch: String?)
    -> Found
  {
    Found(
      issue: ValidationIssue(
        kind: .missing, pointer: object.appending(name), message: branch ?? sentence(message)))
  }

  // MARK: - Tidying

  /// One wrong type per place, and nothing else wrong with a value of the wrong type; no
  /// repeats; in the order the payload gives its fields, a missing field where its object is.
  private func tidy(_ issues: [ValidationIssue]) -> [ValidationIssue] {
    var seen: Set<ValidationIssue> = []
    var wrongTypes: Set<Pointer> = []
    for issue in issues where issue.kind == .wrongType { wrongTypes.insert(issue.pointer) }
    var typeReported: Set<Pointer> = []
    let kept = issues.filter { issue in
      if wrongTypes.contains(issue.pointer) {
        guard issue.kind == .wrongType, typeReported.insert(issue.pointer).inserted else {
          return false
        }
      }
      return seen.insert(issue).inserted
    }

    var order: [Pointer: Int] = [:]
    func number(_ value: JSONValue, at pointer: Pointer) {
      order[pointer] = order.count
      switch value {
      case .object(let object):
        for (key, child) in object { number(child, at: pointer.appending(key)) }
      case .array(let array):
        for (index, child) in array.enumerated() { number(child, at: pointer.appending(index)) }
      default:
        break
      }
    }
    number(payload, at: .root)
    let position = { (issue: ValidationIssue) in
      order[issue.pointer] ?? order[Pointer(tokens: issue.pointer.tokens.dropLast())] ?? 0
    }
    return kept.enumerated().sorted {
      (position($0.element), $0.offset) < (position($1.element), $1.offset)
    }.map(\.element)
  }

  // MARK: - Locations

  private func pointer(_ location: JSONSchema.JSONPointer) -> Pointer {
    Pointer(location.jsonPointerString) ?? .root
  }

  /// The path through the schemas that led to the error, `$ref`s included.
  private func keywordTokens(of error: ValidationError) -> [String] {
    pointer(error.keywordLocation).tokens
  }

  /// The failing keyword's value: where the error's absolute location points in the document.
  private func schemaValue(of error: ValidationError) -> JSONValue? {
    guard let fragment = error.absoluteKeywordLocation?.fragment(percentEncoded: false),
      let location = Pointer(fragment)
    else { return nil }
    return location.value(in: document)
  }

  private func payload(at pointer: Pointer) -> JSONValue? {
    pointer.value(in: payload)
  }
}
