import Foundation
import OrderedCollections
import OrderedJSON

/// Turns resolved schemas into ``SchemaNode`` trees.
///
/// A schema is gathered from its own keywords, the schema its `$ref` leads to and the members of
/// its `allOf`, and those pieces are merged into one node. A `$ref` (or the single member of an
/// `allOf`) with nothing beside it but annotations is a use of that fragment. When the keywords
/// beside it only tighten the fragment (more required fields, forbidden fields, stricter
/// constraints) the node is still that fragment, marked tightened. When they add fields of their own
/// it's a new object, and each field remembers the fragment it came from.
///
/// A fragment's tree is built once and shared, unless it contains a recursive reference to a
/// schema outside itself, because then its tree depends on where it's used.
final class SchemaBuilder {
  let resolver: RefResolver
  /// Every fragment met so far, in the order met.
  private(set) var fragments: OrderedDictionary<NodeLocation, FragmentRef> = [:]
  private var takenNames: [String: NodeLocation] = [:]
  private var cache: [NodeLocation: SchemaNode] = [:]
  /// The spec's component names, by the schema each one is or only points to.
  private var componentNames: [NodeLocation: String] = [:]

  init(resolver: RefResolver) {
    self.resolver = resolver
    // A component that's only a `$ref`, such as `address: {$ref: address.schema.json}`, names the
    // schema it points to. Its raw JSON is enough to tell, so unused components aren't resolved.
    let schemas = resolver.rootLocation.appending("components").appending("schemas")
    guard case .success(.object(let components)) = resolver.value(at: schemas) else { return }
    for (name, value) in components {
      var location = schemas.appending(name)
      if value.object.map({ Array($0.keys) == ["$ref"] }) == true,
        case .success(let target) = resolver.dereference(location)
      {
        location = target
      }
      if componentNames[location] == nil { componentNames[location] = name }
    }
  }

  /// The schema at `location` as a tree.
  func node(at location: NodeLocation) -> SchemaNode? {
    guard let schema = resolver.schema(at: location) else { return nil }
    return build([Part(schema: schema, definedIn: nil, path: [])]).node
  }

  /// A fragment on its own.
  func node(of fragment: FragmentRef) -> SchemaNode {
    fragmentContent(fragment.id, path: []).node
  }

  /// The schema at `location` as a fragment on its own, named and registered like one reached
  /// through a `$ref`.
  func fragmentNode(at location: NodeLocation) -> SchemaNode {
    fragmentContent(location, path: []).node
  }

  // MARK: - Parts and pieces

  /// A schema to merge into a node, with the fragment it's written in and the fragments entered
  /// on the way to it.
  private struct Part {
    var schema: ResolvedSchema
    var definedIn: FragmentRef?
    var path: [NodeLocation]
  }

  private struct Built {
    var node: SchemaNode
    /// Fragments outside this tree that it refers back to recursively. A tree with none is the
    /// same wherever it's used.
    var escapes: Set<NodeLocation> = []
  }

  /// One schema object gathered into a node.
  private struct Piece {
    let object: SchemaObject
    let definedIn: FragmentRef?
    let path: [NodeLocation]
    /// The fragment this piece was reached through, or `nil` for the node's own keywords.
    let topRef: FragmentRef?

    var isOwn: Bool { topRef == nil }
  }

  private struct Pieces {
    var list: [Piece] = []
    /// Fragments reached directly from the node's own keywords.
    var topRefs: [FragmentRef] = []
    var recursive: [FragmentRef] = []
    var unresolved: [(ref: String, failure: RefFailure)] = []
    var never = false
    var entered: Set<NodeLocation> = []
    var escapes: Set<NodeLocation> = []
  }

  // MARK: - Building

  private func build(_ parts: [Part]) -> Built {
    if let use = plainUse(parts) { return buildUse(use.reference, path: use.path, parts: parts) }
    var pieces = Pieces()
    for part in parts {
      flatten(part.schema, definedIn: part.definedIn, path: part.path, topRef: nil, into: &pieces)
    }
    return assemble(pieces, location: parts[0].schema.location)
  }

