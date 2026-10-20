import Foundation
import OrderedCollections
import OrderedJSON

/// Follows `$ref`s within a spec and into files next to it.
///
/// Everything is addressed by ``NodeLocation``: a file and a JSON Pointer into it. A relative
/// `$ref` is resolved against the file it's written in, and each file is loaded once, the first
/// time something points into it. A `$ref` that can't be followed never throws: it becomes
/// ``Reference/Target/unresolved(_:)`` and is added to ``warnings``.
///
/// Not thread-safe: use one resolver from one task.
public final class RefResolver {
  public typealias Loader = (URL) throws(LoadError) -> SourceDocument

  /// The spec's own file.
  public let rootFile: URL
  /// The spec's version. Schemas in a 3.0 spec, and in the files it refers to, are rewritten as
  /// JSON Schema 2020-12 when they're resolved.
  public let version: OpenAPIVersion
  public private(set) var warnings: [LoadWarning] = []

  private let load: Loader
  private var files: OrderedDictionary<URL, Result<SourceDocument, LoadError>> = [:]
  private var schemas: [NodeLocation: ResolvedSchema] = [:]
  private var warnedLocations: Set<NodeLocation> = []

  /// - Parameter load: Reads a referenced file. Tests pass their own.
  public init(
    root: SourceDocument,
    version: OpenAPIVersion,
    load: @escaping Loader = SpecLoader.loadDocument
  ) {
    rootFile = Self.key(for: root.url)
    self.version = version
    self.load = load
    files[rootFile] = .success(root)
  }

  public convenience init(spec: OpenAPIDocument, load: @escaping Loader = SpecLoader.loadDocument) {
    self.init(root: spec.source, version: spec.version, load: load)
  }

  /// The location of the whole spec.
  public var rootLocation: NodeLocation { NodeLocation(file: rootFile) }

  /// Every file looked at so far, the spec first, including ones that couldn't be loaded, so that
  /// creating a missing file can be noticed.
  public var referencedFiles: [URL] { Array(files.keys) }

  /// Every file loaded so far, by URL.
  public var documents: [URL: SourceDocument] {
    files.reduce(into: [:]) { documents, entry in
      if case .success(let document) = entry.value { documents[entry.key] = document }
    }
  }

  /// The JSON at `location`.
  public func value(at location: NodeLocation) -> Result<JSONValue, RefFailure> {
    switch document(location.file) {
    case .failure(let error):
      return .failure(.fileNotLoaded(error))
    case .success(let document):
      guard let value = location.pointer.value(in: document.root) else {
        return .failure(.missingTarget(location))
      }
      return .success(value)
    }
  }

  /// Follows `$ref`s from `location` until reaching a value that isn't one, as for request bodies,
  /// responses and examples that refer to `components`. Failures are added to ``warnings``.
  public func dereference(_ location: NodeLocation) -> Result<NodeLocation, RefFailure> {
    var current = location
    var visited: Set<NodeLocation> = [location]
    while true {
      // Each target has been checked to exist, so only the starting location can be missing.
      let value: JSONValue
      switch self.value(at: current) {
      case .success(let found): value = found
      case .failure(let failure): return .failure(failure)
      }
      guard let ref = value.object?["$ref"] else { return .success(current) }
      let refText = ref.string ?? ref.description
      let next = ref.string.map { target(of: $0, from: current) } ?? .failure(.notAString)
      switch next {
      case .failure(let failure):
        warn(at: current, ref: refText, failure: failure)
        return .failure(failure)
      case .success(let target):
        guard visited.insert(target).inserted else {
          warn(at: current, ref: refText, failure: .circular)
          return .failure(.circular)
        }
        current = target
      }
    }
  }

  /// The schema at `location`, with each `$ref` in it as a ``Reference/Target/link(_:)``.
  /// `nil` when there's no schema there.
  ///
  /// Each schema is resolved once. In a 3.0 spec it's normalised first: this is the first point
  /// where it's known to be a schema, which a referenced file doesn't say by itself.
  public func schema(at location: NodeLocation) -> ResolvedSchema? {
    let location = NodeLocation(file: Self.key(for: location.file), pointer: location.pointer)
    if let schema = schemas[location] { return schema }
    guard case .success(var value) = self.value(at: location) else { return nil }
    if version == .v30 { value = OpenAPI30Normaliser.normalise(value) }
    guard let schema = resolve(value, at: location) else { return nil }
    schemas[location] = schema
    return schema
  }

  /// The schema at `location` as a tree: every link is replaced by the schema it leads to, except
  /// that a schema met again inside itself becomes ``Reference/Target/recursive(_:)``.
  public func expandedSchema(at location: NodeLocation) -> ResolvedSchema? {
    guard let schema = schema(at: location) else { return nil }
    var path = [schema.location]
    return expand(schema, path: &path)
  }

  /// The name to show for the schema at `location`.
  public func origin(of location: NodeLocation) -> SchemaOrigin {
    let tokens = location.pointer.tokens
    if location.file == rootFile, tokens.count == 3, tokens[0] == "components",
      tokens[1] == "schemas"
    {
      return SchemaOrigin(location: location, name: tokens[2])
    }
    let path = relativePath(of: location.file)
    let name = location.pointer.isRoot ? path : "\(path)#\(location.pointer)"
    return SchemaOrigin(location: location, name: name)
  }

  // MARK: - Resolving

