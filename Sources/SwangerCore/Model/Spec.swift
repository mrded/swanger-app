import Foundation
import OrderedCollections
import OrderedJSON

/// Everything Swanger shows for a spec: its request and response schemas, the shared fragments
/// they're built from, and where each fragment is used.
public struct Spec: Sendable {
  public let url: URL
  /// `info.title`.
  public let title: String?
  /// `info.version`: the API's own version.
  public let apiVersion: String?
  public let openAPIVersion: OpenAPIVersion
  /// The `openapi` field as written, such as `3.1.0`.
  public let declaredVersion: String
  /// Request body schemas, in the order the spec's paths give them.
  public let requestSchemas: [RootSchema]
  /// Response body schemas, in the order the spec's paths give them.
  public let responseSchemas: [RootSchema]
  /// The shared fragments the roots use, most used first.
  public let fragments: [Fragment]
  public let fragmentIndex: FragmentIndex
  /// `$ref`s that couldn't be followed, among others.
  public let warnings: [LoadWarning]
  /// Every file read, the spec first, including ones that couldn't be.
  public let referencedFiles: [URL]

  /// Reads the spec at `url` and builds its model.
  public static func load(_ url: URL) throws(LoadError) -> Spec {
    Spec(document: try SpecLoader.load(url))
  }

  public init(
    document: OpenAPIDocument, load: @escaping RefResolver.Loader = SpecLoader.loadDocument
  ) {
    let resolver = RefResolver(spec: document, load: load)
    let builder = SchemaBuilder(resolver: resolver)
    let roots = RootFinder(resolver: resolver, builder: builder).roots()

    let info = document.root.object?["info"]?.object
    url = document.url
    title = info?["title"]?.string
    apiVersion = info?["version"]?.string ?? info?["version"]?.numberLiteral?.rawValue
    openAPIVersion = document.version
    declaredVersion = document.declaredVersion
    requestSchemas = roots.filter { $0.direction == .request }
    responseSchemas = roots.filter { $0.direction == .response }

    let index = FragmentIndex(roots: roots)
    fragmentIndex = index
    let fragments = builder.fragments.values.map { reference in
      Fragment(reference: reference, node: builder.node(of: reference))
    }
    self.fragments = fragments.enumerated().sorted { lhs, rhs in
      let lhsCount = index.roots(using: lhs.element.reference).count
      let rhsCount = index.roots(using: rhs.element.reference).count
      return lhsCount != rhsCount ? lhsCount > rhsCount : lhs.offset < rhs.offset
    }.map(\.element)
    warnings = resolver.warnings
    referencedFiles = resolver.referencedFiles
  }

  public var roots: [RootSchema] { requestSchemas + responseSchemas }

  public func root(_ id: RootID) -> RootSchema? {
    roots.first { $0.id == id }
  }

  public func fragment(_ reference: FragmentRef) -> Fragment? {
    fragments.first { $0.reference == reference }
  }
}

public struct RootID: Hashable, Sendable, CustomStringConvertible {
  public let direction: RootSchema.Direction
  /// The fragment's location, or the body schema's when it's written inline.
  public let key: String

  public var description: String { "\(direction) \(key)" }
}

/// A request or response body schema.
public struct RootSchema: Identifiable, Sendable {
  public enum Direction: String, Hashable, Sendable {
    case request
    case response
  }

  public let id: RootID
  public var direction: Direction { id.direction }
  /// The component's name, or `<operationId> request`, `<operationId> <status> response`, with
  /// `<METHOD> <path>` when there's no `operationId`.
  public let name: String
  public let node: SchemaNode
  /// Every operation that uses this schema as its body.
  public let operations: [OperationUse]
  /// The schema's `examples`, then the media types' `example` and `examples`.
  public let examples: [SchemaExample]
  public let stats: RootStats
}

