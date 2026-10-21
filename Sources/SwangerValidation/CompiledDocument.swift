import OrderedCollections
import OrderedJSON
import SwangerCore

/// A schema from a spec, written out as one self-contained JSON Schema document that
/// swift-json-schema can compile.
///
/// The schema and every schema it reaches through `$ref`, in the spec or in files next to it, go
/// under `$defs`, named `s0`, `s1` and so on in the order they're met, and each `$ref` is
/// rewritten to point there. The schemas are the spec's normalised ones, so a 3.0 spec is already
/// 2020-12. A `$ref` that couldn't be followed is left out, so it allows anything, as the model
/// shows it as unresolved.
struct CompiledDocument {
  /// `{"$defs": {...}, "$ref": "#/$defs/s0"}`.
  let json: JSONValue

  init?(root: NodeLocation, schemas: [NodeLocation: ResolvedSchema]) {
    guard schemas[root] != nil else { return nil }
    var names: OrderedDictionary<NodeLocation, String> = [root: "s0"]
    var defs = OrderedDictionary<String, JSONValue>()
    var index = 0
    while index < names.count {
      let (location, name) = names.elements[index]
      index += 1
      defs[name] = Self.json(for: schemas[location]!) { origin in
        guard schemas[origin.location] != nil else { return nil }
        if let known = names[origin.location] { return known }
        let next = "s\(names.count)"
        names[origin.location] = next
        return next
      }
    }
    json = .object(["$defs": .object(defs), "$ref": "#/$defs/s0"])
  }

  /// `schema` as JSON, with each link's `$ref` pointing to the name `name(for:)` gives it.
  ///
  /// Keywords beside a `$ref` are kept, but the `$ref` moves into `allOf` in the same object:
  /// swift-json-schema 0.14 lets `additionalProperties` and `items` see the `properties` and
  /// `prefixItems` of a `$ref` beside them, so `{$ref: X, additionalProperties: false}` would
  /// accept X's fields. In 2020-12 the two forms mean the same, `unevaluatedProperties` included.
  private static func json(
    for schema: ResolvedSchema, name: (SchemaOrigin) -> String?
  ) -> JSONValue {
    guard case .object(let object) = schema else {
      return .boolean(schema == .boolean(true, location: schema.location))
    }
    var fields = OrderedDictionary<String, JSONValue>()
    for (keyword, value) in object.keywords {
      // They'd change the base URI or dialect the rewritten `$ref`s are read against.
      if keyword == "$id" || keyword == "$schema" { continue }
      switch value {
      case .value(let value):
        fields[keyword] = value
      case .schema(let schema):
        fields[keyword] = json(for: schema, name: name)
      case .schemas(let schemas):
        fields[keyword] = .array(schemas.map { json(for: $0, name: name) })
      case .schemaMap(let schemas):
        fields[keyword] = .object(schemas.mapValues { json(for: $0, name: name) })
      }
    }
    guard case .link(let origin) = object.reference?.target, let target = name(origin) else {
      return .object(fields)
    }
    let ref: JSONValue = .object(["$ref": .string("#/$defs/\(target)")])
    if fields.isEmpty { return ref }
    if case .array(let members) = fields["allOf"] {
      fields["allOf"] = .array([ref] + members)
    } else {
      fields["allOf"] = [ref]
    }
    return .object(fields)
  }
}
