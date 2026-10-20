import Foundation
import OrderedCollections
import OrderedJSON
import Yams

/// Turns a YAML document into the same JSON tree its JSON equivalent would give.
///
/// Plain scalars are resolved with the YAML 1.2 core schema, as most OpenAPI tools do, rather than
/// Yams' YAML 1.1 defaults: `yes`, `no`, `on` and `off` stay strings, and so do dates. Mapping keys
/// are always strings, so a response code written as `200:` becomes `"200"`. Aliases arrive already
/// expanded by Yams, and `<<` merge keys are applied.
struct YAMLConverter {
  /// A document can't expand to more nodes than this, so a file that nests aliases inside aliases
  /// ("billion laughs") is refused instead of exhausting memory.
  static let nodeLimit = 20_000_000

  /// Yams resolves the tags of mapping keys while checking them for duplicates. With only the merge
  /// rule, a plain `<<` key is tagged `!!merge` and every other key `!!str`, while values keep the
  /// implicit tag and are resolved here with the core schema.
  private static let resolver = Resolver.basic.appending(.merge)

  let file: URL
  private var remainingNodes = Self.nodeLimit

  init(file: URL) {
    self.file = file
  }

  /// Parses `text` and converts its single document. An empty document is `null`.
  mutating func convert(_ text: String) throws(LoadError) -> JSONValue {
    let node: Node?
    do {
      node = try Yams.compose(yaml: text, Self.resolver)
    } catch let error as YamlError {
      throw loadError(for: error, in: text)
    } catch {
      throw LoadError(file: file, reason: .syntax(String(describing: error)))
    }
    guard let node else { return .null }
    return try value(of: node)
  }

  private mutating func value(of node: Node) throws(LoadError) -> JSONValue {
    remainingNodes -= 1
    guard remainingNodes >= 0 else {
      throw failure(
        "The document expands to too many values. Does it nest aliases in aliases?", at: node.mark)
    }
    switch node {
    case .scalar(let scalar):
      return try value(of: scalar)
    case .sequence(let sequence):
      var array: [JSONValue] = []
      array.reserveCapacity(sequence.count)
      for element in sequence {
        array.append(try value(of: element))
      }
      return .array(array)
    case .mapping(let mapping):
      return .object(try object(of: mapping))
    case .alias:
      // Yams replaces aliases with the node they point to while composing.
      throw failure("Unexpected alias", at: node.mark)
    }
  }

  private func value(of scalar: Node.Scalar) throws(LoadError) -> JSONValue {
    let text = scalar.string
    switch scalar.tagName {
    case .implicit:
      // A plain scalar without a tag. Quoted and block scalars arrive tagged `!!str`.
      return YAMLCoreSchema.resolve(text)
    case .null:
      guard YAMLCoreSchema.isNull(text) else {
        throw failure("`\(text)` isn't null", at: scalar.mark)
      }
      return .null
    case .bool:
      guard let bool = YAMLCoreSchema.bool(text) else {
        throw failure("`\(text)` isn't true or false", at: scalar.mark)
      }
      return .boolean(bool)
    case .int, .float:
      if let number = YAMLCoreSchema.number(text) { return .numberLiteral(number) }
      // JSON has no infinity or NaN, so they stay as written.
      guard YAMLCoreSchema.isInfinityOrNaN(text) else {
        throw failure("`\(text)` isn't a number", at: scalar.mark)
      }
      return .string(text)
    default:
      // `!!str`, the non-specific `!`, and tags JSON has no type for, such as `!!timestamp`.
      return .string(text)
    }
  }

