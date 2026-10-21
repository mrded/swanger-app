import SwangerCore

/// One thing wrong with a payload, in plain English.
public struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
  public enum Kind: String, Hashable, Sendable, CaseIterable {
    /// A required field isn't there.
    case missing = "Missing"
    case wrongType = "Wrong type"
    /// Not one of the `enum` or `const` values.
    case notAllowedValue = "Not allowed value"
    /// Doesn't match the `format` or `pattern`.
    case wrongFormat = "Wrong format"
    /// Too small, large, short or long, or with too many or too few items or fields.
    case outOfRange = "Out of range"
    /// A field that isn't allowed, or an array item past the last one allowed.
    case unexpectedField = "Unexpected field"
    /// Anything else: conditions, choices, `not` and the like.
    case ruleNotMet = "Rule not met"
  }

  public let kind: Kind
  /// Where the problem is in the payload. For a missing or unexpected field, the field itself.
  public let pointer: SwangerCore.JSONPointer
  /// What's wrong, as Markdown with names and code in backticks: "Must be a string, not a
  /// number". A condition branch with a `description` uses that instead.
  public let message: String

  public init(kind: Kind, pointer: SwangerCore.JSONPointer, message: String) {
    self.kind = kind
    self.pointer = pointer
    self.message = message
  }

  /// `/customer/name: Wrong type: Must be a string, not a number`.
  public var description: String {
    "\(pointer.isRoot ? "/" : pointer.description): \(kind.rawValue): \(message)"
  }
}