  /// When the parts are only a `$ref`, directly or as the one member of an `allOf`, plus
  /// annotations, that `$ref`.
  private func plainUse(_ parts: [Part]) -> (reference: Reference, path: [NodeLocation])? {
    var found: [(reference: Reference, path: [NodeLocation])] = []
    func isPlain(_ schema: ResolvedSchema, path: [NodeLocation]) -> Bool {
      guard case .object(let object) = schema else {
        return schema == .boolean(true, location: schema.location)
      }
      if let reference = object.reference { found.append((reference, path)) }
      for (name, keyword) in object.keywords {
        if name == "allOf", let members = keyword.schemas {
          guard members.allSatisfy({ isPlain($0, path: path) }) else { return false }
        } else if !Self.isAnnotation(name) {
          return false
        }
      }
      return true
    }
    guard parts.allSatisfy({ isPlain($0.schema, path: $0.path) }), found.count == 1 else {
      return nil
    }
    return found[0]
  }

  private func buildUse(_ reference: Reference, path: [NodeLocation], parts: [Part]) -> Built {
    var built: Built
    switch reference.target {
    case .link(let origin), .expanded(let origin, _), .recursive(let origin):
      built = fragmentContent(origin.location, path: path)
    case .unresolved(let failure):
      let kind = SchemaNode.Kind.unresolved(ref: reference.ref, failure: failure)
      built = Built(node: SchemaNode(kind: kind, location: parts[0].schema.location))
    }
    // Annotations written where the fragment is used beat the fragment's own.
    var annotations = Annotations()
    for part in parts { annotations.add(part.schema) }
    annotations.apply(to: &built.node, overriding: true)
    return built
  }

  /// The fragment at `location`, reached along `path`.
  private func fragmentContent(_ location: NodeLocation, path: [NodeLocation]) -> Built {
    switch follow(location) {
    case .unresolved(let ref, let failure):
      return Built(
        node: SchemaNode(kind: .unresolved(ref: ref, failure: failure), location: location))
    case .schema(let chain, let schema):
      let fragment = register(chain)
      if let repeated = chain.first(where: path.contains) {
        var node = SchemaNode(kind: .recursive(fragment), location: fragment.id)
        node.fragment = fragment
        return Built(node: node, escapes: [repeated])
      }
      if let cached = cache[fragment.id] { return Built(node: cached) }
      var built = build([Part(schema: schema, definedIn: fragment, path: path + chain)])
      built.node.fragment = fragment
      built.node.location = fragment.id
      built.node.isTightened = false
      built.escapes.subtract(chain)
      if built.escapes.isEmpty { cache[fragment.id] = built.node }
      return built
    }
  }

  private func flatten(
    _ schema: ResolvedSchema,
    definedIn: FragmentRef?,
    path: [NodeLocation],
    topRef: FragmentRef?,
    into pieces: inout Pieces
  ) {
    guard case .object(let object) = schema else {
      if schema != .boolean(true, location: schema.location) { pieces.never = true }
      return
    }
    if let reference = object.reference {
      switch reference.target {
      case .link(let origin), .expanded(let origin, _), .recursive(let origin):
        switch follow(origin.location) {
        case .unresolved(let ref, let failure):
          pieces.unresolved.append((ref, failure))
        case .schema(let chain, let target):
          let fragment = register(chain)
          if let repeated = chain.first(where: path.contains) {
            pieces.recursive.append(fragment)
            pieces.escapes.insert(repeated)
          } else {
            if topRef == nil { pieces.topRefs.append(fragment) }
            pieces.entered.formUnion(chain)
            flatten(
              target, definedIn: fragment, path: path + chain, topRef: topRef ?? fragment,
              into: &pieces)
          }
        }
      case .unresolved(let failure):
        pieces.unresolved.append((reference.ref, failure))
      }
    }
    pieces.list.append(Piece(object: object, definedIn: definedIn, path: path, topRef: topRef))
    for member in object["allOf"]?.schemas ?? [] {
      flatten(member, definedIn: definedIn, path: path, topRef: topRef, into: &pieces)
    }
  }

