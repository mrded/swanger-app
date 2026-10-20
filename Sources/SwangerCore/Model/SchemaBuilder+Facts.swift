import OrderedCollections
import OrderedJSON

extension SchemaBuilder {
  /// Everything the pieces of a node say, merged.
  struct Facts {
    struct Choice {
      var mode: ChoiceSchema.Mode
      var members: [Part]
      var discriminator: JSONValue?
    }

    struct Condition {
      var condition: ResolvedSchema
      var then: ResolvedSchema?
      var otherwise: ResolvedSchema?
    }

    /// `nil` when no piece says.
    var types: [String]?
    var properties = OrderedDictionary<String, [Part]>()
    var forbidden: Set<String> = []
    var required = OrderedSet<String>()
    var items: [Part] = []
    /// The schemas for each position of a tuple, from every piece.
    var prefixItems: [[Part]] = []
    var additional: [Part] = []
    var additionalForbidden = false
    /// `unevaluatedProperties`: `false` when it's `false`, `true` for a schema. Shown as a rule
    /// only; the fields it sees depend on where it's written, which isn't modelled.
    var unevaluated: Bool?
    /// Each `additionalProperties`, with the fields and patterns of the schema it's written in:
    /// it only sees those, not the fields other `allOf` members add. A `nil` part is `false`.
    var scopedAdditional: [(fields: Set<String>, patterns: [String], part: Part?)] = []
    var patternProperties = OrderedDictionary<String, [Part]>()
    var choices: [Choice] = []
    var conditions: [Condition] = []
    var dependentRequired: [(field: String, requires: [String])] = []
    var nots: [ResolvedSchema] = []
    var contains: [ResolvedSchema] = []
    var minContains: Int?
    var maxContains: Int?
    var allowed: [JSONValue]?
    var format: String?
    var patterns: [String] = []
    var minLength: Int?
    var maxLength: Int?
    var minItems: Int?
    var maxItems: Int?
    var minProperties: Int?
    var maxProperties: Int?
    var minimum: JSONNumberLiteral?
    var exclusiveMinimum: JSONNumberLiteral?
    var maximum: JSONNumberLiteral?
    var exclusiveMaximum: JSONNumberLiteral?
    var multipleOf: [JSONNumberLiteral] = []
    var uniqueItems = false
    var hasObjectKeywords = false
    var hasArrayKeywords = false

    private static let objectKeywords: Set<String> = [
      "additionalProperties", "dependentRequired", "maxProperties", "minProperties",
      "patternProperties", "properties", "propertyNames", "required", "unevaluatedProperties",
    ]
    private static let arrayKeywords: Set<String> = [
      "contains", "items", "maxContains", "maxItems", "minContains", "minItems", "prefixItems",
      "uniqueItems", "unevaluatedItems",
    ]

    /// With a `type`, these facts without the limits that only apply to other types, which JSON
    /// Schema ignores, such as `minimum` on a string. `format` stays: OpenAPI puts it on numbers.
    var applicable: Facts {
      guard let types else { return self }
      var facts = self
      if !types.contains("string") {
        facts.minLength = nil
        facts.maxLength = nil
        facts.patterns = []
      }
      if !types.contains("number"), !types.contains("integer") {
        facts.minimum = nil
        facts.exclusiveMinimum = nil
        facts.maximum = nil
        facts.exclusiveMaximum = nil
        facts.multipleOf = []
      }
      if !types.contains("array") {
        facts.minItems = nil
        facts.maxItems = nil
        facts.uniqueItems = false
        facts.contains = []
      }
      if !types.contains("object") {
        facts.minProperties = nil
        facts.maxProperties = nil
        facts.dependentRequired = []
      }
      return facts
    }

