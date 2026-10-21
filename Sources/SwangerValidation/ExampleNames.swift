import OrderedJSON
import SwangerCore

/// Names for a schema's examples, so the menu says "type: Card" or "with reason" rather than
/// "Example 2".
public enum ExampleNames {
  /// A name for each example: the spec's own when it gives one, otherwise what tells it apart
  /// from the others.
  public static func names(for examples: [SchemaExample], of node: SchemaNode) -> [String] {
    let made = names(for: examples.map(\.value), of: node)
    return zip(examples, made).map { example, name in example.name ?? name }
  }

  /// A name for each value, from what tells it apart from the others, trying in turn:
  ///
  /// 1. top-level fields with fixed values (a discriminator, `const` or `enum`) that differ:
  ///    "type: Card";
  /// 2. which optional top-level fields are there: "with reason", "without reason";
  /// 3. the same, one level down: "payment.method: card", "with customer.phone";
  /// 4. the shortest value that differs, anywhere: "name: Ada".
  ///
  /// Each step only names the values the steps before it couldn't tell apart. A single value is
  /// "Example"; values nothing tells apart are numbered.
  public static func names(for values: [JSONValue], of node: SchemaNode) -> [String] {
    guard values.count > 1 else { return values.map { _ in "Example" } }
    var namer = Namer(values: values)
    for feature in features(of: node, path: []) { namer.refine(feature) }
    while namer.refineByShortestDifference() {}
    var names = namer.labels.map { $0.joined(separator: ", ") }
    var counts: [String: Int] = [:]
    for name in names { counts[name, default: 0] += 1 }
    var seen: [String: Int] = [:]
    for (index, name) in names.enumerated() where counts[name]! > 1 {
      seen[name, default: 0] += 1
      names[index] = name.isEmpty ? "Example \(index + 1)" : "\(name) (\(seen[name]!))"
    }
    return names
  }

  /// A label for a value, or `nil` when the feature doesn't apply to it.
  private typealias Feature = (JSONValue) -> String?

  /// Steps 1–3, for the object at `path`.
  private static func features(of node: SchemaNode, path: [String]) -> [Feature] {
    let fields = node.object?.fields ?? []
    var fixed: [String] = fields.filter { $0.node.scalar?.allowedValues != nil }.map(\.name)
    let choices = (node.choice.map { [$0] } ?? []) + node.choices
    for name in choices.compactMap(\.discriminator) where !fixed.contains(name) {
      fixed.append(name)
    }
    let optional = fields.filter { !$0.isRequired && !$0.isForbidden }.map(\.name)

    var features: [Feature] = fixed.map { name in
      { value in
        guard let object = lookUp(path, in: value)?.object else { return nil }
        let field = dotted(path + [name])
        return object[name].map { "\(field): \(label($0))" } ?? "without \(field)"
      }
    }
    features += optional.map { name in
      { value in
        guard let object = lookUp(path, in: value)?.object else { return nil }
        let field = dotted(path + [name])
        return object[name] == nil ? "without \(field)" : "with \(field)"
      }
    }
    if path.isEmpty {
      for field in fields where field.node.object != nil || field.node.choice != nil {
        features += Self.features(of: field.node, path: [field.name])
      }
    }
    return features
  }

  private struct Namer {
    let values: [JSONValue]
    var labels: [[String]]

    init(values: [JSONValue]) {
      self.values = values
      labels = values.map { _ in [] }
    }

    /// Indexes of values with the same labels so far, for groups of more than one.
    var groups: [[Int]] {
      var groups: [[String]: [Int]] = [:]
      var order: [[String]] = []
      for (index, label) in labels.enumerated() {
        if groups[label] == nil { order.append(label) }
        groups[label, default: []].append(index)
      }
      return order.compactMap { groups[$0]!.count > 1 ? groups[$0] : nil }
    }

    mutating func refine(_ feature: Feature) {
      for group in groups {
        let found = group.map { feature(values[$0]) }
        guard Set(found).count > 1 else { continue }
        for (index, label) in zip(group, found) {
          if let label { labels[index].append(label) }
        }
      }
    }

    /// Step 4 for each group: names the values by the path whose differing values are shortest.
    /// `false` when no group could be told apart.
    mutating func refineByShortestDifference() -> Bool {
      var changed = false
      for group in groups {
        var paths: [[String]] = []
        for index in group {
          for path in leafPaths(values[index]) where !paths.contains(path) { paths.append(path) }
        }
        var best: (path: [String], length: Int)?
        for path in paths {
          let found = group.map { lookUp(path, in: values[$0]).map(label) }
          guard Set(found).count > 1 else { continue }
          let length = found.map { $0?.count ?? 0 }.max() ?? 0
          if best == nil || length < best!.length { best = (path, length) }
        }
        guard let best else { continue }
        let field = dotted(best.path)
        for index in group {
          let label = lookUp(best.path, in: values[index]).map { "\(field): \(label($0))" }
          labels[index].append(label ?? "without \(field)")
        }
        changed = true
      }
      return changed
    }
  }

  /// Paths to every value that isn't an object, array items numbered.
  private static func leafPaths(_ value: JSONValue, at path: [String] = []) -> [[String]] {
    switch value {
    case .object(let object):
      object.flatMap { key, child in leafPaths(child, at: path + [key]) }
    case .array(let array) where !array.isEmpty:
      array.enumerated().flatMap { index, child in leafPaths(child, at: path + [String(index)]) }
    default:
      [path]
    }
  }

  private static func lookUp(_ path: [String], in value: JSONValue) -> JSONValue? {
    SwangerCore.JSONPointer(tokens: path).value(in: value)
  }

  private static func dotted(_ path: [String]) -> String {
    path.isEmpty ? "value" : path.joined(separator: ".")
  }

  /// Strings without quotes, other values as JSON, cut short past 30 characters.
  private static func label(_ value: JSONValue) -> String {
    let text = value.string ?? Wording.literal(value).replacing("`", with: "")
    return text.count > 30 ? text.prefix(29) + "…" : text
  }
}
