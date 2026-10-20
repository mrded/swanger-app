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
  /// The spec's component names, by the schema each one is and the ones it only points to.
  private var componentNames: [NodeLocation: String] = [:]

  init(resolver: RefResolver) {
    self.resolver = resolver
    // A component that's only a `$ref`, such as `address: {$ref: address.schema.json}`, names the
    // schema it points to. The `$ref`'s text is enough to tell where that is, so no other file is
    // read and unused components cost nothing.
    let schemas = resolver.rootLocation.appending("components").appending("schemas")
    guard case .success(.object(let components)) = resolver.value(at: schemas) else { return }
    for (name, value) in components {
      var location = schemas.appending(name)
      var value = value
      var visited: Set<NodeLocation> = []
      while visited.insert(location).inserted {
        if componentNames[location] == nil { componentNames[location] = name }
        guard let object = value.object, Array(object.keys) == ["$ref"],
          let ref = object["$ref"]?.string,
          case .success(let target) = resolver.location(of: ref, from: location)
        else { break }
        location = target
        // Further hops are only followed inside the spec itself, which is already read.
        guard target.file == resolver.rootLocation.file,
          case .success(let next) = resolver.value(at: target)
        else {
          if componentNames[target] == nil { componentNames[target] = name }
          break
        }
        value = next
      }
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
    /// Every fragment merged in, including those reached through other fragments.
    var merged: OrderedSet<FragmentRef> = []
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
      // A fragment that only tightens another, like `{$ref: Name, maxLength: 10}`, is built on it.
      if let base = built.node.fragment, base != fragment, !built.node.bases.contains(base) {
        built.node.bases.insert(base, at: 0)
      }
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
            pieces.merged.append(fragment)
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
      // Still built on the fragments merged in: they're why nothing is valid.
      var node = SchemaNode(kind: .never, location: location)
      node.bases = pieces.merged.elements
      built = Built(node: node)
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
    facts.applyNegatedTypes()
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
    var extraChoices: [ChoiceSchema] = []
    let kind = makeKind(
      facts, home: identity ?? home, location: identity?.id ?? location, escapes: &escapes,
      choiceRules: &choiceRules, extraChoices: &extraChoices)
    var node = SchemaNode(kind: kind, location: identity?.id ?? location)
    node.allowsNull =
      kind != .never
      && (facts.types?.contains("null") ?? facts.allowed?.contains(.null) ?? false)
    node.choices = extraChoices
    node.bases = pieces.merged.filter { $0 != identity }.elements
    if facts.types == nil, node.object != nil || node.array != nil { node.isShapeInferred = true }
    if let identity {
      node.fragment = identity
      node.isTightened = pieces.list.contains { piece in
        piece.isOwn
          && piece.object.keywords.keys.contains { $0 != "allOf" && !Self.isAnnotation($0) }
      }
    }
    // Nothing is valid, so limits on its value would only mislead, as with a `false` schema.
    // A union's type-specific limits are on its variants.
    if kind != .never {
      let isUnion = Self.typeGroups(facts.types?.filter { $0 != "null" } ?? []).count > 1
      let general = isUnion ? facts.narrowed(to: nil) : facts
      node.rules =
        general.constraintRules(isObject: node.object != nil) + choiceRules
        + conditionRules(facts.conditions, present: Set(facts.required))
        + general.dependencyRules()
    }
    return Built(node: node, escapes: escapes)
  }

  private func makeKind(
    _ facts: Facts,
    home: FragmentRef?,
    location: NodeLocation,
    escapes: inout Set<NodeLocation>,
    choiceRules: inout [Rule],
    extraChoices: inout [ChoiceSchema]
  ) -> SchemaNode.Kind {
    // `allOf` members whose types or allowed values don't overlap, like string and integer, and
    // `not: {}` allow no value at all.
    if facts.types?.isEmpty == true || facts.allowed?.isEmpty == true
      || facts.nots.contains(where: Facts.isEmpty)
    {
      return .never
    }
    // Allowed values the `type` rules out, like `type: integer` with `enum: [a]`.
    if let types = facts.types, let allowed = facts.allowed,
      !allowed.contains(where: { value in
        let type = value.primitive.rawValue
        return types.contains(type) || (type == "integer" && types.contains("number"))
      })
    {
      return .never
    }
    let types = facts.types ?? []
    let nonNull = types.filter { $0 != "null" }
    // Object and array keywords only make an object or array when there's no `type`: JSON
    // Schema ignores `properties` on a string or null.
    let untyped = facts.types == nil
    let isObject =
      nonNull.contains("object")
      || (untyped && (!facts.properties.isEmpty || facts.hasObjectKeywords))
    let isArray = nonNull.contains("array") || (untyped && facts.hasArrayKeywords)

    var choices: [ChoiceSchema] = []
    var onlyRequire: [Bool] = []
    for choice in facts.choices {
      let (schema, distinguishing) = buildChoice(
        choice, outerTypes: facts.types, escapes: &escapes)
      // No variant can match under the outer `type`.
      if schema.variants.isEmpty { return .never }
      choices.append(schema)
      onlyRequire.append(choice.members.allSatisfy(Self.onlyRequires))
      choiceRules += Self.choiceRules(schema, distinguishing: distinguishing)
    }
    // Common fields, an array's shape or a type sit beside the variants. Variants that only
    // require fields, like "needs `email` or `phone`", are said in full by their rule.
    func besides(_ indices: Range<Int>) -> [ChoiceSchema] {
      indices.filter { !onlyRequire[$0] }.map { choices[$0] }
    }
    // Fields listed only as required, or limits on other fields, are a shape of their own.
    let hasObjectShape =
      (untyped || nonNull.contains("object"))
      && (!facts.properties.isEmpty || !facts.required.isEmpty || !facts.additional.isEmpty
        || !facts.patternProperties.isEmpty || facts.additionalForbidden)
    // `type: [object, string]` is an object or a string, each with its own keywords.
    let groups = Self.typeGroups(nonNull)
    if groups.count > 1 {
      extraChoices = besides(0..<choices.count)
      let variants = groups.map { group in
        let narrowed = facts.narrowed(to: group)
        var unused: [Rule] = []
        var none: [ChoiceSchema] = []
        let kind = makeKind(
          narrowed, home: home, location: location, escapes: &escapes, choiceRules: &unused,
          extraChoices: &none)
        var node = SchemaNode(kind: kind, location: location)
        node.rules =
          narrowed.constraintRules(isObject: node.object != nil) + narrowed.dependencyRules()
        return Variant(name: node.shapeDescription, discriminatorValue: nil, node: node)
      }
      return .choice(ChoiceSchema(mode: .oneOf, discriminator: nil, variants: variants))
    }
    if let choice = choices.first, !hasObjectShape, !isArray {
      extraChoices = besides(1..<choices.count)
      return .choice(choice)
    }
    extraChoices = besides(0..<choices.count)
    if isObject {
      let object = buildObject(facts, home: home, escapes: &escapes)
      // A field that's both required and forbidden can't be satisfied, when the `type` says
      // it's an object: otherwise values of other types still are.
      if facts.types != nil, object.fields.contains(where: { $0.isRequired && $0.isForbidden }) {
        // Object keywords don't apply to null, so a nullable one is still null.
        return nonNull.count < types.count ? .scalar(ScalarSchema(types: ["null"])) : .never
      }
      return .object(object)
    }
    if isArray {
      var array = ArraySchema()
      if !facts.items.isEmpty {
        let built = build(facts.items)
        escapes.formUnion(built.escapes)
        array.items = built.node
      }
      for (position, parts) in facts.prefixItems.enumerated() {
        let covering = facts.items.indices.filter { facts.itemsStart[$0] <= position }
        let built = build(parts + covering.map { facts.items[$0] })
        escapes.formUnion(built.escapes)
        array.prefixItems.append(built.node)
      }
      return .array(array)
    }
    var scalarTypes = nonNull.isEmpty && types == ["null"] ? types : nonNull
    if facts.types == nil, let allowed = facts.allowed {
      // `const: card` without a `type` is a string; `const: null` is null. Null beside other
      // values is the node's `allowsNull`.
      let inferred = OrderedSet(allowed.map(\.primitive.rawValue))
      let nonNull = inferred.filter { $0 != "null" }
      scalarTypes = nonNull.isEmpty ? Array(inferred) : Array(nonNull)
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
      var parts = facts.properties[name] ?? []
      var isForbidden = facts.forbidden.contains(name)
      // A field whose name matches a pattern must match the pattern's schema too.
      for (pattern, patternParts) in facts.patternProperties where Self.name(name, matches: pattern)
      {
        parts += patternParts
      }
      // A field another schema's `additionalProperties` doesn't list must match it too.
      for scope in facts.scopedAdditional
      where !scope.fields.contains(name)
        && !scope.patterns.contains(where: { Self.name(name, matches: $0) })
      {
        if let part = scope.part { parts.append(part) } else { isForbidden = true }
      }
      let node: SchemaNode
      if parts.isEmpty {
        // Only required, or only forbidden: the field has no schema of its own.
        let kind: SchemaNode.Kind = isForbidden ? .never : .scalar(ScalarSchema())
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
          isForbidden: isForbidden, node: node,
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

  /// Whether a `patternProperties` pattern matches a field name. A pattern that isn't a valid
  /// regular expression matches nothing.
  private static func name(_ name: String, matches pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
  }

  // MARK: - Choices

  /// The variants of a type union: `object` and `array` each on their own, other types together.
  /// One group means there's no union to show.
  private static func typeGroups(_ types: [String]) -> [[String]] {
    let scalars = types.filter { $0 != "object" && $0 != "array" }
    let structural = types.filter { $0 == "object" || $0 == "array" }.map { [$0] }
    return structural + (scalars.isEmpty ? [] : [scalars])
  }

  /// `node` as it can be under a `type` written beside it: the types they don't share are
  /// impossible.
  private static func restricted(_ node: SchemaNode, to types: [String]) -> SchemaNode {
    var node = node
    let allows = { (type: String) in
      types.contains(type) || (type == "integer" && types.contains("number"))
    }
    if !types.contains("null") { node.allowsNull = false }
    let outerScalars = types.filter { $0 != "object" && $0 != "array" }
    switch node.kind {
    case .object, .array:
      let shape = node.object != nil ? "object" : "array"
      guard !allows(shape) else { break }
      if node.isShapeInferred {
        // `{required: [a]}` doesn't apply to a string, so it allows any value of the outer type.
        node.isShapeInferred = false
        node.fragment = nil
        node.isTightened = false
        node.rules = []
        if !outerScalars.isEmpty {
          node.kind = .scalar(ScalarSchema(types: outerScalars))
        } else {
          node.kind = allows("array") ? .array(ArraySchema()) : .object(ObjectSchema())
        }
      } else {
        node.kind = .never
      }
    case .scalar(var scalar):
      if !scalar.types.isEmpty {
        scalar.types = Facts.intersect(scalar.types, types)
        node.kind = scalar.types.isEmpty ? .never : .scalar(scalar)
      } else if !outerScalars.isEmpty {
        // A variant of any type, like `{maxLength: 2}`, is what the outer type allows.
        scalar.types = outerScalars
        node.kind = .scalar(scalar)
      }
    case .choice(var choice):
      choice.variants = choice.variants.map { variant in
        var variant = variant
        variant.node = restricted(variant.node, to: types)
        return variant
      }.filter { $0.node.kind != .never }
      node.kind = choice.variants.isEmpty ? .never : .choice(choice)
    case .recursive, .unresolved, .never:
      break
    }
    // A nullable variant whose own shape is ruled out still allows null, when the outer type does.
    if node.kind == .never, node.allowsNull, types.contains("null") {
      node.kind = .scalar(ScalarSchema(types: ["null"]))
      node.fragment = nil
      node.isTightened = false
    }
    if node.kind == .never { node.rules = [] }
    return node
  }

  /// A variant written as only `required`, such as `{required: [email]}`.
  private static func onlyRequires(_ member: Part) -> Bool {
    guard case .object(let object) = member.schema, object.reference == nil else { return false }
    return object.keywords.keys.allSatisfy { $0 == "required" || isAnnotation($0) }
  }

  private func buildChoice(
    _ choice: Facts.Choice,
    outerTypes: [String]?,
    escapes: inout Set<NodeLocation>
  ) -> (ChoiceSchema, distinguishing: [[String]]) {
    var nodes: [SchemaNode] = []
    var members: [Part] = []
    for member in choice.members {
      let built = build([member])
      escapes.formUnion(built.escapes)
      // A variant the outer `type` rules out can never match, so it isn't shown.
      let node = outerTypes.map { Self.restricted(built.node, to: $0) } ?? built.node
      guard node.kind != .never else { continue }
      nodes.append(node)
      members.append(member)
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
          of: node, member: members[index], property: property,
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
    // The name of the component nearest the end of the chain, such as the alias that pointed
    // at a file.
    var name =
      chain.reversed().lazy.compactMap { self.componentNames[$0] }.first
      ?? shortName(of: location)
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
    /// For each of `items`, the first position it covers: after its own schema's `prefixItems`,
    /// which may be shorter than another `allOf` member's.
    var itemsStart: [Int] = []
    /// The schemas for each position of a tuple, from every piece.
    var prefixItems: [[Part]] = []
    var additional: [Part] = []
    var additionalForbidden = false
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

    /// The same facts with nothing required, for a part of a condition that may be missing.
    var withoutRequired: Facts {
      var facts = self
      facts.required = []
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
        narrowed.scopedAdditional = scopedAdditional
        narrowed.patternProperties = patternProperties
        narrowed.minProperties = minProperties
        narrowed.maxProperties = maxProperties
        narrowed.dependentRequired = dependentRequired
        narrowed.hasObjectKeywords = hasObjectKeywords
      }
      if types.contains("array") {
        narrowed.items = items
        narrowed.itemsStart = itemsStart
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

    /// `not: {type: string}` beside a `type` takes that type away, so `type: [string, null]`
    /// with `not: {type: null}` is a string.
    mutating func applyNegatedTypes() {
      guard let current = types else { return }
      var excluded: Set<String> = []
      nots.removeAll { schema in
        guard case .object(let object) = schema, object.reference == nil,
          Array(object.keywords.keys) == ["type"], let value = object["type"]?.value
        else { return false }
        let types = Set(value.string.map { [$0] } ?? value.array?.compactMap(\.string) ?? [])
        excluded.formUnion(types)
        // `number` without integers isn't a type of its own, so that `not` stays as a rule.
        return
          !(types.contains("integer") && !types.contains("number")
          && current.contains("number"))
      }
      types = current.filter { type in
        !excluded.contains(type) && !(type == "integer" && excluded.contains("number"))
      }
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
          itemsStart.append(object["prefixItems"]?.schemas?.count ?? 0)
        case ("items", .schemas(let schemas)), ("prefixItems", .schemas(let schemas)):
          for (position, schema) in schemas.enumerated() {
            if position == prefixItems.count { prefixItems.append([]) }
            prefixItems[position].append(part(schema))
          }
        case ("additionalProperties", .schema(let schema)),
          ("unevaluatedProperties", .schema(let schema)):
          if Self.isForbidden(schema) {
            additionalForbidden = true
          } else if case .object = schema {
            additional.append(part(schema))
          } else {
            break
          }
          if name == "additionalProperties" {
            scopedAdditional.append(
              (
                fields: Set(object["properties"]?.schemaMap?.keys ?? []),
                patterns: Array(object["patternProperties"]?.schemaMap?.keys ?? []),
                part: Self.isForbidden(schema) ? nil : part(schema)
              ))
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
      if isObject, additionalForbidden { phrases.append("allows no other fields") }
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

    private static func negation(_ schema: ResolvedSchema) -> String {
      guard case .object(let object) = schema else { return "mustn't match `not`" }
      if let fields = object["required"]?.value?.array?.compactMap(\.string), !fields.isEmpty {
        return "mustn't have \(list(fields.map(Wording.code), "and"))"
      }
      if let values = object["enum"]?.value?.array ?? object["const"]?.value.map({ [$0] }) {
        return "mustn't be \(list(values.map(Wording.literal), "or"))"
      }
      if Array(object.keywords.keys) == ["type"], let value = object["type"]?.value {
        let types = value.string.map { [$0] } ?? value.array?.compactMap(\.string) ?? []
        if !types.isEmpty { return "mustn't be \(Wording.types(types))" }
      }
      return "mustn't match `not`"
    }

  }

  // MARK: - Conditions

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
  private func conditionRules(_ conditions: [Facts.Condition], present: Set<String>) -> [Rule] {
    conditions.map { condition in
      var text = "When \(describe(condition.condition, present: present))"
      text += ": \(condition.then.flatMap(effects) ?? "nothing more is needed")"
      if let otherwise = condition.otherwise.flatMap(effects) {
        text += ". Otherwise: \(otherwise)"
      }
      return Rule(.condition, text)
    }
  }

  /// The `if` schema as a condition: "`status` is "Rejected" and `reason` is present".
  private func describe(_ condition: ResolvedSchema, present: Set<String>) -> String {
    let resolved = merged([condition])
    let clauses = clauses(
      resolved.facts, prefix: "", visited: resolved.visited, present: present)
    if !clauses.isEmpty { return list(clauses, "and") }
    return resolved.description ?? "the `if` schema matches"
  }

  /// `present` holds the fields known to be there. `properties` in an `if` also matches when
  /// the field is missing, so any other field is "missing or …".
  private func clauses(
    _ facts: Facts, prefix: String, visited: Set<NodeLocation>, present: Set<String>
  ) -> [String] {
    var clauses: [String] = []
    var mentioned: Set<String> = []
    let present = present.union(facts.required)
    for (name, parts) in facts.properties {
      let path = prefix + name
      let canBeMissing = !present.contains(name)
      let resolved = merged(parts.map(\.schema), visited: visited)
      let inner = resolved.facts
      if let values = inner.allowed {
        let comparison =
          values.count == 1
          ? "is \(Wording.literal(values[0]))"
          : "is one of \(list(values.map(Wording.literal), "or"))"
        clauses.append(
          "\(Wording.code(path)) \(canBeMissing ? "is missing or " : "")\(comparison)")
        mentioned.insert(name)
      } else if !inner.properties.isEmpty {
        // A missing parent matches as well, so nothing below it is known to be there.
        let nested = self.clauses(
          canBeMissing ? inner.withoutRequired : inner, prefix: path + ".",
          visited: resolved.visited, present: [])
        clauses += nested
        if !nested.isEmpty { mentioned.insert(name) }
      }
    }
    for name in facts.required where !mentioned.contains(name) {
      clauses.append("\(Wording.code(prefix + name)) is present")
    }
    return clauses
  }

  /// What a `then` or `else` asks for: "`reason` is required; `note` isn't allowed".
  private func effects(_ schema: ResolvedSchema) -> String? {
    let resolved = merged([schema])
    if resolved.rejectsAll { return "nothing is allowed" }
    let facts = resolved.facts
    var effects: [String] = []
    if !facts.required.isEmpty { effects.append(Wording.required(Array(facts.required))) }
    for (name, parts) in facts.properties where !facts.forbidden.contains(name) {
      let inner = merged(parts.map(\.schema)).facts
      var phrases = inner.constraintPhrases(isObject: false)
      // The branch's shape isn't shown anywhere else, so its type is part of what it asks for.
      if let types = inner.types { phrases.insert("must be \(Wording.types(types))", at: 0) }
      effects += phrases.map { "\(Wording.code(name)) \($0)" }
    }
    let forbidden = Array(facts.properties.keys.filter(facts.forbidden.contains))
    if !forbidden.isEmpty { effects.append(Wording.forbidden(forbidden)) }
    if let types = facts.types { effects.append("it must be \(Wording.types(types))") }
    effects += facts.constraintPhrases(isObject: true).map { "it \($0)" }
    return effects.isEmpty ? nil : effects.joined(separator: "; ")
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
