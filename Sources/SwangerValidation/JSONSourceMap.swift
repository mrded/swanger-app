import SwangerCore

/// Where each value of a JSON text is, so an issue's pointer can be shown in the text.
///
/// Ranges are in UTF-16 code units, as `NSString` and `NSTextView` count them.
public struct JSONSourceMap: Sendable {
  /// Each value's range, from its first character to its last.
  private var values: [JSONPointer: Range<Int>] = [:]
  /// Each object member's key, quotes included.
  private var keys: [JSONPointer: Range<Int>] = [:]

  /// Maps `text`, or returns `nil` when it isn't valid JSON.
  public init?(_ text: String) {
    var scanner = Scanner(units: Array(text.utf16))
    scanner.skipSpace()
    guard scanner.value(at: .root, into: &self) else { return nil }
    scanner.skipSpace()
    guard scanner.isAtEnd else { return nil }
  }

  /// The range of the value at `pointer`, or `nil` when the text has nothing there.
  public func range(of pointer: JSONPointer) -> Range<Int>? {
    values[pointer]
  }

  /// What to select for an issue at `pointer`: the member (its key and value) or item that's
  /// there. When it isn't there, such as a missing field, the nearest value that is: its key, or
  /// its opening bracket for an item or the whole payload.
  public func selection(for pointer: JSONPointer) -> Range<Int> {
    if let value = values[pointer] {
      return keys[pointer].map { $0.lowerBound..<value.upperBound } ?? value
    }
    var tokens = pointer.tokens
    while !tokens.isEmpty {
      tokens.removeLast()
      let ancestor = JSONPointer(tokens: tokens)
      if let key = keys[ancestor] { return key }
      if let value = values[ancestor] { return value.lowerBound..<(value.lowerBound + 1) }
    }
    return 0..<0
  }

  /// Drops the values inside `pointer`'s.
  private mutating func forget(below pointer: JSONPointer) {
    let isInside = { (other: JSONPointer) in
      other.tokens.count > pointer.tokens.count && other.tokens.starts(with: pointer.tokens)
    }
    values = values.filter { !isInside($0.key) }
    keys = keys.filter { !isInside($0.key) }
  }

  /// The UTF-16 offset of a UTF-8 offset, such as `JSONParseError.byteOffset`. Inside a
  /// character, the character's start; past the end, the end.
  public static func offset(utf8Offset: Int, in text: String) -> Int {
    var bytes = 0
    var units = 0
    for scalar in text.unicodeScalars {
      bytes += UTF8.width(scalar)
      guard bytes <= utf8Offset else { break }
      units += UTF16.width(scalar)
    }
    return units
  }

  /// The UTF-16 offset of the bracket matching the one at `offset`, or `nil` when there's no
  /// bracket there, it's inside a string, or it has no match. Works on text that isn't valid
  /// JSON, as it's being typed.
  public static func matchingBracket(at offset: Int, in text: String) -> Int? {
    let units = Array(text.utf16)
    guard units.indices.contains(offset), [0x7B, 0x5B, 0x7D, 0x5D].contains(units[offset])
    else { return nil }
    var open: [Int] = []
    var inString = false
    var index = 0
    while index < units.count {
      let unit = units[index]
      if inString {
        if index == offset { return nil }
        if unit == 0x5C {
          index += 1
        } else if unit == 0x22 {
          inString = false
        }
      } else {
        switch unit {
        case 0x22:
          inString = true
        case 0x7B, 0x5B:
          open.append(index)
        case 0x7D, 0x5D:
          let opener = open.popLast()
          // A closer that doesn't match its opener is a mismatch, not a match.
          let pairs = opener.map { units[$0] == (unit == 0x7D ? 0x7B : 0x5B) } ?? false
          if index == offset { return pairs ? opener : nil }
          if opener == offset { return pairs ? index : nil }
        default:
          break
        }
      }
      index += 1
    }
    return nil
  }

