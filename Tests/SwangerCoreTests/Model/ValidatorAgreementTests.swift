import Foundation
import OrderedCollections
import OrderedJSON
import SwangerValidation
import Testing

@testable import SwangerCore

/// Checks the model against a real JSON Schema validator, for many small schemas combined in the
/// ways that have gone wrong before: `allOf`, keywords merged into one schema, `$ref` with
/// siblings and `allOf` of `$ref`s, each as a body, a field and an array's items.
///
/// For each schema and sample value the validator accepts, the model must accept it too: its
/// type, each field, unlisted and pattern fields, tuple positions and choice variants.
@Suite struct ValidatorAgreementTests {
  /// Small schemas, one or two keywords each.
  static let atoms = [
    #"{"type":"string"}"#,
    #"{"type":"integer"}"#,
    #"{"type":"number","minimum":1}"#,
    #"{"type":"null"}"#,
    #"{"type":["string","null"]}"#,
    #"{"type":["object","string"]}"#,
    #"{"type":["array","integer"]}"#,
    #"{"type":["object","null"]}"#,
    #"{"type":"object","properties":{"a":{"type":"integer"}}}"#,
    #"{"properties":{"a":{"type":"string"}}}"#,
    #"{"properties":{"b":{"type":"string"}},"required":["b"]}"#,
    #"{"type":"object","properties":{"a":{}},"additionalProperties":false}"#,
    #"{"additionalProperties":{"type":"integer"}}"#,
    #"{"unevaluatedProperties":false}"#,
    #"{"patternProperties":{"^a":{"type":"string"}}}"#,
    #"{"type":"array","items":{"type":"string"}}"#,
    #"{"prefixItems":[{"type":"integer"}]}"#,
    #"{"prefixItems":[{"type":"string"}],"items":false}"#,
    #"{"enum":["x",1,null]}"#,
    #"{"enum":["y"]}"#,
    #"{"const":"x"}"#,
    #"{"not":{"type":"string"}}"#,
    #"{"not":{}}"#,
    #"{"not":{"type":"integer"}}"#,
    #"{"oneOf":[{"type":"string"},{"type":"integer"}]}"#,
    #"{"anyOf":[{"required":["a"]},{"required":["b"]}]}"#,
    #"{"oneOf":[{"properties":{"k":{"const":"c"}},"required":["k"]},{"properties":{"k":{"const":"d"}},"required":["k"]}]}"#,
    #"{"if":{"properties":{"a":{"const":1}}},"then":{"required":["b"]},"else":{"required":["c"]}}"#,
    #"{"maxLength":2}"#,
    #"{"minItems":1}"#,
    "true",
    "false",
  ]

  /// Values of every JSON type, with the field names, items and strings the atoms mention.
  static let samples = [
    "null", "true", "0", "1", "1.5", "2.5", #""x""#, #""y""#, #""abc""#,
    "[]", #"["x"]"#, "[1]", #"[1,"x"]"#, #"["x",1]"#,
    "{}", #"{"a":1}"#, #"{"a":"s"}"#, #"{"a":1,"b":"t"}"#, #"{"b":"t"}"#, #"{"c":1}"#,
    #"{"k":"c"}"#, #"{"k":"d"}"#, #"{"a":1,"c":1}"#, #"{"ab":"s"}"#, #"{"z":5}"#,
  ].map { try! JSONValue.parse($0) }

  /// A schema to check, written with `REF(n)` where it refers to atom `n`.
  struct Case {
    var label: String
    var schema: String
  }

