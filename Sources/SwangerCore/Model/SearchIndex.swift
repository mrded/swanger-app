import Foundation

/// Finds roots, fragments and fields by name, best matches first.
///
/// A field matches on its own name, never on the fields it sits inside. A dotted query, such as
/// `address.postcode`, matches fields whose path ends with those names: the last part as a name,
/// the parts before it exactly.
public struct SearchIndex: Sendable {
  public struct Result: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
      case root(RootID)
      case fragment(FragmentRef)
      /// A field inside a root, by its path from the root.
      case field(RootID, FieldPath)
    }

    public let target: Target
    /// The root's, fragment's or field's name.
    public let name: String
    /// For a field, the root it's in and the path to it: `NewOrder · customer.address`.
    public let detail: String?
  }

  /// How well a name matches, best first.
  enum Quality: Int, Comparable {
    case exact
    case prefix
    case wordStart
    case contains

    static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  private struct FieldEntry: Sendable {
    let root: RootSchema
    let path: FieldPath
    /// `path.fieldNames`, lower case.
    let names: [String]
  }

  private let roots: [RootSchema]
  private let fragments: [FragmentRef]
  private let fields: [FieldEntry]

  public init(spec: Spec) {
    roots = spec.roots
    fragments = spec.fragments.map(\.reference)
    var fields: [FieldEntry] = []
    for root in spec.roots {
      root.node.walk { _, path, _ in
        guard case .field = path.components.last else { return }
        fields.append(
          FieldEntry(root: root, path: path, names: path.fieldNames.map { $0.lowercased() }))
      }
    }
    self.fields = fields
  }

  public func search(_ query: String, limit: Int = 100) -> [Result] {
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return [] }
    var ranked: [(quality: Quality, kind: Int, depth: Int, order: Int, result: Result)] = []

    for (order, root) in roots.enumerated() {
      if let quality = Self.quality(of: root.name, for: query) {
        ranked.append(
          (quality, 0, 0, order, Result(target: .root(root.id), name: root.name, detail: nil)))
      }
    }
    for (order, fragment) in fragments.enumerated() {
      if let quality = Self.quality(of: fragment.name, for: query) {
        ranked.append(
          (
            quality, 1, 0, order,
            Result(target: .fragment(fragment), name: fragment.name, detail: nil)
          ))
      }
    }

    // `lines[].sku` reads as `lines.sku`.
    let parts = query.lowercased().replacingOccurrences(of: "[]", with: "")
      .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if let name = parts.last, !name.isEmpty {
      let parents = parts.dropLast()
      for (order, entry) in fields.enumerated() {
        guard entry.names.count > parents.count,
          entry.names.dropLast().suffix(parents.count).elementsEqual(parents),
          let fieldName = entry.path.fieldNames.last,
          let quality = Self.quality(of: fieldName, for: name)
        else { continue }
        let result = Result(
          target: .field(entry.root.id, entry.path), name: fieldName,
          detail: "\(entry.root.name) · \(entry.path)")
        ranked.append((quality, 2, entry.path.components.count, order, result))
      }
    }

    ranked.sort { lhs, rhs in
      (lhs.quality, lhs.kind, lhs.depth, lhs.order) < (rhs.quality, rhs.kind, rhs.depth, rhs.order)
    }
    return ranked.prefix(limit).map(\.result)
  }

  /// How well `name` matches `query`, ignoring case, or `nil` when it doesn't.
  static func quality(of name: String, for query: String) -> Quality? {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    if name.compare(query, options: options) == .orderedSame { return .exact }
    guard let first = name.range(of: query, options: options) else { return nil }
    if first.lowerBound == name.startIndex { return .prefix }
    var searchStart = name.startIndex
    while let match = name.range(of: query, options: options, range: searchStart..<name.endIndex) {
      if isWordStart(match.lowerBound, in: name) { return .wordStart }
      searchStart = name.index(after: match.lowerBound)
    }
    return .contains
  }

  /// After a separator such as `_` or a space, or the upper case letter of `camelCase`.
  private static func isWordStart(_ index: String.Index, in name: String) -> Bool {
    let previous = name[name.index(before: index)]
    let current = name[index]
    return !(previous.isLetter || previous.isNumber)
      || (previous.isLowercase && current.isUppercase)
  }
}