    /// The keywords for values of `types` alone, for one variant of a type union. With `nil`,
    /// the keywords for any value: allowed values, `not`, choices and conditions.
    func narrowed(to types: [String]?) -> Facts {
      var narrowed = Facts()
      guard let types else {
        narrowed.allowed = allowed
        narrowed.nots = nots
        narrowed.choices = choices
        narrowed.conditions = conditions
        return narrowed
      }
      narrowed.types = types
      if types.contains("object") {
        narrowed.properties = properties
        narrowed.forbidden = forbidden
        narrowed.required = required
        narrowed.additional = additional
        narrowed.additionalForbidden = additionalForbidden
        narrowed.unevaluated = unevaluated
        narrowed.scopedAdditional = scopedAdditional
        narrowed.patternProperties = patternProperties
        narrowed.minProperties = minProperties
        narrowed.maxProperties = maxProperties
        narrowed.dependentRequired = dependentRequired
        narrowed.hasObjectKeywords = hasObjectKeywords
      }
      if types.contains("array") {
        narrowed.items = items
        narrowed.prefixItems = prefixItems
        narrowed.contains = contains
        narrowed.minContains = minContains
        narrowed.maxContains = maxContains
        narrowed.minItems = minItems
        narrowed.maxItems = maxItems
        narrowed.uniqueItems = uniqueItems
        narrowed.hasArrayKeywords = hasArrayKeywords
      }
      if types.contains("string") {
        narrowed.format = format
        narrowed.patterns = patterns
        narrowed.minLength = minLength
        narrowed.maxLength = maxLength
      }
      if types.contains("number") || types.contains("integer") {
        narrowed.minimum = minimum
        narrowed.exclusiveMinimum = exclusiveMinimum
        narrowed.maximum = maximum
        narrowed.exclusiveMaximum = exclusiveMaximum
        narrowed.multipleOf = multipleOf
      }
      return narrowed
    }

    mutating func add(_ piece: Piece) {
      add(piece.object, definedIn: piece.definedIn, path: piece.path)
    }

    mutating func add(_ object: SchemaObject, definedIn: FragmentRef?, path: [NodeLocation]) {
      func part(_ schema: ResolvedSchema) -> Part {
        Part(schema: schema, definedIn: definedIn, path: path)
      }
      for (name, keyword) in object.keywords {
        if Self.objectKeywords.contains(name) { hasObjectKeywords = true }
        if Self.arrayKeywords.contains(name) { hasArrayKeywords = true }
        switch (name, keyword) {
        case ("type", .value(let value)):
          let named = value.string.map { [$0] } ?? value.array?.compactMap(\.string) ?? []
          types = types.map { Self.intersect($0, named) } ?? named
        case ("properties", .schemaMap(let schemas)):
          for (field, schema) in schemas {
            if Self.isForbidden(schema) {
              forbidden.insert(field)
              if properties[field] == nil { properties[field] = [] }
            } else {
              properties[field, default: []].append(part(schema))
            }
          }
        case ("required", .value(let value)):
          for field in value.array?.compactMap(\.string) ?? [] { required.append(field) }
        case ("items", .schema(let schema)):
          items.append(part(schema))
        case ("items", .schemas(let schemas)), ("prefixItems", .schemas(let schemas)):
          for (position, schema) in schemas.enumerated() {
            if position == prefixItems.count { prefixItems.append([]) }
            prefixItems[position].append(part(schema))
          }
        case ("unevaluatedProperties", .schema(let schema)):
          if Self.isForbidden(schema) {
            unevaluated = false
          } else if case .object = schema, unevaluated == nil {
            unevaluated = true
          }
        case ("additionalProperties", .schema(let schema)):
          if Self.isForbidden(schema) {
            additionalForbidden = true
          } else if case .object = schema {
            additional.append(part(schema))
          } else {
            break
          }
          scopedAdditional.append(
            (
              fields: Set(object["properties"]?.schemaMap?.keys ?? []),
              patterns: Array(object["patternProperties"]?.schemaMap?.keys ?? []),
              part: Self.isForbidden(schema) ? nil : part(schema)
            ))
        case ("patternProperties", .schemaMap(let schemas)):
          for (pattern, schema) in schemas {
            patternProperties[pattern, default: []].append(part(schema))
          }
        case ("oneOf", .schemas(let schemas)), ("anyOf", .schemas(let schemas)):
          choices.append(
            Choice(
              mode: name == "oneOf" ? .oneOf : .anyOf, members: schemas.map(part),
              discriminator: object["discriminator"]?.value))
        case ("if", .schema(let schema)):
          conditions.append(
            Condition(
              condition: schema, then: object["then"]?.schema, otherwise: object["else"]?.schema))
        case ("dependentRequired", .value(let value)):
          for (field, fields) in value.object ?? [:] {
            dependentRequired.append((field, fields.array?.compactMap(\.string) ?? []))
          }
        case ("not", .schema(let schema)):
          nots.append(schema)
        case ("contains", .schema(let schema)):
          contains.append(schema)
        case ("minContains", .value(let value)):
          minContains = Self.larger(minContains, value.integer)
        case ("maxContains", .value(let value)):
          maxContains = Self.smaller(maxContains, value.integer)
        case ("enum", .value(let value)):
          restrict(to: value.array ?? [])
        case ("const", .value(let value)):
          restrict(to: [value])
        case ("format", .value(let value)):
          format = format ?? value.string
        case ("pattern", .value(let value)):
          if let pattern = value.string { patterns.append(pattern) }
        case ("minLength", .value(let value)): minLength = Self.larger(minLength, value.integer)
        case ("maxLength", .value(let value)): maxLength = Self.smaller(maxLength, value.integer)
        case ("minItems", .value(let value)): minItems = Self.larger(minItems, value.integer)
        case ("maxItems", .value(let value)): maxItems = Self.smaller(maxItems, value.integer)
        case ("minProperties", .value(let value)):
          minProperties = Self.larger(minProperties, value.integer)
        case ("maxProperties", .value(let value)):
          maxProperties = Self.smaller(maxProperties, value.integer)
        case ("minimum", .value(let value)): minimum = Self.larger(minimum, value.numberLiteral)
        case ("exclusiveMinimum", .value(let value)):
          exclusiveMinimum = Self.larger(exclusiveMinimum, value.numberLiteral)
        case ("maximum", .value(let value)): maximum = Self.smaller(maximum, value.numberLiteral)
        case ("exclusiveMaximum", .value(let value)):
          exclusiveMaximum = Self.smaller(exclusiveMaximum, value.numberLiteral)
        case ("multipleOf", .value(let value)):
          if let number = value.numberLiteral { multipleOf.append(number) }
        case ("uniqueItems", .value(let value)):
          uniqueItems = uniqueItems || value.boolean == true
        default:
          break
        }
      }
    }