  private func assemble(_ pieces: Pieces, location: NodeLocation) -> Built {
    let structural = pieces.list.contains { piece in
      piece.object.keywords.keys.contains { $0 != "allOf" && !Self.isAnnotation($0) }
    }
    var built: Built
    if !structural, pieces.topRefs.isEmpty, let fragment = pieces.recursive.first {
      var node = SchemaNode(kind: .recursive(fragment), location: fragment.id)
      node.fragment = fragment
      built = Built(node: node)
    } else if !structural, pieces.topRefs.isEmpty, let unresolved = pieces.unresolved.first {
      let kind = SchemaNode.Kind.unresolved(ref: unresolved.ref, failure: unresolved.failure)
      built = Built(node: SchemaNode(kind: kind, location: location))
    } else if pieces.never {
      built = Built(node: SchemaNode(kind: .never, location: location))
    } else {
      built = merge(pieces, location: location)
    }
    built.escapes.formUnion(pieces.escapes)
    built.escapes.subtract(pieces.entered)

    // A fragment that's only tightened keeps its description and examples. An object that adds
    // fields of its own doesn't: a base schema's examples would be missing those fields.
    var annotations = Annotations()
    for piece in pieces.list where piece.isOwn { annotations.add(piece.object) }
    if built.node.fragment != nil {
      for piece in pieces.list where !piece.isOwn { annotations.add(piece.object) }
    }
    annotations.apply(to: &built.node, overriding: false)
    return built
  }

  private func merge(_ pieces: Pieces, location: NodeLocation) -> Built {
    var facts = Facts()
    for piece in pieces.list { facts.add(piece) }
    let home = pieces.list.first(where: \.isOwn)?.definedIn

    // The node is a fragment when it reaches exactly one, and only tightens it.
    var identity: FragmentRef?
    let topRefs = Set(pieces.topRefs)
    if topRefs.count == 1, let fragment = topRefs.first {
      let ownFields = Set(pieces.list.filter(\.isOwn).flatMap(Self.propertyNames))
      let fragmentFields = Set(
        pieces.list.filter { $0.topRef == fragment }.flatMap(Self.propertyNames))
      if ownFields.isSubset(of: fragmentFields) { identity = fragment }
    }

    var escapes: Set<NodeLocation> = []
    var choiceRules: [Rule] = []
    let kind = makeKind(
      facts, home: identity ?? home, escapes: &escapes, choiceRules: &choiceRules)
    var node = SchemaNode(kind: kind, location: identity?.id ?? location)
    node.allowsNull = facts.types?.contains("null") ?? false
    if let identity {
      node.fragment = identity
      node.isTightened = pieces.list.contains { piece in
        piece.isOwn
          && piece.object.keywords.keys.contains { $0 != "allOf" && !Self.isAnnotation($0) }
      }
    }
    node.rules =
      facts.constraintRules(isObject: node.object != nil) + choiceRules + facts.conditionRules()
      + facts.dependencyRules()
    return Built(node: node, escapes: escapes)
  }

  private func makeKind(
    _ facts: Facts,
    home: FragmentRef?,
    escapes: inout Set<NodeLocation>,
    choiceRules: inout [Rule]
  ) -> SchemaNode.Kind {
    let types = facts.types ?? []
    let nonNull = types.filter { $0 != "null" }
    let isObject =
      nonNull.contains("object") || !facts.properties.isEmpty
      || (facts.hasObjectKeywords && nonNull.isEmpty)
    let isArray = nonNull.contains("array") || (facts.hasArrayKeywords && nonNull.isEmpty)

    var choices: [ChoiceSchema] = []
    for choice in facts.choices {
      let (schema, distinguishing) = buildChoice(choice, escapes: &escapes)
      choices.append(schema)
      choiceRules += Self.choiceRules(schema, distinguishing: distinguishing)
    }
    if let choice = choices.first, facts.properties.isEmpty, !isArray {
      return .choice(choice)
    }
    if isObject {
      return .object(buildObject(facts, home: home, escapes: &escapes))
    }
    if isArray {
      var array = ArraySchema()
      if !facts.items.isEmpty {
        let built = build(facts.items)
        escapes.formUnion(built.escapes)
        array.items = built.node
      }
      for part in facts.prefixItems {
        let built = build([part])
        escapes.formUnion(built.escapes)
        array.prefixItems.append(built.node)
      }
      return .array(array)
    }
    var scalarTypes = nonNull.isEmpty && types == ["null"] ? types : nonNull
    if facts.types == nil, let allowed = facts.allowed {
      // `const: card` without a `type` is a string.
      scalarTypes = Array(OrderedSet(allowed.filter { $0 != .null }.map(\.primitive.rawValue)))
    }
    return .scalar(
      ScalarSchema(
        types: scalarTypes, format: facts.format, patterns: facts.patterns,
        allowedValues: facts.allowed))
  }

