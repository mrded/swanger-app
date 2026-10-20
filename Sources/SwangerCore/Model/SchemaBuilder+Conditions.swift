import OrderedJSON

/// Wording `if`/`then`/`else` as rules.
extension SchemaBuilder {
  /// A schema read for its wording only: its keywords, its `$ref` target's and its `allOf`
  /// members', merged. Fragments met aren't registered, since no node is built for them.
  private struct Resolved {
    var facts = Facts()
    var description: String?
    var rejectsAll = false
    /// The `$ref` targets merged in, and those already merged on the way here.
    var visited: Set<NodeLocation> = []
  }

  /// `visited` holds the `$ref` targets already merged on the way here, which aren't merged
  /// again, so a recursive schema such as a tree ends.
  private func merged(_ schemas: [ResolvedSchema], visited: Set<NodeLocation> = []) -> Resolved {
    var result = Resolved()
    var visited = visited
    func add(_ schema: ResolvedSchema) {
      guard case .object(let object) = schema else {
        if Facts.isForbidden(schema) { result.rejectsAll = true }
        return
      }
      if Facts.isForbidden(schema) { result.rejectsAll = true }
      result.description = result.description ?? object["description"]?.value?.string
      result.facts.add(object, definedIn: nil, path: [])
      if let reference = object.reference {
        switch reference.target {
        case .expanded(let origin, let target) where visited.insert(origin.location).inserted:
          add(target)
        case .link(let origin), .recursive(let origin):
          if visited.insert(origin.location).inserted,
            let target = resolver.schema(at: origin.location)
          {
            add(target)
          }
        case .expanded, .unresolved:
          break
        }
      }
      for member in object["allOf"]?.schemas ?? [] { add(member) }
    }
    schemas.forEach(add)
    result.visited = visited
    return result
  }

  /// `present` holds the fields the object itself requires, which a condition can't find missing.
  func conditionRules(_ conditions: [Facts.Condition], present: Set<String>) -> [Rule] {
    conditions.map { condition in
      var text = "When \(describe(condition.condition, present: present))"
      let then = condition.then.flatMap { effects($0, branch: "then") }
      text += ": \(then ?? "nothing more is needed")"
      if let otherwise = condition.otherwise.flatMap({ effects($0, branch: "else") }) {
        text += ". Otherwise: \(otherwise)"
      }
      return Rule(.condition, text)
    }
  }

  /// The `if` schema as a condition: "`status` is "Rejected" and `reason` is present".
  private func describe(_ condition: ResolvedSchema, present: Set<String>) -> String {
    let resolved = merged([condition])
    if let clauses = clauses(
      resolved.facts, prefix: "", visited: resolved.visited, present: present),
      !clauses.isEmpty
    {
      return list(clauses, "and")
    }
    return resolved.description ?? "the `if` schema matches"
  }

  /// The `if` schema's checks, field by field: "`status` is "Rejected"", "`amount` is at least
  /// 100". `nil` when it has a check this can't word, so a condition is never shown as matching
  /// more than it does.
  ///
  /// `present` holds the fields known to be there. `properties` in an `if` also matches when
  /// the field is missing, so any other field is "missing or …". With `ownChecked`, the checks on
  /// the object itself were already worded by its parent.
  private func clauses(
    _ facts: Facts, prefix: String, visited: Set<NodeLocation>, present: Set<String>,
    ownChecked: Bool = false
  ) -> [String]? {
    // Of the checks on the object itself, only `type: object` goes without saying.
    guard facts.choices.isEmpty, facts.conditions.isEmpty, facts.patternProperties.isEmpty,
      facts.additional.isEmpty, facts.unevaluated == nil, facts.dependentRequired.isEmpty
    else { return nil }
    if !ownChecked {
      guard facts.types.map({ $0 == ["object"] }) ?? true, Self.ownChecks(facts).isEmpty else {
        return nil
      }
    }
    var clauses: [String] = []
    var mentioned: Set<String> = []
    let present = present.union(facts.required)
    for (name, parts) in facts.properties {
      let path = Wording.code(prefix + name)
      let canBeMissing = !present.contains(name)
      let resolved = merged(parts.map(\.schema), visited: visited)
      if facts.forbidden.contains(name) || resolved.rejectsAll {
        clauses.append("\(path) is missing")
        mentioned.insert(name)
        continue
      }
      let inner = resolved.facts
      guard inner.choices.isEmpty, inner.conditions.isEmpty, inner.dependentRequired.isEmpty
      else { return nil }
      var checks: [String] = []
      if let values = inner.allowed {
        checks.append(
          values.count == 1
            ? "is \(Wording.literal(values[0]))"
            : "is one of \(list(values.map(Wording.literal), "or"))")
      } else if let types = inner.types, types != ["object"] || inner.properties.isEmpty {
        checks.append("is \(Wording.types(types))")
      }
      for phrase in Self.ownChecks(inner) {
        guard let check = Self.conditionCheck(phrase) else { return nil }
        checks.append(check)
      }
      if !checks.isEmpty {
        clauses.append(
          "\(path) \(canBeMissing ? "is missing or " : "")\(checks.joined(separator: " and "))")
        mentioned.insert(name)
      }
      if !inner.properties.isEmpty || !inner.required.isEmpty {
        // A missing parent matches as well, which makes a field required below it "parent is
        // missing or child is present". That isn't worded: the condition falls back to its
        // description. Checks below it are already "missing or …".
        guard !(canBeMissing && !inner.required.isEmpty),
          let nested = self.clauses(
            inner, prefix: prefix + name + ".", visited: resolved.visited, present: [],
            ownChecked: true)
        else { return nil }
        clauses += nested
        if !nested.isEmpty { mentioned.insert(name) }
      }
    }
    for name in facts.required where !mentioned.contains(name) {
      clauses.append("\(Wording.code(prefix + name)) is present")
    }
    return clauses
  }

