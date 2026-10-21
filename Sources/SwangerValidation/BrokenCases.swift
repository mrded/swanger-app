import OrderedJSON
import SwangerCore

/// A copy of an example with one thing changed, to check that each kind of mistake is reported
/// where it was made.
public struct BrokenCase: Sendable, CustomStringConvertible {
  public enum Change: Hashable, Sendable {
    case removed
    case replaced(with: JSONValue)
    /// A field the example didn't have, named ``BrokenCases/unexpectedFieldName``.
    case added
  }

  /// The field removed, replaced or added.
  public let pointer: SwangerCore.JSONPointer
  public let change: Change
  public let payload: JSONValue

  /// `/customer/name removed`, `/lines/0/sku set to 7`.
  public var description: String {
    switch change {
    case .removed: "\(pointer) removed"
    case .replaced(let value): "\(pointer) set to \(value)"
    case .added: "\(pointer) added"
    }
  }
}

public enum BrokenCases {
  /// The values each field is set to in turn, unless it already has that value.
  public static let replacements: [JSONValue] = ["", 7, "zzz", .null, .object([:]), .array([])]
  public static let unexpectedFieldName = "unexpectedField"

  /// From `example`, at any depth: each field removed, each field set to each of
  /// ``replacements``, and each object given an unexpected field.
  public static func cases(from example: JSONValue) -> [BrokenCase] {
    var cases: [BrokenCase] = []
    func visit(_ value: JSONValue, at pointer: SwangerCore.JSONPointer) {
      switch value {
      case .object(let object):
        for (key, child) in object {
          let field = pointer.appending(key)
          cases.append(
            BrokenCase(
              pointer: field, change: .removed,
              payload: updating(example, at: field.tokens[...]) { _ in nil }))
          for replacement in replacements where replacement != child {
            cases.append(
              BrokenCase(
                pointer: field, change: .replaced(with: replacement),
                payload: updating(example, at: field.tokens[...]) { _ in replacement }))
          }
        }
        if object[unexpectedFieldName] == nil {
          let field = pointer.appending(unexpectedFieldName)
          cases.append(
            BrokenCase(
              pointer: field, change: .added,
              payload: updating(example, at: field.tokens[...]) { _ in "zzz" }))
        }
        for (key, child) in object { visit(child, at: pointer.appending(key)) }
      case .array(let array):
        for (index, child) in array.enumerated() { visit(child, at: pointer.appending(index)) }
      default:
        break
      }
    }
    visit(example, at: .root)
    return cases
  }

  /// `value` with what's at `path` changed: `nil` from `change` removes it.
  private static func updating(
    _ value: JSONValue, at path: ArraySlice<String>, _ change: (JSONValue?) -> JSONValue?
  ) -> JSONValue {
    guard let token = path.first else { return change(value) ?? .null }
    switch value {
    case .object(var object):
      if path.count == 1 {
        object[token] = change(object[token])
      } else if let child = object[token] {
        object[token] = updating(child, at: path.dropFirst(), change)
      }
      return .object(object)
    case .array(var array):
      guard let index = Int(token), array.indices.contains(index) else { return value }
      array[index] = updating(array[index], at: path.dropFirst(), change)
      return .array(array)
    default:
      return value
    }
  }
}
