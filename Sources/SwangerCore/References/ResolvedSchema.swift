import OrderedCollections
import OrderedJSON

/// A schema with its `$ref`s followed.
///
/// ``RefResolver/schema(at:)`` gives the graph form, where each `$ref` is a
/// ``Reference/Target/link(_:)`` to a schema resolved separately, so a fragment used in many
/// places is resolved once. ``RefResolver/expandedSchema(at:)`` gives the tree form, where links
/// are replaced by the schemas they point to and a schema met again on its own path is
/// ``Reference/Target/recursive(_:)``.
public indirect enum ResolvedSchema: Equatable, Sendable {
  /// The `true` schema (anything is valid) or the `false` schema (nothing is).
  case boolean(Bool, location: NodeLocation)
  case object(SchemaObject)

  public var location: NodeLocation {
    switch self {
    case .boolean(_, let location): location
    case .object(let object): object.location
    }
  }

  public var object: SchemaObject? {
    if case .object(let object) = self { object } else { nil }
  }

  /// Calls `visit` with the origin of every link in this schema and its subschemas, without
  /// following them.
  func forEachLink(_ visit: (SchemaOrigin) -> Void) {
    guard case .object(let object) = self else { return }
    if case .link(let origin) = object.reference?.target { visit(origin) }
    for keyword in object.keywords.values {
      switch keyword {
      case .value: continue
      case .schema(let schema): schema.forEachLink(visit)
      case .schemas(let schemas):
        for schema in schemas { schema.forEachLink(visit) }
      case .schemaMap(let schemas):
        for schema in schemas.values { schema.forEachLink(visit) }
      }
    }
  }
}

/// A schema object: its keywords in the order they're written, and its `$ref`.
public struct SchemaObject: Equatable, Sendable {
  /// Where the schema object is written.
  public let location: NodeLocation
  /// The schema's `$ref`, if it has one. Its other keywords stay in ``keywords``: in JSON Schema
  /// 2020-12 they apply alongside the referenced schema.
  public var reference: Reference?
  /// Every keyword except `$ref`.
  public var keywords: OrderedDictionary<String, Keyword>

  public init(
    location: NodeLocation,
    reference: Reference? = nil,
    keywords: OrderedDictionary<String, Keyword> = [:]
  ) {
    self.location = location
    self.reference = reference
    self.keywords = keywords
  }

  public subscript(keyword: String) -> Keyword? { keywords[keyword] }
}

/// A keyword's value. Keywords that hold schemas, such as `properties` or `items`, hold resolved
/// schemas; the rest, including `enum`, `examples` and `default`, hold the JSON as written.
public indirect enum Keyword: Equatable, Sendable {
  case value(JSONValue)
  /// `items`, `not`, `additionalProperties`, `if`, and others holding one schema.
  case schema(ResolvedSchema)
  /// `allOf`, `anyOf`, `oneOf` and `prefixItems`.
  case schemas([ResolvedSchema])
  /// `properties`, `patternProperties`, `$defs` and `dependentSchemas`.
  case schemaMap(OrderedDictionary<String, ResolvedSchema>)

  public var value: JSONValue? {
    if case .value(let value) = self { value } else { nil }
  }

  public var schema: ResolvedSchema? {
    if case .schema(let schema) = self { schema } else { nil }
  }

  public var schemas: [ResolvedSchema]? {
    if case .schemas(let schemas) = self { schemas } else { nil }
  }

  public var schemaMap: OrderedDictionary<String, ResolvedSchema>? {
    if case .schemaMap(let schemas) = self { schemas } else { nil }
  }

  static let singleSchemaKeywords: Set<String> = [
    "additionalItems", "additionalProperties", "contains", "contentSchema", "else", "if", "items",
    "not", "propertyNames", "then", "unevaluatedItems", "unevaluatedProperties",
  ]
  static let schemaArrayKeywords: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]
  static let schemaMapKeywords: Set<String> = [
    "$defs", "definitions", "dependentSchemas", "patternProperties", "properties",
  ]
}