  private func buildObject(
    _ facts: Facts,
    home: FragmentRef?,
    escapes: inout Set<NodeLocation>
  ) -> ObjectSchema {
    var object = ObjectSchema()
    var names = Array(facts.properties.keys)
    names += facts.required.filter { facts.properties[$0] == nil }
    for name in names {
      let parts = facts.properties[name] ?? []
      let node: SchemaNode
      if parts.isEmpty {
        // Only required, or only forbidden: the field has no schema of its own.
        let kind: SchemaNode.Kind =
          facts.forbidden.contains(name) ? .never : .scalar(ScalarSchema())
        node = SchemaNode(kind: kind, location: home?.id ?? resolver.rootLocation)
      } else {
        let built = build(parts)
        escapes.formUnion(built.escapes)
        node = built.node
      }
      let definedIn = parts.first?.definedIn
      object.fields.append(
        Field(
          name: name, isRequired: facts.required.contains(name),
          isForbidden: facts.forbidden.contains(name), node: node,
          definedIn: definedIn == home ? nil : definedIn))
    }
    if facts.additionalForbidden {
      object.additionalFields = .forbidden
    } else if !facts.additional.isEmpty {
      let built = build(facts.additional)
      escapes.formUnion(built.escapes)
      object.additionalFields = .schema(built.node)
    }
    for (pattern, parts) in facts.patternProperties {
      let built = build(parts)
      escapes.formUnion(built.escapes)
      object.patternFields.append(PatternField(pattern: pattern, node: built.node))
    }
    return object
  }

  // MARK: - Choices

  private func buildChoice(
    _ choice: Facts.Choice,
    escapes: inout Set<NodeLocation>
  ) -> (ChoiceSchema, distinguishing: [[String]]) {
    let nodes = choice.members.map { member in
      let built = build([member])
      escapes.formUnion(built.escapes)
      return built.node
    }

    let required = nodes.map { $0.object?.fields.filter(\.isRequired).map(\.name) ?? [] }
    let shared = required.dropFirst().reduce(Set(required.first ?? [])) { $0.intersection($1) }
    let distinguishing = required.map { $0.filter { !shared.contains($0) } }

    let explicit = choice.discriminator?.object
    let property = explicit?["propertyName"]?.string ?? Self.inferDiscriminator(nodes)
    var variants: [Variant] = []
    for (index, node) in nodes.enumerated() {
      let value = property.flatMap { property in
        Self.discriminatorValue(
          of: node, member: choice.members[index], property: property,
          mapping: explicit?["mapping"]?.object, isExplicit: explicit != nil)
      }
      let name = Self.variantName(
        node, value: value, distinguishing: distinguishing[index], index: index)
      variants.append(Variant(name: name, discriminatorValue: value, node: node))
    }
    let schema = ChoiceSchema(mode: choice.mode, discriminator: property, variants: variants)
    return (schema, distinguishing)
  }

  /// The fragment's name, the discriminator value, the fields only this variant needs, or its
  /// type.
  private static func variantName(
    _ node: SchemaNode,
    value: JSONValue?,
    distinguishing: [String],
    index: Int
  ) -> String {
    if let fragment = node.fragment { return fragment.name }
    if let value { return value.string ?? Wording.literal(value) }
    if !distinguishing.isEmpty { return list(distinguishing, "and") }
    if node.object == nil { return node.typeDescription }
    return "Option \(index + 1)"
  }

  /// A field that has one fixed value in every variant, different in each.
  private static func inferDiscriminator(_ nodes: [SchemaNode]) -> String? {
    guard nodes.count > 1, let first = nodes[0].object else { return nil }
    return first.fields.map(\.name).first { name in
      let values = nodes.map { $0.object?[field: name]?.node.scalar?.allowedValues }
      guard values.allSatisfy({ $0?.count == 1 }) else { return false }
      return Set(values.compactMap { $0?.first }).count == nodes.count
    }
  }