/// An operation that uses a root schema as its request or response body.
public struct OperationUse: Hashable, Sendable, CustomStringConvertible {
  /// Upper case, such as `POST`.
  public let method: String
  public let path: String
  public let operationId: String?
  /// The response's status, such as `201` or `default`. `nil` for a request.
  public let status: String?
  public let mediaType: String

  public var description: String {
    [method, path, status].compactMap(\.self).joined(separator: " ")
  }
}

public struct SchemaExample: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    /// The schema's `examples`.
    case schema
    /// A media type's `example` or `examples`.
    case mediaType
  }

  /// The example's `summary` or key, for a media type's `examples`.
  public let name: String?
  public let value: JSONValue
  public let source: Source
}

/// Counts shown on a root's overview card.
public struct RootStats: Equatable, Sendable {
  /// Fields, counting each field inside each fragment where it's used.
  public let fields: Int
  /// Different fragments used, directly or inside other fragments.
  public let fragments: Int
  public let rules: Int
}

public struct Fragment: Identifiable, Sendable {
  public let reference: FragmentRef
  /// The fragment on its own, as its page shows it.
  public let node: SchemaNode

  public var id: NodeLocation { reference.id }
  public var name: String { reference.name }
}

// MARK: - Finding roots

/// Walks `paths` for request and response bodies.
private struct RootFinder {
  let resolver: RefResolver
  let builder: SchemaBuilder

  private static let methods = [
    "get", "put", "post", "delete", "options", "head", "patch", "trace",
  ]

  private struct Candidate {
    var id: RootID
    var name: String
    var node: SchemaNode
    var operations: [OperationUse]
    var mediaTypes: [NodeLocation]
  }

  func roots() -> [RootSchema] {
    var candidates = OrderedDictionary<RootID, Candidate>()
    let paths = resolver.rootLocation.appending("paths")
    guard case .success(.object(let pathItems)) = resolver.value(at: paths) else { return [] }

    for path in pathItems.keys {
      guard case .success(let item) = resolver.dereference(paths.appending(path)),
        case .success(.object(let operations)) = resolver.value(at: item)
      else { continue }
      for method in Self.methods where operations[method] != nil {
        let operation = item.appending(method)
        let operationId = operations[method]?.object?["operationId"]?.string
        var bodies: [(direction: RootSchema.Direction, status: String?, body: NodeLocation)] = []
        if operations[method]?.object?["requestBody"] != nil,
          case .success(let body) = resolver.dereference(operation.appending("requestBody"))
        {
          bodies.append((.request, nil, body))
        }
        let responses = operation.appending("responses")
        if case .success(.object(let statuses)) = resolver.value(at: responses) {
          for status in statuses.keys {
            if case .success(let body) = resolver.dereference(responses.appending(status)) {
              bodies.append((.response, status, body))
            }
          }
        }

        for (direction, status, body) in bodies {
          guard let (mediaType, media) = jsonMediaType(of: body) else { continue }
          let schema = media.appending("schema")
          guard let node = builder.node(at: schema) else { continue }
          let use = OperationUse(
            method: method.uppercased(), path: path, operationId: operationId, status: status,
            mediaType: mediaType)

          // A fragment used by several operations is one root.
          let id: RootID
          let name: String
          if let fragment = node.fragment, !node.isTightened {
            id = RootID(direction: direction, key: fragment.id.description)
            name = fragment.name
          } else {
            id = RootID(direction: direction, key: schema.description)
            let operationName = operationId ?? "\(use.method) \(path)"
            name = [operationName, status, direction.rawValue].compactMap(\.self).joined(
              separator: " ")
          }
          if candidates[id] == nil {
            candidates[id] = Candidate(
              id: id, name: name, node: node, operations: [], mediaTypes: [])
          }
          candidates[id]?.operations.append(use)
          candidates[id]?.mediaTypes.append(media)
        }
      }
    }

    return candidates.values.map { candidate in
      RootSchema(
        id: candidate.id, name: candidate.name, node: candidate.node,
        operations: candidate.operations, examples: examples(of: candidate),
        stats: RootStats(of: candidate.node))
    }
  }

