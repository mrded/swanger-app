import OrderedJSON

/// A shared fragment: a schema reached through a `$ref`, such as `#/components/schemas/Address`.
public struct FragmentRef: Hashable, Sendable, CustomStringConvertible {
  /// Where the fragment is written. For a chain of `$ref`s, such as a component that only points
  /// at a file, it's the schema at the end of the chain.
  public let id: NodeLocation
  /// The name to show: the name of the spec's component that is or points to it, the last part
  /// of the pointer, or the file's name.
  public let name: String

  public init(id: NodeLocation, name: String) {
    self.id = id
    self.name = name
  }

  public var description: String { name }
}

/// One schema, as the diagram shows it: a card for objects, arrays and choices, or a row's value.
public struct SchemaNode: Equatable, Sendable {
  public indirect enum Kind: Equatable, Sendable {
    case object(ObjectSchema)
    case array(ArraySchema)
    /// Strings, numbers, booleans and null, or any value when `types` is empty.
    case scalar(ScalarSchema)
    /// `oneOf` or `anyOf`: one branch per variant.
    case choice(ChoiceSchema)
    /// A fragment met again inside itself, such as a tree's children.
    case recursive(FragmentRef)
    /// A `$ref` that couldn't be followed.
    case unresolved(ref: String, failure: RefFailure)
    /// The `false` schema: no value is valid.
    case never
  }

  public var kind: Kind
  /// Where the schema is written.
  public var location: NodeLocation
  /// Set when this schema is a shared fragment.
  public var fragment: FragmentRef?
  /// The fragment, with extra keywords where it's used: more required fields, forbidden fields or
  /// stricter constraints.
  public var isTightened = false
  /// `null` is allowed as well as the kind's own values.
  public var allowsNull = false
  public var title: String?
  public var description: String?
  public var examples: [JSONValue] = []
  public var defaultValue: JSONValue?
  public var isDeprecated = false
  public var isReadOnly = false
  public var isWriteOnly = false
  /// Everything the value must satisfy beyond its shape, in plain English.
  public var rules: [Rule] = []

  public init(kind: Kind, location: NodeLocation) {
    self.kind = kind
    self.location = location
  }

  public var object: ObjectSchema? {
    if case .object(let object) = kind { object } else { nil }
  }

  public var array: ArraySchema? {
    if case .array(let array) = kind { array } else { nil }
  }

  public var scalar: ScalarSchema? {
    if case .scalar(let scalar) = kind { scalar } else { nil }
  }

  public var choice: ChoiceSchema? {
    if case .choice(let choice) = kind { choice } else { nil }
  }

  /// A short description of the type: `string`, `Address`, `array of Line`, `one of Card or
  /// BankTransfer`, `integer or null`. A fragment is described by its name.
  public var typeDescription: String {
    guard let fragment else { return shapeDescription }
    return allowsNull ? "\(fragment.name) or null" : fragment.name
  }

  /// The type without the fragment's name: `object` for an `Address`.
  public var shapeDescription: String {
    let base: String
    switch kind {
    case .object: base = "object"
    case .array(let array): base = array.items.map { "array of \($0.typeDescription)" } ?? "array"
    case .scalar(let scalar): base = scalar.types.isEmpty ? "any" : list(scalar.types, "or")
    case .choice(let choice):
      let mode = choice.mode == .oneOf ? "one of" : "any of"
      base = "\(mode) \(list(choice.variants.map(\.name), "or"))"
    case .recursive(let fragment): base = fragment.name
    case .unresolved: base = "unresolved"
    case .never: base = "nothing"
    }
    return allowsNull && scalar?.types.contains("null") != true ? "\(base) or null" : base
  }
}

public struct ObjectSchema: Equatable, Sendable {
  public enum AdditionalFields: Equatable, Sendable {
    /// Fields not listed are allowed, with any value.
    case allowed
    /// Only the listed fields are allowed.
    case forbidden
    /// Other fields are allowed when their value matches.
    case schema(SchemaNode)
  }

  /// In the order the schema gives them, fields from the fragments it extends first.
  public var fields: [Field]
  public var additionalFields: AdditionalFields
  /// `patternProperties`: fields whose names match a pattern.
  public var patternFields: [PatternField]

  public init(
    fields: [Field] = [],
    additionalFields: AdditionalFields = .allowed,
    patternFields: [PatternField] = []
  ) {
    self.fields = fields
    self.additionalFields = additionalFields
    self.patternFields = patternFields
  }

  public subscript(field name: String) -> Field? {
    fields.first { $0.name == name }
  }
}

public struct PatternField: Equatable, Sendable {
  public var pattern: String
  public var node: SchemaNode

  public init(pattern: String, node: SchemaNode) {
    self.pattern = pattern
    self.node = node
  }
}

public struct Field: Equatable, Sendable {
  public var name: String
  public var isRequired: Bool
  /// Listed only to say it mustn't be there, as `name: false` or `name: {not: {}}`.
  public var isForbidden: Bool
  public var node: SchemaNode
  /// The fragment the field is written in, when it's not the object's own, such as a base schema
  /// in an `allOf`.
  public var definedIn: FragmentRef?

  public init(
    name: String,
    isRequired: Bool,
    isForbidden: Bool = false,
    node: SchemaNode,
    definedIn: FragmentRef? = nil
  ) {
    self.name = name
    self.isRequired = isRequired
    self.isForbidden = isForbidden
    self.node = node
    self.definedIn = definedIn
  }

  /// The fragment the field's value is, if it's one.
  public var fragmentUsed: FragmentRef? { node.fragment }
}

public struct ArraySchema: Equatable, Sendable {
  public var items: SchemaNode?
  /// `prefixItems`: a schema for each item in turn, before `items` applies.
  public var prefixItems: [SchemaNode]

  public init(items: SchemaNode? = nil, prefixItems: [SchemaNode] = []) {
    self.items = items
    self.prefixItems = prefixItems
  }
}

public struct ScalarSchema: Equatable, Sendable {
  /// JSON types, such as `string` or `integer`. Empty means any value.
  public var types: [String]
  public var format: String?
  public var patterns: [String]
  /// `enum` or `const`.
  public var allowedValues: [JSONValue]?

  public init(
    types: [String] = [],
    format: String? = nil,
    patterns: [String] = [],
    allowedValues: [JSONValue]? = nil
  ) {
    self.types = types
    self.format = format
    self.patterns = patterns
    self.allowedValues = allowedValues
  }
}

public struct ChoiceSchema: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    /// `oneOf`: exactly one variant matches.
    case oneOf
    /// `anyOf`: at least one variant matches.
    case anyOf
  }

  public var mode: Mode
  /// The field whose value says which variant it is, such as `type`.
  public var discriminator: String?
  public var variants: [Variant]

  public init(mode: Mode, discriminator: String? = nil, variants: [Variant]) {
    self.mode = mode
    self.discriminator = discriminator
    self.variants = variants
  }
}

public struct Variant: Equatable, Sendable {
  /// The fragment's name, the discriminator value, the fields only this variant has, or its type.
  public var name: String
  public var discriminatorValue: JSONValue?
  public var node: SchemaNode

  public init(name: String, discriminatorValue: JSONValue? = nil, node: SchemaNode) {
    self.name = name
    self.discriminatorValue = discriminatorValue
    self.node = node
  }
}

/// `a`, `a or b`, `a, b or c`.
func list(_ items: [String], _ conjunction: String) -> String {
  switch items.count {
  case 0: ""
  case 1: items[0]
  default: items.dropLast().joined(separator: ", ") + " \(conjunction) " + items.last!
  }
}
