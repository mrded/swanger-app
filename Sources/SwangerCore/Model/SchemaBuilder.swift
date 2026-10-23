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
///
/// The tree is for showing the schema, not for validating against it: it may be less strict than
/// JSON Schema for rare keyword combinations, but never stricter. See
/// `docs/model-boundaries.md` before extending it.
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
  struct Part {
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
  struct Piece {
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
      // The known keywords make the shape, but it's only part of the schema.
      built.node.unresolvedRefs = pieces.unresolved.map {
        UnresolvedRef(ref: $0.ref, failure: $0.failure)
      }
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
    if facts.types == nil, facts.allowed == nil {
      facts.types = Self.conditionTypes(facts.conditions)
    }
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
    // Null has to get past both the `type` and any allowed values.
    node.allowsNull =
      kind != .never
      && (facts.types?.contains("null") ?? true)
      && (facts.allowed?.contains(.null) ?? (facts.types != nil))
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
      let general = isUnion ? facts.typeIndependent : facts.applicable
      let decisions =
        conditionRules(facts.conditions, present: Set(facts.required)) + general.dependencies()
      node.rules =
        general.constraintRules(isObject: node.object != nil) + choiceRules
        + decisions.map(\.rule)
      node.markDecidedFields(decisions)
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
      let (schema, distinguishing) = buildChoice(choice, escapes: &escapes)
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
        || !facts.patternProperties.isEmpty || facts.additionalForbidden
        || facts.unevaluated != nil)
    // `type: [object, string]` is an object or a string, each with its own keywords.
    let groups = Self.typeGroups(nonNull)
    if groups.count > 1 {
      extraChoices = besides(0..<choices.count)
      let variants = groups.map { group in
        let narrowed = facts.variant(group)
        var unused: [Rule] = []
        var none: [ChoiceSchema] = []
        let kind = makeKind(
          narrowed, home: home, location: location, escapes: &escapes, choiceRules: &unused,
          extraChoices: &none)
        var node = SchemaNode(kind: kind, location: location)
        let dependencies = narrowed.dependencies()
        node.rules =
          narrowed.constraintRules(isObject: node.object != nil) + dependencies.map(\.rule)
        node.markDecidedFields(dependencies)
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
      return .object(buildObject(facts, home: home, escapes: &escapes))
    }
    if isArray {
      var array = ArraySchema()
      if !facts.items.isEmpty {
        let built = build(facts.items)
        escapes.formUnion(built.escapes)
        array.items = built.node
      }
      for parts in facts.prefixItems {
        let built = build(parts)
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
      let parts = facts.properties[name] ?? []
      var isForbidden = facts.forbidden.contains(name)
      // A closed `allOf` member that doesn't list the field forbids it.
      if facts.closedScopes.contains(where: { scope in
        !scope.fields.contains(name)
          && !scope.patterns.contains(where: { Self.name(name, matches: $0) })
      }) {
        isForbidden = true
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
      // No value can satisfy it, so the field can only be left out, as with `false`.
      if node.kind == .never { isForbidden = true }
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

  /// A variant written as only `required`, such as `{required: [email]}`.
  private static func onlyRequires(_ member: Part) -> Bool {
    guard case .object(let object) = member.schema, object.reference == nil else { return false }
    return object.keywords.keys.allSatisfy { $0 == "required" || isAnnotation($0) }
  }

  private func buildChoice(
    _ choice: Facts.Choice,
    escapes: inout Set<NodeLocation>
  ) -> (ChoiceSchema, distinguishing: [[String]]) {
    let members = choice.members
    let nodes = members.map { member in
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

extension SchemaNode {
  /// Links each of the object's fields to the rules that require or forbid it. The rules apply
  /// to the whole value, so they reach the objects among a choice's variants too, such as the
  /// object of `type: [object, string]`.
  fileprivate mutating func markDecidedFields(_ decisions: [(rule: Rule, decides: [String])]) {
    switch kind {
    case .object(var object):
      for (rule, names) in decisions {
        for index in object.fields.indices where names.contains(object.fields[index].name) {
          object.fields[index].decidedBy.append(rule)
        }
      }
      kind = .object(object)
    case .choice(var choice):
      for index in choice.variants.indices {
        choice.variants[index].node.markDecidedFields(decisions)
      }
      kind = .choice(choice)
    case .array, .scalar, .recursive, .unresolved, .never:
      break
    }
  }
}