  private func resolve(_ value: JSONValue, at location: NodeLocation) -> ResolvedSchema? {
    switch value {
    case .boolean(let bool):
      return .boolean(bool, location: location)
    case .object(let fields):
      var object = SchemaObject(location: location)
      for (keyword, value) in fields {
        if keyword == "$ref" {
          object.reference = reference(value, at: location)
        } else {
          object.keywords[keyword] = self.keyword(keyword, value, at: location.appending(keyword))
        }
      }
      return .object(object)
    default:
      return nil
    }
  }

  private func keyword(_ name: String, _ value: JSONValue, at location: NodeLocation) -> Keyword {
    if Keyword.singleSchemaKeywords.contains(name), let schema = resolve(value, at: location) {
      return .schema(schema)
    }
    if Keyword.schemaArrayKeywords.contains(name) || name == "items", case .array(let array) = value
    {
      var schemas: [ResolvedSchema] = []
      for (index, element) in array.enumerated() {
        guard let schema = resolve(element, at: location.appending(index)) else {
          return .value(value)
        }
        schemas.append(schema)
      }
      return .schemas(schemas)
    }
    if Keyword.schemaMapKeywords.contains(name), case .object(let object) = value {
      var schemas = OrderedDictionary<String, ResolvedSchema>()
      for (key, element) in object {
        guard let schema = resolve(element, at: location.appending(key)) else {
          return .value(value)
        }
        schemas[key] = schema
      }
      return .schemaMap(schemas)
    }
    return .value(value)
  }

  private func reference(_ value: JSONValue, at location: NodeLocation) -> Reference {
    guard case .string(let ref) = value else {
      warn(at: location, ref: value.description, failure: .notAString)
      return Reference(ref: value.description, target: .unresolved(.notAString))
    }
    let target = self.target(of: ref, from: location).flatMap { target in
      switch self.value(at: target) {
      case .success(.object), .success(.boolean): .success(target)
      case .success: .failure(.notASchema(target))
      case .failure(let failure): .failure(failure)
      }
    }
    switch target {
    case .success(let target):
      return Reference(ref: ref, target: .link(origin(of: target)))
    case .failure(let failure):
      warn(at: location, ref: ref, failure: failure)
      return Reference(ref: ref, target: .unresolved(failure))
    }
  }

  /// Where `ref`, written at `site`, points. Checks the value exists, not what it is.
  private func target(of ref: String, from site: NodeLocation) -> Result<NodeLocation, RefFailure> {
    location(of: ref, from: site).flatMap { location in value(at: location).map { _ in location } }
  }

  /// Where `ref`, written at `site`, points, worked out from its text alone: nothing is read, so
  /// the target may not exist.
  func location(of ref: String, from site: NodeLocation) -> Result<NodeLocation, RefFailure> {
    let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let path = String(parts[0])
    let fragment = parts.count > 1 ? String(parts[1]) : ""

    let file: URL
    if path.isEmpty {
      file = site.file
    } else {
      guard let url = URL(string: path, relativeTo: site.file) else {
        return .failure(.missingTarget(NodeLocation(file: site.file.appending(path: path))))
      }
      guard url.isFileURL else { return .failure(.remote(ref)) }
      file = Self.key(for: url)
    }

    let decoded = fragment.removingPercentEncoding ?? fragment
    guard decoded.isEmpty || decoded.hasPrefix("/") else { return .failure(.anchor(decoded)) }
    guard let pointer = JSONPointer(decoded) else { return .failure(.invalidPointer(fragment)) }

    return .success(NodeLocation(file: file, pointer: pointer))
  }

  // MARK: - Expanding

  private func expand(_ schema: ResolvedSchema, path: inout [NodeLocation]) -> ResolvedSchema {
    guard case .object(var object) = schema else { return schema }
    if var reference = object.reference, case .link(let origin) = reference.target {
      if path.contains(origin.location) {
        reference.target = .recursive(origin)
      } else if let target = self.schema(at: origin.location) {
        path.append(origin.location)
        reference.target = .expanded(origin, expand(target, path: &path))
        path.removeLast()
      }
      object.reference = reference
    }
    for (name, keyword) in object.keywords {
      switch keyword {
      case .value:
        continue
      case .schema(let schema):
        object.keywords[name] = .schema(expand(schema, path: &path))
      case .schemas(let schemas):
        object.keywords[name] = .schemas(schemas.map { expand($0, path: &path) })
      case .schemaMap(let schemas):
        object.keywords[name] = .schemaMap(schemas.mapValues { expand($0, path: &path) })
      }
    }
    return .object(object)
  }

  // MARK: - Files

  private func document(_ file: URL) -> Result<SourceDocument, LoadError> {
    let file = Self.key(for: file)
    if let cached = files[file] { return cached }
    let result: Result<SourceDocument, LoadError>
    do {
      result = .success(try load(file))
    } catch {
      result = .failure(error)
    }
    files[file] = result
    return result
  }

  private func warn(at location: NodeLocation, ref: String, failure: RefFailure) {
    guard warnedLocations.insert(location).inserted else { return }
    warnings.append(
      LoadWarning(location: location, kind: .unresolvedReference(ref: ref, failure: failure)))
  }

  /// `file` relative to the spec's folder, such as `common/types.yaml` or `../shared/types.yaml`.
  private func relativePath(of file: URL) -> String {
    let folder = rootFile.deletingLastPathComponent().pathComponents
    let target = file.pathComponents
    let shared = zip(folder, target).prefix { $0 == $1 }.count
    let parts = Array(repeating: "..", count: folder.count - shared) + target.dropFirst(shared)
    return parts.joined(separator: "/")
  }

  /// Files are cached by their absolute, standardised URL, so `./a.yaml` and `b/../a.yaml` are the
  /// same file.
  private static func key(for url: URL) -> URL {
    url.absoluteURL.standardizedFileURL
  }
}