  private static func discriminatorValue(
    of node: SchemaNode,
    member: Part,
    property: String,
    mapping: OrderedDictionary<String, JSONValue>?,
    isExplicit: Bool
  ) -> JSONValue? {
    if let values = node.object?[field: property]?.node.scalar?.allowedValues, values.count == 1 {
      return values[0]
    }
    let ref = member.schema.object?.reference?.ref
    if let mapping,
      let entry = mapping.first(where: { _, target in
        guard let target = target.string else { return false }
        return target == ref || target == node.fragment?.name
          || (node.fragment.map { target.hasSuffix("/\($0.name)") } ?? false)
      })
    {
      return .string(entry.key)
    }
    // OpenAPI's implicit mapping: the schema's name.
    if isExplicit, let fragment = node.fragment { return .string(fragment.name) }
    return nil
  }

  private static func choiceRules(_ choice: ChoiceSchema, distinguishing: [[String]]) -> [Rule] {
    if let property = choice.discriminator {
      return zip(choice.variants, distinguishing).map { variant, fields in
        let value = Wording.literal(variant.discriminatorValue ?? .string(variant.name))
        let effect: String
        if let fragment = variant.node.fragment {
          effect = "it's a \(Wording.code(fragment.name))"
        } else if case let extra = fields.filter({ $0 != property }), !extra.isEmpty {
          effect = Wording.required(extra)
        } else {
          effect = "it's the \(variant.name) option"
        }
        return Rule(.choice, "When \(Wording.code(property)) is \(value): \(effect)")
      }
    }
    let quantity = choice.mode == .oneOf ? "exactly one" : "at least one"
    if !distinguishing.isEmpty, distinguishing.allSatisfy({ !$0.isEmpty }) {
      let groups = distinguishing.map { fields in
        fields.count == 1 ? Wording.code(fields[0]) : "(\(list(fields.map(Wording.code), "and")))"
      }
      return [Rule(.choice, "Needs \(quantity) of \(list(groups, "or"))")]
    }
    return [Rule(.choice, "Must match \(quantity) of \(list(choice.variants.map(\.name), "or"))")]
  }

  // MARK: - Fragments

  private enum Followed {
    case schema(chain: [NodeLocation], ResolvedSchema)
    case unresolved(ref: String, failure: RefFailure)
  }

  /// Follows schemas that are only a `$ref`, so that a component pointing at a file is one
  /// fragment, named after the component.
  private func follow(_ start: NodeLocation) -> Followed {
    var chain = [start]
    var location = start
    while true {
      guard let schema = resolver.schema(at: location) else {
        return .unresolved(ref: location.description, failure: .missingTarget(location))
      }
      guard case .object(let object) = schema, object.keywords.isEmpty,
        let reference = object.reference
      else {
        return .schema(chain: chain, schema)
      }
      switch reference.target {
      case .link(let origin), .expanded(let origin, _), .recursive(let origin):
        guard !chain.contains(origin.location) else {
          return .unresolved(ref: reference.ref, failure: .circular)
        }
        chain.append(origin.location)
        location = origin.location
      case .unresolved(let failure):
        return .unresolved(ref: reference.ref, failure: failure)
      }
    }
  }

  /// The fragment a chain of `$ref`s leads to. It's the schema at the end of the chain, so a
  /// component and the file it points to are one fragment, named after the component.
  private func register(_ chain: [NodeLocation]) -> FragmentRef {
    let location = chain[chain.count - 1]
    if let known = fragments[location] { return known }
    var name = componentNames[location] ?? shortName(of: location)
    if let holder = takenNames[name], holder != location {
      name = resolver.origin(of: location).name
    }
    if takenNames[name] == nil { takenNames[name] = location }
    let fragment = FragmentRef(id: location, name: name)
    fragments[location] = fragment
    return fragment
  }