/// A `$ref` and where it leads.
public struct Reference: Equatable, Sendable {
  /// The `$ref` as written, such as `#/components/schemas/Pet` or `common.yaml#/Address`.
  public let ref: String
  public var target: Target

  public init(ref: String, target: Target) {
    self.ref = ref
    self.target = target
  }

  public indirect enum Target: Equatable, Sendable {
    /// The schema at `origin`, which ``RefResolver/schema(at:)`` resolves.
    case link(SchemaOrigin)
    /// The schema at `origin`, expanded in place.
    case expanded(SchemaOrigin, ResolvedSchema)
    /// The schema at `origin` again, inside itself: a recursive structure such as a tree.
    case recursive(SchemaOrigin)
    /// The reference couldn't be followed.
    case unresolved(RefFailure)

    public var origin: SchemaOrigin? {
      switch self {
      case .link(let origin), .expanded(let origin, _), .recursive(let origin): origin
      case .unresolved: nil
      }
    }
  }
}

/// Where a referenced schema is written, and the name to show for it.
public struct SchemaOrigin: Hashable, Sendable, CustomStringConvertible {
  public let location: NodeLocation
  /// The component name for `#/components/schemas/<name>` in the spec itself, otherwise the
  /// file (relative to the spec) and pointer, such as `common/types.yaml#/Tag`.
  public let name: String

  public init(location: NodeLocation, name: String) {
    self.location = location
    self.name = name
  }

  public var description: String { name }
}

/// Why a `$ref` couldn't be followed.
public enum RefFailure: Error, Hashable, Sendable, CustomStringConvertible {
  /// The file it points to couldn't be read or parsed.
  case fileNotLoaded(LoadError)
  /// The fragment after `#` isn't a valid JSON Pointer.
  case invalidPointer(String)
  /// The file has nothing at the pointer.
  case missingTarget(NodeLocation)
  /// It points to something that isn't a schema, such as a string.
  case notASchema(NodeLocation)
  /// It points to another server. Only files next to the spec are read.
  case remote(String)
  /// It uses a named anchor, `#name`, which isn't supported.
  case anchor(String)
  /// `$ref` isn't a string.
  case notAString
  /// A chain of `$ref`s leads back to where it started.
  case circular

  public var description: String {
    switch self {
    case .fileNotLoaded(let error):
      "Couldn't load \(error.file.lastPathComponent): \(error.message)"
    case .invalidPointer(let fragment):
      "`#\(fragment)` isn't a valid JSON Pointer."
    case .missingTarget(let location):
      "\(location.file.lastPathComponent) has nothing at `\(location.pointer)`."
    case .notASchema(let location):
      "`\(location)` isn't a schema."
    case .remote(let url):
      "`\(url)` is on another server. Swanger only reads files next to the spec."
    case .anchor(let name):
      "Named anchors such as `#\(name)` aren't supported."
    case .notAString:
      "`$ref` must be a string."
    case .circular:
      "The references lead round in a circle."
    }
  }
}

/// Something wrong in a spec that doesn't stop it loading.
public struct LoadWarning: Hashable, Sendable, CustomStringConvertible {
  public enum Kind: Hashable, Sendable {
    /// A `$ref` that couldn't be followed. It shows as an unresolved schema.
    case unresolvedReference(ref: String, failure: RefFailure)
  }

  /// Where the problem is written.
  public let location: NodeLocation
  public let kind: Kind

  public init(location: NodeLocation, kind: Kind) {
    self.location = location
    self.kind = kind
  }

  public var message: String {
    switch kind {
    case .unresolvedReference(let ref, let failure):
      "`$ref: \(ref)` couldn't be followed. \(failure)"
    }
  }

  public var description: String { "\(location): \(message)" }
}