  private mutating func object(
    of mapping: Node.Mapping
  ) throws(LoadError) -> OrderedDictionary<String, JSONValue> {
    // Yams has already refused keys that are equal in YAML; this catches ones that are only equal
    // as JSON keys, such as `200` and `'200'`. Like Yams, it points at the first one.
    var ownKeys: [String: Mark?] = [:]
    for (key, _) in mapping where !isMergeKey(key) {
      let name = try keyName(key)
      if let first = ownKeys[name] {
        throw failure(duplicateKeyMessage([name]), at: first)
      }
      ownKeys.updateValue(key.mark, forKey: name)
    }

    // Keys written in the mapping beat keys merged in with `<<`, wherever they appear in it.
    var object = OrderedDictionary<String, JSONValue>()
    for (key, value) in mapping {
      if isMergeKey(key) {
        for (name, merged) in try mergedEntries(value) where ownKeys[name] == nil {
          if object[name] == nil { object[name] = merged }
        }
      } else {
        object[try keyName(key)] = try self.value(of: value)
      }
    }
    return object
  }

  private func isMergeKey(_ key: Node) -> Bool {
    guard case .scalar(let scalar) = key else { return false }
    return scalar.tagName == .merge || (scalar.tagName == .implicit && scalar.string == "<<")
  }

  private func keyName(_ key: Node) throws(LoadError) -> String {
    guard case .scalar(let scalar) = key else {
      throw failure("Keys must be plain values, not lists or mappings", at: key.mark)
    }
    return scalar.string
  }

  /// The entries a `<<` key brings in: one mapping, or a list of them where earlier ones win.
  private mutating func mergedEntries(
    _ node: Node
  ) throws(LoadError) -> OrderedDictionary<String, JSONValue> {
    let sources: [Node.Mapping]
    switch node {
    case .mapping(let mapping):
      sources = [mapping]
    case .sequence(let sequence):
      var mappings: [Node.Mapping] = []
      for element in sequence {
        guard case .mapping(let mapping) = element else {
          throw failure("`<<` can only merge mappings", at: element.mark)
        }
        mappings.append(mapping)
      }
      sources = mappings
    default:
      throw failure("`<<` can only merge a mapping or a list of mappings", at: node.mark)
    }

    var entries = OrderedDictionary<String, JSONValue>()
    for source in sources {
      for (name, value) in try object(of: source) where entries[name] == nil {
        entries[name] = value
      }
    }
    return entries
  }

  private func duplicateKeyMessage(_ keys: [String]) -> String {
    let names = keys.map { "`\($0)`" }.joined(separator: ", ")
    return "Duplicate key \(names): it's used again later in the same mapping"
  }

  private func failure(_ message: String, at mark: Mark?) -> LoadError {
    LoadError(file: file, reason: .syntax(message), location: mark.flatMap(SourceLocation.init))
  }

  private func loadError(for error: YamlError, in text: String) -> LoadError {
    switch error {
    case .scanner(let context, let problem, let mark, _),
      .parser(let context, let problem, let mark, _),
      .composer(let context, let problem, let mark, _):
      if problem == "but found another document" {
        return failure(
          "A file can hold only one YAML document, but another one starts here", at: mark)
      }
      var message = problem.prefix(1).uppercased() + problem.dropFirst()
      // libyaml's contexts read "while scanning a simple key", and so on.
      if let context, context.text.hasPrefix("while ") {
        message += " (\(context.text) that starts on line \(context.mark.line))"
      }
      return failure(message, at: mark)
    case .reader(let problem, let offset, _, _):
      let location = offset.map { SourceLocation(utf8Offset: $0, in: text) }
      return LoadError(file: file, reason: .syntax(problem), location: location)
    case .duplicatedKeysInMapping(let duplicates, let context):
      return failure(duplicateKeyMessage(duplicates), at: context.mark)
    case .dataCouldNotBeDecoded:
      return LoadError(file: file, reason: .unreadable("The file isn't UTF-8 text."))
    default:
      return LoadError(file: file, reason: .syntax(String(describing: error)))
    }
  }
}

extension SourceLocation {
  fileprivate init?(_ mark: Mark) {
    // Yams uses line 0 when a node has no position.
    guard mark.line > 0 else { return nil }
    self.init(line: mark.line, column: mark.column)
  }