  /// The component name, the last part of the pointer, or the file's name without extensions.
  private func shortName(of location: NodeLocation) -> String {
    if let last = location.pointer.tokens.last { return last }
    var name = location.file.lastPathComponent
    while let dot = name.lastIndex(of: "."), dot != name.startIndex {
      name = String(name[..<dot])
    }
    return name
  }

  // MARK: - Keywords

  private static let annotations: Set<String> = [
    "$anchor", "$comment", "$defs", "$dynamicAnchor", "$id", "$schema", "contentEncoding",
    "contentMediaType", "default", "definitions", "deprecated", "description", "discriminator",
    "example", "examples", "externalDocs", "readOnly", "title", "writeOnly", "xml",
  ]

  static func isAnnotation(_ keyword: String) -> Bool {
    annotations.contains(keyword) || keyword.hasPrefix("x-")
  }

  private static func propertyNames(_ piece: Piece) -> [String] {
    Array(piece.object["properties"]?.schemaMap?.keys ?? [])
  }

  // MARK: - Facts

  /// Everything the pieces of a node say, merged.
  private struct Facts {
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
    var prefixItems: [Part] = []
    var additional: [Part] = []
    var additionalForbidden = false
    var patternProperties = OrderedDictionary<String, [Part]>()
    var choices: [Choice] = []
    var conditions: [Condition] = []
    var dependentRequired: [(field: String, requires: [String])] = []
    var nots: [ResolvedSchema] = []
    var contains: [ResolvedSchema] = []
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
      "contains", "items", "maxItems", "minItems", "prefixItems", "uniqueItems", "unevaluatedItems",
    ]

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
          if prefixItems.isEmpty { prefixItems = schemas.map(part) }
        case ("additionalProperties", .schema(let schema)),
          ("unevaluatedProperties", .schema(let schema)):
          if Self.isForbidden(schema) {
            additionalForbidden = true
          } else if case .object = schema {
            additional.append(part(schema))
          }
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
      case .object(let object): object.reference == nil && object.keywords.isEmpty
      }
    }

    /// Types both lists allow, where `integer` is a kind of `number`.
    private static func intersect(_ lhs: [String], _ rhs: [String]) -> [String] {
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
      if !contains.isEmpty { phrases.append("needs at least one item matching `contains`") }
      phrases += Self.range(minProperties, maxProperties, noun: "field")
      if isObject, additionalForbidden { phrases.append("allows no other fields") }
      // `not: {}` forbids the value altogether, which is shown on the field instead.
      phrases += nots.filter { !Self.isEmpty($0) }.map(Self.negation)
      return phrases
    }

    func constraintRules(isObject: Bool) -> [Rule] {
      constraintPhrases(isObject: isObject).map { Rule(.constraint, $0) }
    }

    func conditionRules() -> [Rule] {
      conditions.map { condition in
        var text = "When \(Self.describe(condition.condition))"
        text += ": \(condition.then.flatMap(Self.effects) ?? "nothing more is needed")"
        if let otherwise = condition.otherwise.flatMap(Self.effects) {
          text += ". Otherwise: \(otherwise)"
        }
        return Rule(.condition, text)
      }
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

    private static func negation(_ schema: ResolvedSchema) -> String {
      guard case .object(let object) = schema else { return "mustn't match `not`" }
      if let fields = object["required"]?.value?.array?.compactMap(\.string), !fields.isEmpty {
        return "mustn't have \(list(fields.map(Wording.code), "and"))"
      }
      if let values = object["enum"]?.value?.array ?? object["const"]?.value.map({ [$0] }) {
        return "mustn't be \(list(values.map(Wording.literal), "or"))"
      }
      return "mustn't match `not`"
    }

    /// The `if` schema as a condition: "`status` is "Rejected" and `reason` is present".
    private static func describe(_ condition: ResolvedSchema) -> String {
      let clauses = Self.clauses(condition, prefix: "")
      if !clauses.isEmpty { return list(clauses, "and") }
      return condition.object?["description"]?.value?.string ?? "the `if` schema matches"
    }

    private static func clauses(_ schema: ResolvedSchema, prefix: String) -> [String] {
      guard case .object(let object) = schema else { return [] }
      var clauses: [String] = []
      var mentioned: Set<String> = []
      for (name, property) in object["properties"]?.schemaMap ?? [:] {
        let path = prefix + name
        guard case .object(let inner) = property else { continue }
        if let values = inner["const"]?.value.map({ [$0] }) ?? inner["enum"]?.value?.array {
          let comparison =
            values.count == 1
            ? "is \(Wording.literal(values[0]))"
            : "is one of \(list(values.map(Wording.literal), "or"))"
          clauses.append("\(Wording.code(path)) \(comparison)")
          mentioned.insert(name)
        } else if inner["properties"] != nil {
          let nested = Self.clauses(property, prefix: path + ".")
          clauses += nested
          if !nested.isEmpty { mentioned.insert(name) }
        }
      }
      for name in object["required"]?.value?.array?.compactMap(\.string) ?? []
      where !mentioned.contains(name) {
        clauses.append("\(Wording.code(prefix + name)) is present")
      }
      return clauses
    }

    /// What a `then`, `else` or variant asks for: "`reason` is required; `note` isn't allowed".
    private static func effects(_ schema: ResolvedSchema) -> String? {
      guard case .object(let object) = schema else {
        return Self.isForbidden(schema) ? "nothing is allowed" : nil
      }
      var effects: [String] = []
      if let fields = object["required"]?.value?.array?.compactMap(\.string), !fields.isEmpty {
        effects.append(Wording.required(fields))
      }
      var forbidden: [String] = []
      for (name, property) in object["properties"]?.schemaMap ?? [:] {
        if isForbidden(property) {
          forbidden.append(name)
        } else if case .object(let inner) = property {
          var facts = Facts()
          facts.add(inner, definedIn: nil, path: [])
          effects += facts.constraintPhrases(isObject: false).map { "\(Wording.code(name)) \($0)" }
        }
      }
      if !forbidden.isEmpty { effects.append(Wording.forbidden(forbidden)) }
      var own = Facts()
      own.add(
        SchemaObject(
          location: object.location,
          keywords: object.keywords.filter { $0.key != "properties" && $0.key != "required" }),
        definedIn: nil, path: [])
      effects += own.constraintPhrases(isObject: true).map { "it \($0)" }
      return effects.isEmpty ? nil : effects.joined(separator: "; ")
    }
  }

  // MARK: - Annotations

  private struct Annotations {
    var title: String?
    var description: String?
    var examples: [JSONValue] = []
    var defaultValue: JSONValue?
    var isDeprecated = false
    var isReadOnly = false
    var isWriteOnly = false

    /// Adds a schema's annotations, and those of its `allOf` members; earlier ones win.
    mutating func add(_ schema: ResolvedSchema) {
      guard case .object(let object) = schema else { return }
      add(object)
      for member in object["allOf"]?.schemas ?? [] { add(member) }
    }

    /// Adds one schema object's annotations, without its `allOf` members.
    mutating func add(_ object: SchemaObject) {
      title = title ?? object["title"]?.value?.string
      description = description ?? object["description"]?.value?.string
      for example in object["examples"]?.value?.array ?? [] where !examples.contains(example) {
        examples.append(example)
      }
      defaultValue = defaultValue ?? object["default"]?.value
      isDeprecated = isDeprecated || object["deprecated"]?.value?.boolean == true
      isReadOnly = isReadOnly || object["readOnly"]?.value?.boolean == true
      isWriteOnly = isWriteOnly || object["writeOnly"]?.value?.boolean == true
    }

    /// With `overriding`, these annotations beat the node's own.
    func apply(to node: inout SchemaNode, overriding: Bool) {
      if overriding {
        node.title = title ?? node.title
        node.description = description ?? node.description
        node.examples = examples + node.examples.filter { !examples.contains($0) }
        node.defaultValue = defaultValue ?? node.defaultValue
      } else {
        node.title = node.title ?? title
        node.description = node.description ?? description
        node.examples += examples.filter { !node.examples.contains($0) }
        node.defaultValue = node.defaultValue ?? defaultValue
      }
      node.isDeprecated = node.isDeprecated || isDeprecated
      node.isReadOnly = node.isReadOnly || isReadOnly
      node.isWriteOnly = node.isWriteOnly || isWriteOnly
    }
  }
}