  /// Reads one value after another, recording where each is. Only checks as much syntax as it
  /// needs to, but the text may not have been parsed: it's mapped again as it's being typed.
  private struct Scanner {
    /// Deeper than the parser allows, so whatever it parses can be mapped, but shallow enough
    /// not to run out of stack.
    static let maxDepth = 512

    let units: [UInt16]
    var index = 0
    var depth = 0

    var isAtEnd: Bool { index >= units.count }

    mutating func skipSpace() {
      while !isAtEnd, [0x20, 0x09, 0x0A, 0x0D].contains(units[index]) { index += 1 }
    }

    mutating func value(at pointer: JSONPointer, into map: inout JSONSourceMap) -> Bool {
      guard !isAtEnd, depth < Self.maxDepth else { return false }
      depth += 1
      defer { depth -= 1 }
      let start = index
      switch units[index] {
      case 0x7B:  // {
        guard object(at: pointer, into: &map) else { return false }
      case 0x5B:  // [
        guard array(at: pointer, into: &map) else { return false }
      case 0x22:  // "
        guard string() != nil else { return false }
      default:
        // A number, `true`, `false` or `null`.
        while !isAtEnd, !Self.ends(units[index]) { index += 1 }
        guard index > start else { return false }
      }
      map.values[pointer] = start..<index
      return true
    }

    private mutating func object(at pointer: JSONPointer, into map: inout JSONSourceMap) -> Bool {
      index += 1
      skipSpace()
      if !isAtEnd, units[index] == 0x7D {
        index += 1
        return true
      }
      while true {
        skipSpace()
        let keyStart = index
        guard !isAtEnd, units[index] == 0x22, let key = string() else { return false }
        let member = pointer.appending(key)
        // A key said twice keeps its last value, as the parser does, so the first one's
        // values inside are gone too.
        if map.values[member] != nil { map.forget(below: member) }
        map.keys[member] = keyStart..<index
        skipSpace()
        guard !isAtEnd, units[index] == 0x3A else { return false }
        index += 1
        skipSpace()
        guard value(at: member, into: &map) else { return false }
        skipSpace()
        guard !isAtEnd else { return false }
        index += 1
        if units[index - 1] == 0x7D { return true }
        guard units[index - 1] == 0x2C else { return false }
      }
    }

    private mutating func array(at pointer: JSONPointer, into map: inout JSONSourceMap) -> Bool {
      index += 1
      skipSpace()
      if !isAtEnd, units[index] == 0x5D {
        index += 1
        return true
      }
      var count = 0
      while true {
        skipSpace()
        guard value(at: pointer.appending(count), into: &map) else { return false }
        count += 1
        skipSpace()
        guard !isAtEnd else { return false }
        index += 1
        if units[index - 1] == 0x5D { return true }
        guard units[index - 1] == 0x2C else { return false }
      }
    }

    /// Reads a string from its opening quote, and returns it unescaped.
    private mutating func string() -> String? {
      index += 1
      var decoded: [UInt16] = []
      while !isAtEnd {
        let unit = units[index]
        index += 1
        switch unit {
        case 0x22:
          return String(decoding: decoded, as: UTF16.self)
        case 0x5C:
          guard !isAtEnd else { return nil }
          let escape = units[index]
          index += 1
          switch escape {
          case 0x62: decoded.append(0x08)  // b
          case 0x66: decoded.append(0x0C)  // f
          case 0x6E: decoded.append(0x0A)  // n
          case 0x72: decoded.append(0x0D)  // r
          case 0x74: decoded.append(0x09)  // t
          case 0x75:  // u
            guard index + 4 <= units.count,
              let code = UInt16(
                String(decoding: units[index..<index + 4], as: UTF16.self),
                radix: 16)
            else { return nil }
            decoded.append(code)
            index += 4
          default: decoded.append(escape)  // " \ /
          }
        default:
          decoded.append(unit)
        }
      }
      return nil
    }

    /// Whether `unit` ends a number or literal.
    private static func ends(_ unit: UInt16) -> Bool {
      [0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(unit)
    }
  }
}