  /// `application/json`, or else the first JSON-like media type such as `application/problem+json`.
  private func jsonMediaType(of body: NodeLocation) -> (String, NodeLocation)? {
    let content = body.appending("content")
    guard case .success(.object(let mediaTypes)) = resolver.value(at: content) else { return nil }
    let essence = { (type: String) in
      type.split(separator: ";")[0].trimmingCharacters(in: .whitespaces).lowercased()
    }
    let chosen =
      mediaTypes.keys.first { essence($0) == "application/json" }
      ?? mediaTypes.keys.first { essence($0).hasSuffix("+json") || essence($0).hasSuffix("/json") }
    return chosen.map { ($0, content.appending($0)) }
  }

  private func examples(of candidate: Candidate) -> [SchemaExample] {
    var examples = candidate.node.examples.map {
      SchemaExample(name: nil, value: $0, source: .schema)
    }
    func add(_ example: SchemaExample) {
      if !examples.contains(where: { $0.value == example.value }) { examples.append(example) }
    }
    for media in candidate.mediaTypes {
      guard case .success(.object(let fields)) = resolver.value(at: media) else { continue }
      if let example = fields["example"] {
        add(SchemaExample(name: nil, value: example, source: .mediaType))
      }
      for name in fields["examples"]?.object?.keys ?? [] {
        guard
          case .success(let location) = resolver.dereference(
            media.appending("examples").appending(name)),
          case .success(.object(let example)) = resolver.value(at: location),
          let value = example["value"]
        else { continue }
        add(
          SchemaExample(name: example["summary"]?.string ?? name, value: value, source: .mediaType))
      }
    }
    return examples
  }
}

// MARK: - Walking

extension SchemaNode {
  /// Visits this node and every node inside it, depth first, with the path to it and the nearest
  /// fragment it's inside. The node it starts from doesn't count as one, so a root that is a
  /// fragment uses what's in it directly. Stops at recursive nodes, so it always ends.
  func walk(
    path: FieldPath = FieldPath(),
    inside fragment: FragmentRef? = nil,
    _ visit: (SchemaNode, FieldPath, FragmentRef?) -> Void
  ) {
    visit(self, path, fragment)
    let inner = path.isEmpty ? fragment : self.fragment ?? fragment
    switch kind {
    case .object(let object):
      for field in object.fields {
        // A field from a base schema in an `allOf` is inside that base.
        let inside = field.definedIn ?? inner
        field.node.walk(path: path.appending(.field(field.name)), inside: inside, visit)
      }
    case .array(let array):
      for item in array.prefixItems + (array.items.map { [$0] } ?? []) {
        item.walk(path: path.appending(.items), inside: inner, visit)
      }
    case .choice(let choice):
      for variant in choice.variants {
        variant.node.walk(path: path.appending(.variant(variant.name)), inside: inner, visit)
      }
    case .scalar, .recursive, .unresolved, .never:
      break
    }
  }
}

extension SchemaNode {
  /// The fragment this node is, and the ones its fields come from through `allOf`.
  var fragmentsUsed: [FragmentRef] {
    var used = fragment.map { [$0] } ?? []
    for field in object?.fields ?? [] {
      if let definedIn = field.definedIn, !used.contains(definedIn) { used.append(definedIn) }
    }
    return used
  }
}

extension RootStats {
  init(of root: SchemaNode) {
    var fields = 0
    var rules = 0
    var fragments: Set<NodeLocation> = []
    root.walk { node, path, _ in
      if case .field = path.components.last { fields += 1 }
      rules += node.rules.count
      for fragment in node.fragmentsUsed where fragment != root.fragment {
        fragments.insert(fragment.id)
      }
    }
    self.init(fields: fields, fragments: fragments.count, rules: rules)
  }
}