    private mutating func restrict(to values: [JSONValue]) {
      allowed = allowed.map { current in current.filter(values.contains) } ?? values
    }

    /// `false`, `{not: {}}` or `{not: true}`: nothing is allowed.
    static func isForbidden(_ schema: ResolvedSchema) -> Bool {
      switch schema {
      case .boolean(let bool, _):
        return !bool
      case .object(let object):
        guard object.reference == nil, object.keywords.count == 1,
          let not = object["not"]?.schema
        else { return false }
        return isEmpty(not)
      }
    }

    /// `true` or `{}`: anything is allowed.
    static func isEmpty(_ schema: ResolvedSchema) -> Bool {
      switch schema {
      case .boolean(let bool, _): bool
      case .object(let object):
        object.reference == nil && object.keywords.keys.allSatisfy(SchemaBuilder.isAnnotation)
      }
    }

    /// Types both lists allow, where `integer` is a kind of `number`.
    static func intersect(_ lhs: [String], _ rhs: [String]) -> [String] {
      var result = lhs.filter { rhs.contains($0) || ($0 == "integer" && rhs.contains("number")) }
      if lhs.contains("number"), rhs.contains("integer"), !result.contains("integer") {
        result.append("integer")
      }
      return result
    }

    private static func larger<T: Comparable>(_ current: T?, _ new: T?) -> T? {
      guard let new else { return current }
      return current.map { max($0, new) } ?? new
    }

    private static func smaller<T: Comparable>(_ current: T?, _ new: T?) -> T? {
      guard let new else { return current }
      return current.map { min($0, new) } ?? new
    }

    // MARK: Wording

