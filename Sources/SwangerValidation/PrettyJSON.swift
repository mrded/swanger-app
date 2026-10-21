import OrderedJSON

extension JSONValue {
  /// The value as JSON to edit: two spaces to a level, `"key": value`, and empty objects and
  /// arrays as `{}` and `[]`.
  public var prettyText: String {
    var text = ""
    write(to: &text, indent: "")
    return text
  }

  private func write(to text: inout String, indent: String) {
    let inner = indent + "  "
    switch self {
    case .object(let fields) where !fields.isEmpty:
      text += "{\n"
      for (index, (key, value)) in fields.enumerated() {
        text += inner + JSONValue.string(key).compactText + ": "
        value.write(to: &text, indent: inner)
        text += index < fields.count - 1 ? ",\n" : "\n"
      }
      text += indent + "}"
    case .array(let items) where !items.isEmpty:
      text += "[\n"
      for (index, item) in items.enumerated() {
        text += inner
        item.write(to: &text, indent: inner)
        text += index < items.count - 1 ? ",\n" : "\n"
      }
      text += indent + "]"
    default:
      text += compactText
    }
  }

  /// A scalar, or an empty object or array, on one line.
  private var compactText: String {
    (try? serialized(options: .compact)) ?? "null"
  }
}