  fileprivate init(utf8Offset: Int, in text: String) {
    let prefix = text.utf8.prefix(utf8Offset)
    let lineStart = prefix.lastIndex(of: UInt8(ascii: "\n")).map { prefix.index(after: $0) }
    let line = prefix.count { $0 == UInt8(ascii: "\n") } + 1
    let column = prefix[(lineStart ?? prefix.startIndex)...].count + 1
    self.init(line: line, column: column)
  }
}

/// Plain scalar resolution from the YAML 1.2 core schema.
enum YAMLCoreSchema {
  static func resolve(_ text: String) -> JSONValue {
    if isNull(text) { return .null }
    if let bool = bool(text) { return .boolean(bool) }
    if let number = number(text) { return .numberLiteral(number) }
    return .string(text)
  }

  static func isNull(_ text: String) -> Bool {
    switch text {
    case "", "~", "null", "Null", "NULL": true
    default: false
    }
  }

  static func bool(_ text: String) -> Bool? {
    switch text {
    case "true", "True", "TRUE": true
    case "false", "False", "FALSE": false
    default: nil
    }
  }

  static func isInfinityOrNaN(_ text: String) -> Bool {
    switch text {
    case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF",
      ".nan", ".NaN", ".NAN":
      true
    default:
      false
    }
  }

  /// Reads a core-schema integer or float and spells it as JSON: `+12` is `12`, `007` is `7`,
  /// `.5` is `0.5`, `1.` is `1`, `0x1F` is `31` and `0o17` is `15`.
  static func number(_ text: String) -> JSONNumberLiteral? {
    let bytes = Array(text.utf8)
    if bytes.count > 2, bytes[0] == UInt8(ascii: "0") {
      let radix: Int? =
        switch bytes[1] {
        case UInt8(ascii: "x"): 16
        case UInt8(ascii: "o"): 8
        default: nil
        }
      if let radix {
        // Too large for 64 bits: left as a string rather than rounded.
        guard let value = UInt64(text.dropFirst(2), radix: radix) else { return nil }
        return try? JSONNumberLiteral(String(value))
      }
    }
    return decimal(bytes)
  }

  private static func decimal(_ bytes: [UInt8]) -> JSONNumberLiteral? {
    var index = 0
    func digits() -> ArraySlice<UInt8> {
      let start = index
      while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
        index += 1
      }
      return bytes[start..<index]
    }

    var negative = false
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
      negative = bytes[index] == UInt8(ascii: "-")
      index += 1
    }
    let integer = digits()
    var fraction: ArraySlice<UInt8> = []
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      index += 1
      fraction = digits()
    }
    guard !integer.isEmpty || !fraction.isEmpty else { return nil }

    var exponent = ""
    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      index += 1
      var sign = ""
      if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+")
      {
        sign = bytes[index] == UInt8(ascii: "-") ? "-" : "+"
        index += 1
      }
      let power = digits()
      guard !power.isEmpty else { return nil }
      exponent = "e" + sign + String(decoding: power, as: UTF8.self)
    }
    guard index == bytes.count else { return nil }

    let trimmed = integer.drop { $0 == UInt8(ascii: "0") }
    var literal = negative ? "-" : ""
    literal += trimmed.isEmpty ? "0" : String(decoding: trimmed, as: UTF8.self)
    if !fraction.isEmpty { literal += "." + String(decoding: fraction, as: UTF8.self) }
    literal += exponent
    return try? JSONNumberLiteral(literal)
  }
}

extension Node.Scalar {
  /// The tag as written, before Yams' resolver fills in implicit ones: `.implicit` for a plain
  /// scalar without a tag, `.str` for quoted and block scalars.
  fileprivate var tagName: Tag.Name { Tag.Name(rawValue: tag.rawValue) }
}