    /// Constraints as verb phrases: "must be one of …", "allows at most 70 characters".
    func constraintPhrases(isObject: Bool) -> [String] {
      var phrases: [String] = []
      if let allowed { phrases.append(Wording.allowedValues(allowed)) }
      phrases += Self.range(minLength, maxLength, noun: "character")
      phrases += patterns.map { "must match \(Wording.code($0))" }
      if let format { phrases.append(Wording.format(format)) }
      if let minimum, let maximum {
        phrases.append("must be between \(minimum) and \(maximum)")
      } else if let minimum {
        phrases.append("must be at least \(minimum)")
      } else if let maximum {
        phrases.append("must be at most \(maximum)")
      }
      if let exclusiveMinimum { phrases.append("must be more than \(exclusiveMinimum)") }
      if let exclusiveMaximum { phrases.append("must be less than \(exclusiveMaximum)") }
      phrases += multipleOf.map { "must be a multiple of \($0)" }
      phrases += Self.range(minItems, maxItems, noun: "item")
      if uniqueItems { phrases.append("items must all be different") }
      if !contains.isEmpty {
        // `contains` alone needs one matching item; `minContains: 0` needs none.
        let least = minContains ?? 1
        let matching = "matching `contains`"
        switch (least, maxContains) {
        case (0, nil): break
        case (1, nil): phrases.append("needs at least one item \(matching)")
        case (_, nil): phrases.append("needs at least \(Wording.count(least, "item")) \(matching)")
        case (0, let most?):
          phrases.append("allows at most \(Wording.count(most, "item")) \(matching)")
        case (let least, let most?) where least == most:
          phrases.append("must have exactly \(Wording.count(least, "item")) \(matching)")
        case (let least, let most?):
          phrases.append(
            "must have between \(least) and \(Wording.count(most, "item")) \(matching)")
        }
      }
      phrases += Self.range(minProperties, maxProperties, noun: "field")
      if isObject, additionalForbidden {
        phrases.append("allows no other fields")
      }
      if isObject, let unevaluated {
        phrases.append(
          unevaluated
            ? "unevaluated fields must match `unevaluatedProperties`"
            : "allows no unevaluated fields")
      }
      phrases += nots.map(Self.negation)
      return phrases
    }

    func constraintRules(isObject: Bool) -> [Rule] {
      constraintPhrases(isObject: isObject).map { Rule(.constraint, $0) }
    }

    func dependencyRules() -> [Rule] {
      dependentRequired.filter { !$0.requires.isEmpty }.map { field, requires in
        Rule(.dependency, "When \(Wording.code(field)) is present: \(Wording.required(requires))")
      }
    }

    /// "needs at least 1 item", "allows at most 70 characters", "must be between 2 and 5 fields".
    private static func range(_ minimum: Int?, _ maximum: Int?, noun: String) -> [String] {
      // A minimum of 0 says nothing.
      switch (minimum == 0 ? nil : minimum, maximum) {
      case (let minimum?, let maximum?) where minimum == maximum:
        ["must have exactly \(Wording.count(minimum, noun))"]
      case (let minimum?, let maximum?):
        ["must have between \(minimum) and \(Wording.count(maximum, noun))"]
      case (let minimum?, nil):
        ["needs at least \(Wording.count(minimum, noun))"]
      case (nil, let maximum?):
        ["allows at most \(Wording.count(maximum, noun))"]
      case (nil, nil):
        []
      }
    }

    /// Simple wording only when one keyword says everything the negated schema does; otherwise
    /// "mustn't match `not`", which can't mislead.
    private static func negation(_ schema: ResolvedSchema) -> String {
      guard case .object(let object) = schema, object.reference == nil else {
        return "mustn't match `not`"
      }
      let keywords = object.keywords.keys.filter { !SchemaBuilder.isAnnotation($0) }
      guard keywords.count == 1 else { return "mustn't match `not`" }
      if let fields = object["required"]?.value?.array?.compactMap(\.string), !fields.isEmpty {
        // `not: {required: [a, b]}` only rules out having all of them.
        let codes = fields.map(Wording.code)
        switch codes.count {
        case 1: return "mustn't have \(codes[0])"
        case 2: return "mustn't have both \(codes[0]) and \(codes[1])"
        default: return "mustn't have all of \(list(codes, "and"))"
        }
      }
      if let values = object["enum"]?.value?.array ?? object["const"]?.value.map({ [$0] }) {
        return "mustn't be \(list(values.map(Wording.literal), "or"))"
      }
      if keywords == ["type"], let value = object["type"]?.value {
        let types = value.string.map { [$0] } ?? value.array?.compactMap(\.string) ?? []
        if !types.isEmpty { return "mustn't be \(Wording.types(types))" }
      }
      return "mustn't match `not`"
    }

  }
}
