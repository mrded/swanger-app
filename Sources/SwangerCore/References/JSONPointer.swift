import Foundation
import OrderedJSON

/// A JSON Pointer (RFC 6901), such as `/components/schemas/Pet`.
public struct JSONPointer: Hashable, Sendable, CustomStringConvertible {
  /// The pointer to the whole document, written as an empty string.
  public static let root = JSONPointer(tokens: [])

  /// The unescaped reference tokens: `/a~1b/c` is `["a/b", "c"]`.
  public let tokens: [String]

  public init(tokens: [String]) {
    self.tokens = tokens
  }

  /// Parses `""` or `/token/token`, unescaping `~1` to `/` and `~0` to `~`. Returns `nil` when the
  /// text doesn't start with `/` or has a `~` that isn't followed by `0` or `1`.
  public init?(_ text: String) {
    guard !text.isEmpty else {
      self = .root
      return
    }
    guard text.hasPrefix("/") else { return nil }
    var tokens: [String] = []
    for escaped in text.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      guard let token = Self.unescape(escaped) else { return nil }
      tokens.append(token)
    }
    self.tokens = tokens
  }

  public var isRoot: Bool { tokens.isEmpty }

  public func appending(_ token: String) -> JSONPointer {
    JSONPointer(tokens: tokens + [token])
  }

  public func appending(_ index: Int) -> JSONPointer {
    appending(String(index))
  }

  public var description: String {
    tokens.map { "/" + Self.escape($0) }.joined()
  }

  /// The value the pointer points to in `document`, or `nil` when there's nothing there.
  public func value(in document: JSONValue) -> JSONValue? {
    var current = document
    for token in tokens {
      switch current {
      case .object(let object):
        guard let child = object[token] else { return nil }
        current = child
      case .array(let array):
        guard let index = Self.arrayIndex(token), array.indices.contains(index) else { return nil }
        current = array[index]
      default:
        return nil
      }
    }
    return current
  }

  /// `0`, or a number without leading zeros. RFC 6901 doesn't allow `-` or `01`.
  private static func arrayIndex(_ token: String) -> Int? {
    guard let first = token.first, first.isASCII, first.isNumber,
      first != "0" || token.count == 1,
      token.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return Int(token)
  }

  private static func escape(_ token: String) -> String {
    token.replacing("~", with: "~0").replacing("/", with: "~1")
  }

  private static func unescape(_ escaped: Substring) -> String? {
    var token = ""
    var iterator = escaped.makeIterator()
    while let character = iterator.next() {
      guard character == "~" else {
        token.append(character)
        continue
      }
      switch iterator.next() {
      case "0": token.append("~")
      case "1": token.append("/")
      default: return nil
      }
    }
    return token
  }
}

/// A place in a file: the file, and a JSON Pointer to a value in it.
public struct NodeLocation: Hashable, Sendable, CustomStringConvertible {
  public let file: URL
  public let pointer: JSONPointer

  public init(file: URL, pointer: JSONPointer = .root) {
    self.file = file
    self.pointer = pointer
  }

  public func appending(_ token: String) -> NodeLocation {
    NodeLocation(file: file, pointer: pointer.appending(token))
  }

  public func appending(_ index: Int) -> NodeLocation {
    NodeLocation(file: file, pointer: pointer.appending(index))
  }

  /// `spec.yaml#/components/schemas/Pet`.
  public var description: String { "\(file.lastPathComponent)#\(pointer)" }
}
