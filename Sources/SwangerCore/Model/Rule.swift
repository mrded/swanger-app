import OrderedJSON

/// Something a value must satisfy, in plain English. Field names and code are in backticks, so
/// the text can be shown as Markdown.
public struct Rule: Equatable, Sendable, CustomStringConvertible {
  public enum Kind: Equatable, Sendable {
    /// A limit on the value itself: "allows at most 70 characters".
    case constraint
    /// `if`/`then`/`else`: "When `status` is "Rejected": `reason` is required".
    case condition
    /// `oneOf` or `anyOf`: "When `type` is "Card": it's a `Card`".
    case choice
    /// `dependentRequired`: "When `a` is present: `b` is required".
    case dependency
  }

  public let kind: Kind
  public let text: String

  public init(_ kind: Kind, _ text: String) {
    self.kind = kind
    self.text = text
  }

  public var description: String { text }
}

/// Builds the wording of rules, and of validation issues in `SwangerValidation`.
package enum Wording {
  /// A value as JSON: `"Rejected"`, `5`, `true`, `null`.
  package static func literal(_ value: JSONValue) -> String {
    switch value {
    case .string(let text): "\"\(text)\""
    case .numberLiteral(let number): number.rawValue
    case .boolean(let bool): bool ? "true" : "false"
    case .null: "null"
    case .array, .object: "`\(value.description)`"
    }
  }

  package static func code(_ name: String) -> String { "`\(name)`" }

  /// "an integer", "a string or null".
  package static func types(_ types: [String]) -> String {
    let named = types.map { type in
      if type == "null" { return "null" }
      return (["integer", "object", "array"].contains(type) ? "an " : "a ") + type
    }
    return list(named, "or")
  }

  package static func count(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
  }

  /// "must be "a"", "must be one of "a", "b" or "c"".
  package static func allowedValues(_ values: [JSONValue]) -> String {
    values.count == 1
      ? "must be \(literal(values[0]))"
      : "must be one of \(list(values.map(literal), "or"))"
  }

  /// "`a` is required", "`a` and `b` are required".
  package static func required(_ names: [String]) -> String {
    "\(list(names.map(code), "and")) \(names.count == 1 ? "is" : "are") required"
  }

  /// "`a` isn't allowed", "`a` and `b` aren't allowed".
  package static func forbidden(_ names: [String]) -> String {
    "\(list(names.map(code), "and")) \(names.count == 1 ? "isn't" : "aren't") allowed"
  }

  package static func format(_ format: String) -> String {
    let described: String? =
      switch format {
      case "date": "a date, such as 2024-01-31"
      case "date-time": "a date and time, such as 2024-01-31T09:30:00Z"
      case "time": "a time, such as 09:30:00Z"
      case "duration": "a duration, such as P1D"
      case "email", "idn-email": "an email address"
      case "hostname", "idn-hostname": "a host name"
      case "ipv4": "an IPv4 address"
      case "ipv6": "an IPv6 address"
      case "uri", "iri": "a URI"
      case "uri-reference", "iri-reference": "a URI reference"
      case "uuid": "a UUID"
      case "regex": "a regular expression"
      case "byte": "base64-encoded data"
      case "int32": "a whole number that fits in 32 bits"
      case "int64": "a whole number that fits in 64 bits"
      default: nil
      }
    return described.map { "must be \($0)" } ?? "must be in the \(code(format)) format"
  }
}