  /// The constraint phrases for a schema's own value, without its allowed values and fields.
  private static func ownChecks(_ facts: Facts) -> [String] {
    var own = facts
    own.allowed = nil
    own.properties = [:]
    own.required = []
    own.forbidden = []
    return own.constraintPhrases(
      isObject: facts.types?.contains("object") ?? !facts.properties.isEmpty)
  }

  /// A constraint phrase as a check in a condition: "must be at least 100" is "is at least 100".
  /// `nil` for a phrase with no such wording.
  private static func conditionCheck(_ phrase: String) -> String? {
    let rewordings = [
      ("must be ", "is "), ("must have ", "has "), ("needs at least ", "has at least "),
      ("allows at most ", "has at most "), ("must match `", "matches `"), ("mustn't be ", "isn't "),
      ("mustn't have ", "doesn't have "), ("allows no other fields", "has no other fields"),
      ("items must all be different", "has items that are all different"),
    ]
    for (from, to) in rewordings where phrase.hasPrefix(from) {
      return to + phrase.dropFirst(from.count)
    }
    return nil
  }

  /// What a `then` or `else` asks for: "`reason` is required; `note` isn't allowed". `nil` when
  /// it asks for nothing; when it asks for something this can't word, "the `then` schema applies"
  /// rather than nothing.
  private func effects(_ schema: ResolvedSchema, branch: String) -> String? {
    let resolved = merged([schema])
    if resolved.rejectsAll { return "nothing is allowed" }
    guard let effects = effectPhrases(resolved.facts, prefix: "", visited: resolved.visited)
    else { return "the `\(branch)` schema applies" }
    return effects.isEmpty ? nil : effects.joined(separator: "; ")
  }

  /// A branch's requirements, field by field and into nested fields as `address.zip`. `nil` for
  /// one with a check this can't word. With a `prefix`, the object's own checks were already
  /// worded by its parent.
  private func effectPhrases(_ facts: Facts, prefix: String, visited: Set<NodeLocation>)
    -> [String]?
  {
    guard facts.choices.isEmpty, facts.conditions.isEmpty, facts.patternProperties.isEmpty,
      facts.additional.isEmpty, facts.unevaluated == nil
    else { return nil }
    var effects: [String] = []
    if !facts.required.isEmpty {
      effects.append(Wording.required(facts.required.map { prefix + $0 }))
    }
    var forbidden: [String] = []
    for (name, parts) in facts.properties {
      let resolved = merged(parts.map(\.schema), visited: visited)
      if facts.forbidden.contains(name) || resolved.rejectsAll {
        forbidden.append(prefix + name)
        continue
      }
      let inner = resolved.facts
      var phrases = inner.constraintPhrases(isObject: !inner.properties.isEmpty)
      // The branch's shape isn't shown anywhere else, so its type is part of what it asks for.
      if let types = inner.types, types != ["object"] || inner.properties.isEmpty {
        phrases.insert("must be \(Wording.types(types))", at: 0)
      }
      effects += phrases.map { "\(Wording.code(prefix + name)) \($0)" }
      if !inner.properties.isEmpty || !inner.required.isEmpty || !inner.choices.isEmpty
        || !inner.conditions.isEmpty || !inner.dependentRequired.isEmpty
      {
        guard
          let nested = effectPhrases(
            inner, prefix: prefix + name + ".", visited: resolved.visited)
        else { return nil }
        effects += nested
      }
    }
    if !forbidden.isEmpty { effects.append(Wording.forbidden(forbidden)) }
    for (field, requires) in facts.dependentRequired where !requires.isEmpty {
      effects.append(
        "when \(Wording.code(prefix + field)) is present, "
          + Wording.required(requires.map { prefix + $0 }))
    }
    if prefix.isEmpty {
      if let types = facts.types { effects.append("it must be \(Wording.types(types))") }
      effects += facts.constraintPhrases(isObject: true).map { "it \($0)" }
    }
    return effects
  }
}