  static func cases() throws -> [Case] {
    var combined: [Case] = []
    let objects = try atoms.map { atom -> OrderedDictionary<String, JSONValue>? in
      if case .object(let object) = try JSONValue.parse(atom) { object } else { nil }
    }
    for (i, a) in atoms.enumerated() {
      combined.append(Case(label: "atom \(i)", schema: a))
      for (j, b) in atoms.enumerated() {
        if i <= j {
          combined.append(Case(label: "allOf \(i) \(j)", schema: #"{"allOf":[\#(a),\#(b)]}"#))
        }
        if i < j {
          combined.append(
            Case(
              label: "allOf of refs \(i) \(j)",
              schema: #"{"allOf":[{"$ref":"REF(\#(i))"},{"$ref":"REF(\#(j))"}]}"#))
        }
        // Keywords written together in one schema, when they don't share a name.
        if i < j, let first = objects[i], let second = objects[j], !first.isEmpty,
          !second.isEmpty, Set(first.keys).isDisjoint(with: second.keys)
        {
          combined.append(
            Case(
              label: "merged \(i) \(j)",
              schema: "{\(a.dropFirst().dropLast()),\(b.dropFirst().dropLast())}"))
        }
        if i != j, let second = objects[j], !second.isEmpty {
          combined.append(
            Case(
              label: "ref \(i) with \(j)",
              schema: #"{"$ref":"REF(\#(i))",\#(b.dropFirst().dropLast())}"#))
        }
      }
    }
    var cases: [Case] = []
    for item in combined {
      cases.append(item)
      cases.append(
        Case(
          label: "field of \(item.label)",
          schema: #"{"type":"object","properties":{"f":\#(item.schema)}}"#))
      cases.append(
        Case(label: "items of \(item.label)", schema: #"{"type":"array","items":\#(item.schema)}"#))
    }
    return cases
  }

  @Test func modelAcceptsWhatTheValidatorAccepts() throws {
    let cases = try Self.cases()
    let spec = try Spec.load(try Self.writeSpec(cases))
    let validator = PayloadValidator(spec: spec)

    var rootsByOperation: [String: RootSchema] = [:]
    for root in spec.requestSchemas {
      for operation in root.operations { rootsByOperation[operation.operationId ?? ""] = root }
    }

    var disagreements: [String] = []
    var impossible: [String] = []
    for (index, item) in cases.enumerated() {
      let root = try #require(rootsByOperation["c\(index)"], "No root for \(item.label)")

      var anyValid = false
      for sample in Self.samples(for: item) {
        guard validator.isValid(sample, forSchemaAt: root.id.location) else { continue }
        anyValid = true
        if let problem = Self.problem(root.node, accepting: sample) {
          disagreements.append("\(item.label): \(sample) is valid, but \(problem)")
        }
      }
      if !anyValid, root.node.kind != .never {
        impossible.append(
          "\(item.label): no sample is valid, model says \(root.node.typeDescription)")
      }
      for rule in Self.rules(in: root.node) where rule.hasSuffix(" ") || rule.contains("  ") {
        disagreements.append("\(item.label): unfinished rule \"\(rule)\"")
      }
    }

    // Every fragment the model lists is used somewhere.
    for fragment in spec.fragments where spec.fragmentIndex.usages(of: fragment.reference).isEmpty {
      disagreements.append("fragment \(fragment.name) has no usages")
    }

    print("Checked \(cases.count) schemas against \(Self.samples.count) samples each.")
    if !impossible.isEmpty {
      print("Possibly impossible, not shown as nothing (\(impossible.count)):")
      for line in impossible.prefix(40) { print("  \(line)") }
    }
    // The whole list, for working through: the expectation only shows the start.
    try? (disagreements + ["", "Possibly impossible:"] + impossible).joined(separator: "\n")
      .write(
        to: FileManager.default.temporaryDirectory.appending(path: "validator-agreement.txt"),
        atomically: true, encoding: .utf8)
    let report = disagreements.prefix(60).joined(separator: "\n")
    #expect(disagreements.isEmpty, "\(disagreements.count) disagreements:\n\(report)")
  }

  // MARK: - Helpers

  /// The samples for a case, wrapped the way its context expects.
  private static func samples(for item: Case) -> [JSONValue] {
    if item.label.hasPrefix("field of") {
      return [.object([:])] + samples.map { .object(["f": $0]) }
    }
    if item.label.hasPrefix("items of") {
      return [.array([])] + samples.map { .array([$0]) }
    }
    return samples
  }

  /// Why the model rules `value` out, or `nil` when it allows it.
  private static func problem(_ node: SchemaNode, accepting value: JSONValue, at path: String = "")
    -> String?
  {
    let place = path.isEmpty ? "the model" : "the model at \(path)"
    if value == .null, node.allowsNull { return nil }
    // A shape from keywords alone doesn't constrain values of other types.
    if node.isShapeInferred {
      if node.object != nil, !matches(value, type: "object") { return nil }
      if node.array != nil, !matches(value, type: "array") { return nil }
    }
    for choice in node.choices
    where !choice.variants.contains(where: { problem($0.node, accepting: value) == nil }) {
      return "\(place) has no matching variant among \(choice.variants.map(\.name))"
    }
    switch node.kind {
    case .never:
      return "\(place) says nothing is valid"
    case .recursive, .unresolved:
      return nil
    case .scalar(let scalar):
      if scalar.types.isEmpty || scalar.types.contains(where: { matches(value, type: $0) }) {
        return nil
      }
      return "\(place) is \(node.typeDescription)"
    case .choice(let choice):
      if choice.variants.contains(where: { problem($0.node, accepting: value) == nil }) {
        return nil
      }
      return "\(place) is \(node.typeDescription) and no variant matches"
    case .object(let object):
      guard case .object(let fields) = value else { return "\(place) is an object" }
      for (key, item) in fields {
        let inner = path + "." + key
        if let field = object[field: key] {
          if field.isForbidden { return "\(place) forbids `\(key)`" }
          if let problem = problem(field.node, accepting: item, at: inner) { return problem }
          continue
        }
        let patterns = object.patternFields.filter { name(key, matches: $0.pattern) }
        if !patterns.isEmpty {
          for pattern in patterns {
            if let problem = problem(pattern.node, accepting: item, at: inner) { return problem }
          }
          continue
        }
        switch object.additionalFields {
        case .allowed: continue
        case .forbidden: return "\(place) allows no field `\(key)`"
        case .schema(let other):
          if let problem = problem(other, accepting: item, at: inner) { return problem }
        }
      }
      return nil
    case .array(let array):
      guard case .array(let items) = value else { return "\(place) is an array" }
      for (position, item) in items.enumerated() {
        let schema = position < array.prefixItems.count ? array.prefixItems[position] : array.items
        if let schema, let problem = problem(schema, accepting: item, at: path + "[\(position)]") {
          return problem
        }
      }
      return nil
    }
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("null", .null), ("boolean", .boolean), ("string", .string), ("number", .numberLiteral),
      ("object", .object), ("array", .array):
      true
    case ("integer", .numberLiteral(let number)): number.isInteger
    default: false
    }
  }

  private static func name(_ name: String, matches pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
  }

  private static func rules(in node: SchemaNode) -> [String] {
    var rules: [String] = []
    node.walk { node, _, _ in rules += node.rules.map(\.text) }
    return rules
  }

  /// One spec with each case as a request body, and the atoms as components.
  private static func writeSpec(_ cases: [Case]) throws -> URL {
    let paths = cases.enumerated().map { index, item in
      let schema = item.schema.replacingOccurrences(
        of: #"REF\((\d+)\)"#, with: "#/components/schemas/A$1", options: .regularExpression)
      return
        #""/c\#(index)":{"post":{"operationId":"c\#(index)","requestBody":{"content":{"application/json":{"schema":\#(schema)}}},"responses":{"204":{"description":"ok"}}}}"#
    }
    let components = atoms.enumerated().map { #""A\#($0.offset)":\#($0.element)"# }
    let text =
      #"{"openapi":"3.1.0","info":{"title":"Agreement","version":"1"},"paths":{\#(paths.joined(separator: ","))},"components":{"schemas":{\#(components.joined(separator: ","))}}}"#
    let url = FileManager.default.temporaryDirectory.appending(path: "validator-agreement.json")
    try Data(text.utf8).write(to: url)
    return url
  }
}
