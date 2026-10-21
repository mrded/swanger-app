import JSONSchema
import SwangerCore
import Synchronization

/// Checks JSON payloads against a spec's schemas with swift-json-schema, and explains what's wrong
/// in ``ValidationIssue``s.
///
/// Each schema is compiled the first time it's used and kept. Safe to use from any thread.
public final class PayloadValidator: Sendable {
  public let spec: Spec
  private let compiled = Mutex<[NodeLocation: Compiled]>([:])

  /// A schema that's ready to use, with the document it was compiled from, which issues are read
  /// against.
  private struct Compiled: Sendable {
    let schema: Schema
    let document: JSONValue
  }

  public init(spec: Spec) {
    self.spec = spec
  }

  /// What's wrong with `payload` as the body `root` describes: empty when it's valid.
  public func issues(in payload: JSONValue, for root: RootSchema) -> [ValidationIssue] {
    issues(in: payload, forSchemaAt: root.id.location)
  }

  /// What's wrong with `payload` as a value of `fragment`: empty when it's valid.
  public func issues(in payload: JSONValue, for fragment: Fragment) -> [ValidationIssue] {
    issues(in: payload, forSchemaAt: fragment.reference.id)
  }

  /// What's wrong with `payload` as a value of the schema at `location`, which must be one of
  /// ``Spec/resolvedSchemas``: empty when it's valid. A location that isn't allows anything.
  public func issues(in payload: JSONValue, forSchemaAt location: NodeLocation)
    -> [ValidationIssue]
  {
    guard let compiled = compile(location) else { return [] }
    let result = compiled.schema.validate(payload)
    if result.isValid { return [] }
    return IssueReader(document: compiled.document, payload: payload).issues(in: result)
  }

  /// Whether `payload` is valid for the schema at `location`, without explaining why not.
  public func isValid(_ payload: JSONValue, forSchemaAt location: NodeLocation) -> Bool {
    compile(location)?.schema.validate(payload).isValid ?? true
  }

  /// How many schemas have been compiled, for tests.
  var compiledCount: Int { compiled.withLock { $0.count } }

  private func compile(_ location: NodeLocation) -> Compiled? {
    if let cached = compiled.withLock({ $0[location] }) { return cached }
    guard let document = CompiledDocument(root: location, schemas: spec.resolvedSchemas),
      // Only a document that isn't an object or boolean, or asks for a vocabulary it doesn't
      // know, fails to compile, and this one is an object without `$vocabulary`.
      let schema = try? Schema(
        rawSchema: document.json,
        context: Context(dialect: .draft2020_12, formatValidators: DefaultFormatValidators.all))
    else { return nil }
    let result = Compiled(schema: schema, document: document.json)
    compiled.withLock { $0[location] = result }
    return result
  }
}
