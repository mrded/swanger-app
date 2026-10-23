import OrderedCollections
import OrderedJSON

/// Wording `if`/`then`/`else` as rules.
///
/// Only the common, flat shape is worded: an `if` that checks fields' fixed values, types or
/// presence, and branches that require, forbid or limit fields. Anything else (a `$ref`, `allOf`,
/// nested fields, choices) falls back to the condition's description or a generic phrase, which
/// can't mislead.
extension SchemaBuilder {
  /// `present` holds the fields the object itself requires, which a condition can't find missing.
  func conditionRules(_ conditions: [Facts.Condition], present: Set<String>) -> [Rule] {
    conditions.map { condition in
      var text = "When \(describe(condition.condition, present: present))"
      // The value's own checks, such as "it's a number", needn't be said again by `then`.
      let checked = Self.flatFacts(condition.condition, allowing: Self.valueChecks)?.types
      let then = condition.then.flatMap { effects($0, branch: "then", checked: checked) }
      text += ": \(then ?? "nothing more is needed")"
      if let otherwise = condition.otherwise.flatMap({ effects($0, branch: "else") }) {
        text += ". Otherwise: \(otherwise)"
      }
      return Rule(.condition, text)
    }
  }

  /// The `if` schema as a condition: "`status` is "Rejected" and `reason` is present".
  ///
  /// `properties` in an `if` also matches when the field is missing, so a field the object
  /// doesn't require is "missing or …".
  private func describe(_ condition: ResolvedSchema, present: Set<String>) -> String {
    let fallback = condition.object?["description"]?.value?.string ?? "the `if` schema matches"
    if let value = Self.flatFacts(condition, allowing: Self.valueChecks) {
      if let values = value.allowed {
        return values.count == 1
          ? "it's \(Wording.literal(values[0]))"
          : "it's one of \(list(values.map(Wording.literal), "or"))"
      }
      if let types = value.types { return "it's \(Wording.types(types))" }
    }
    guard let facts = Self.flatFacts(condition, allowing: ["properties", "required", "type"]),
      facts.types.map({ $0 == ["object"] }) ?? true
    else { return fallback }
    let present = present.union(facts.required)
    var clauses: [String] = []
    for (name, parts) in facts.properties {
      let path = Wording.code(name)
      if facts.forbidden.contains(name) {
        clauses.append("\(path) is missing")
        continue
      }
      guard parts.count == 1,
        let field = Self.flatFacts(parts[0].schema, allowing: ["const", "enum", "type"])
      else { return fallback }
      let check: String
      if let values = field.allowed {
        check =
          values.count == 1
          ? "is \(Wording.literal(values[0]))"
          : "is one of \(list(values.map(Wording.literal), "or"))"
      } else if let types = field.types {
        check = "is \(Wording.types(types))"
      } else {
        if facts.required.contains(name) { clauses.append("\(path) is present") }
        continue
      }
      clauses.append("\(path) \(present.contains(name) ? "" : "is missing or ")\(check)")
    }
    for name in facts.required where facts.properties[name] == nil {
      clauses.append("\(Wording.code(name)) is present")
    }
    return clauses.isEmpty ? fallback : list(clauses, "and")
  }

  /// What a `then` or `else` asks for: "`reason` is required; `note` isn't allowed". `nil` when
  /// it asks for nothing; when it asks for something this can't word, "the `then` schema applies".
  /// `checked` is the types the `if` has already said the value has.
  private func effects(
    _ schema: ResolvedSchema, branch: String, checked: [String]? = nil
  ) -> String? {
    if Facts.isForbidden(schema) { return "nothing is allowed" }
    let cantWord = "the `\(branch)` schema applies"
    // Limits on the value itself, such as `{type: number, exclusiveMinimum: 0}`.
    if let value = Self.flatFacts(schema, allowing: Self.limits) {
      var phrases = value.applicable.constraintPhrases(isObject: false)
      if let types = value.types, types != checked {
        phrases.insert("must be \(Wording.types(types))", at: 0)
      }
      return phrases.isEmpty ? nil : phrases.joined(separator: "; ")
    }
    guard let facts = Self.flatFacts(schema, allowing: ["properties", "required", "type"]),
      facts.types.map({ $0 == ["object"] }) ?? true
    else { return cantWord }
    var effects: [String] = []
    if !facts.required.isEmpty { effects.append(Wording.required(Array(facts.required))) }
    for (name, parts) in facts.properties where !facts.forbidden.contains(name) {
      guard parts.count == 1, let field = Self.flatFacts(parts[0].schema, allowing: Self.limits)
      else { return cantWord }
      var phrases = field.applicable.constraintPhrases(isObject: false)
      if let types = field.types { phrases.insert("must be \(Wording.types(types))", at: 0) }
      effects += phrases.map { "\(Wording.code(name)) \($0)" }
    }
    let forbidden = facts.properties.keys.filter(facts.forbidden.contains)
    if !forbidden.isEmpty { effects.append(Wording.forbidden(Array(forbidden))) }
    return effects.isEmpty ? nil : effects.joined(separator: "; ")
  }

  /// Keywords an `if` can check the value itself with.
  private static let valueChecks: Set<String> = ["const", "enum", "type"]

  /// The types a value can have when every condition has both branches, each limiting the
  /// value's type: a valid value matches one branch of each. `nil` when they don't say.
  static func conditionTypes(_ conditions: [Facts.Condition]) -> [String]? {
    var result: [String]?
    for condition in conditions {
      guard let then = condition.then.flatMap(branchTypes),
        let otherwise = condition.otherwise.flatMap(branchTypes)
      else { continue }
      var union = Array(OrderedSet(then + otherwise))
      // Every integer is a number.
      if union.contains("number") { union.removeAll { $0 == "integer" } }
      result = result.map { Facts.intersect($0, union) } ?? union
    }
    return result
  }

  /// The types a branch allows, from its own `type`, `enum` or `const`: `[]` when it allows
  /// nothing, `nil` when it doesn't say or is more than one inline schema.
  private static func branchTypes(_ schema: ResolvedSchema) -> [String]? {
    if Facts.isForbidden(schema) { return [] }
    guard case .object(let object) = schema, object.reference == nil else { return nil }
    var facts = Facts()
    facts.add(object, definedIn: nil, path: [])
    if let allowed = facts.allowed {
      return Array(OrderedSet(allowed.map(\.primitive.rawValue)))
    }
    return facts.types
  }

  /// Keywords that limit a single value, worded by ``Facts/constraintPhrases(isObject:)``.
  private static let limits: Set<String> = [
    "const", "enum", "exclusiveMaximum", "exclusiveMinimum", "format", "maxItems", "maxLength",
    "maximum", "minItems", "minLength", "minimum", "multipleOf", "pattern", "type", "uniqueItems",
  ]

  /// The facts of a schema written inline with only `allowing` keywords besides annotations;
  /// `nil` for anything else, such as a `$ref` or an `allOf`.
  private static func flatFacts(_ schema: ResolvedSchema, allowing: Set<String>) -> Facts? {
    guard case .object(let object) = schema, object.reference == nil,
      object.keywords.keys.allSatisfy({ allowing.contains($0) || isAnnotation($0) })
    else { return nil }
    var facts = Facts()
    facts.add(object, definedIn: nil, path: [])
    return facts
  }
}
