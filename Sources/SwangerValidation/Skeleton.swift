import OrderedCollections
import OrderedJSON
import SwangerCore

/// A payload to start from when a schema has no examples.
public enum Skeleton {
  /// The required fields only, each with its first allowed value, its `default`, or a placeholder
  /// for its type: `""`, `0`, `false`, `{}` or `[]`. A choice takes its first variant. An array
  /// gets one item when its items are objects or choices, so their fields are there to fill in.
  ///
  /// It isn't always valid: placeholders don't meet patterns, formats or lower limits.
  public static func payload(for node: SchemaNode, in spec: Spec) -> JSONValue {
    var builder = Builder(spec: spec)
    if let fragment = node.fragment { builder.entered.insert(fragment.id) }
    return builder.value(for: node)
  }

  private struct Builder {
    let spec: Spec
    /// Recursive fragments being filled in, so a required field that leads back to its own
    /// fragment ends.
    var entered: Set<NodeLocation> = []

    mutating func value(for node: SchemaNode) -> JSONValue {
      if let allowed = node.scalar?.allowedValues, let first = allowed.first {
        return allowed.first { $0 != .null } ?? first
      }
      if let defaultValue = node.defaultValue { return defaultValue }
      switch node.kind {
      case .object(let object):
        var fields = OrderedDictionary<String, JSONValue>()
        for field in object.fields where field.isRequired && !field.isForbidden {
          fields[field.name] = value(for: field.node)
        }
        for choice in node.choices {
          guard let variant = choice.variants.first,
            case .object(let more) = value(for: variant.node)
          else { continue }
          for (name, value) in more where fields[name] == nil { fields[name] = value }
        }
        return .object(fields)
      case .array(let array):
        var items = array.prefixItems.map { value(for: $0) }
        if items.isEmpty, let item = array.items, item.object != nil || item.choice != nil {
          items.append(value(for: item))
        }
        return .array(items)
      case .scalar(let scalar):
        return placeholder(scalar.types.first { $0 != "null" } ?? scalar.types.first)
      case .choice(let choice):
        return choice.variants.first.map { value(for: $0.node) } ?? .null
      case .recursive(let fragment):
        guard !entered.contains(fragment.id), let target = spec.fragment(fragment)?.node else {
          return node.allowsNull ? .null : .object([:])
        }
        entered.insert(fragment.id)
        defer { entered.remove(fragment.id) }
        return value(for: target)
      case .unresolved, .never:
        return .null
      }
    }

    private func placeholder(_ type: String?) -> JSONValue {
      switch type {
      case "string": ""
      case "integer", "number": 0
      case "boolean": false
      case "object": .object([:])
      case "array": .array([])
      default: .null
      }
    }
  }
}
