import OrderedCollections
import OrderedJSON

/// Rewrites an OpenAPI 3.0 schema as the JSON Schema 2020-12 that OpenAPI 3.1 uses, so the rest of
/// Swanger only deals with one dialect.
///
/// - `nullable: true` adds `"null"` to `type`, and to `enum` when there is one. As OpenAPI 3.0.3
///   clarifies, it has no effect without a `type`, so then it's just removed.
/// - A boolean `exclusiveMinimum` or `exclusiveMaximum` takes the value of `minimum` or `maximum`.
/// - `example` becomes `examples: [example]`.
/// - Keywords beside `$ref` are dropped, since OpenAPI 3.0 ignores them, except `description`,
///   which OpenAPI 3.1 lets a reference override.
///
/// Keys keep their order, with each rewritten keyword where the original was. Subschemas are
/// normalised too; values that are data, such as `enum`, `default` and `examples`, aren't touched.
enum OpenAPI30Normaliser {
  static func normalise(_ schema: JSONValue) -> JSONValue {
    guard case .object(let fields) = schema else { return schema }

    let hasRef = fields["$ref"] != nil
    let nullable = fields["nullable"]?.boolean == true && fields["type"] != nil
    var result = OrderedDictionary<String, JSONValue>()
    for (keyword, value) in fields {
      if hasRef, keyword != "$ref", keyword != "description" { continue }
      switch keyword {
      case "nullable":
        continue
      case "type":
        result[keyword] = nullable ? addingNullType(to: value) : value
      case "enum":
        result[keyword] = nullable ? addingNull(to: value) : value
      case "minimum", "maximum":
        let exclusive = keyword == "minimum" ? "exclusiveMinimum" : "exclusiveMaximum"
        result[fields[exclusive]?.boolean == true ? exclusive : keyword] = value
      case "exclusiveMinimum", "exclusiveMaximum":
        // A boolean only says whether `minimum` or `maximum` is exclusive; see above.
        if value.boolean == nil { result[keyword] = value }
      case "example":
        // Folded into `examples` if there is one; see below.
        if fields["examples"] == nil { result["examples"] = [value] }
      case "examples":
        if let example = fields["example"], case .array(let examples) = value {
          result[keyword] = .array([example] + examples)
        } else {
          result[keyword] = value
        }
      default:
        result[keyword] = normaliseSubschemas(of: keyword, value)
      }
    }
    return .object(result)
  }

  private static func normaliseSubschemas(of keyword: String, _ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object) where Keyword.schemaMapKeywords.contains(keyword):
      return .object(object.mapValues(normalise))
    case .array(let array)
    where Keyword.schemaArrayKeywords.contains(keyword) || keyword == "items":
      return .array(array.map(normalise))
    case .object where Keyword.singleSchemaKeywords.contains(keyword):
      return normalise(value)
    default:
      return value
    }
  }

  private static func addingNullType(to type: JSONValue) -> JSONValue {
    switch type {
    case .string(let name):
      return name == "null" ? type : .array([.string(name), "null"])
    case .array(let names):
      return names.contains("null") ? type : .array(names + ["null"])
    default:
      return type
    }
  }

  private static func addingNull(to values: JSONValue) -> JSONValue {
    guard case .array(let values) = values, !values.contains(.null) else { return values }
    return .array(values + [.null])
  }
}
