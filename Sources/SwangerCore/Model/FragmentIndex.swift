import OrderedCollections

/// The way from a root to a value inside it: `customer.address`, `lines[].sku`, `point[0]`,
/// `payment(Card).cardNumber`, `metadata.*` or `extensions./^x-/`.
public struct FieldPath: Hashable, Sendable, CustomStringConvertible {
  public enum Component: Hashable, Sendable {
    case field(String)
    /// An item of an array, from `items`.
    case items
    /// The item at one position of an array, from `prefixItems`.
    case prefixItem(Int)
    /// One variant of a `oneOf` or `anyOf`: its name, and its position among the node's
    /// variants (``SchemaNode/variants``), since two variants can share a name.
    case variant(String, index: Int)
    /// The value of any field not listed, from `additionalProperties`.
    case otherFields
    /// The value of a field whose name matches a `patternProperties` pattern.
    case patternField(String)
  }

  public var components: [Component]

  public init(_ components: [Component] = []) {
    self.components = components
  }

  public func appending(_ component: Component) -> FieldPath {
    FieldPath(components + [component])
  }

  public var isEmpty: Bool { components.isEmpty }

  /// The field names alone, without items, variants and unlisted fields.
  public var fieldNames: [String] {
    components.compactMap { if case .field(let name) = $0 { name } else { nil } }
  }

  public var description: String {
    var text = ""
    for component in components {
      switch component {
      case .field(let name): text += text.isEmpty ? name : ".\(name)"
      case .items: text += "[]"
      case .prefixItem(let index): text += "[\(index)]"
      case .variant(let name, _): text += "(\(name))"
      case .otherFields: text += text.isEmpty ? "*" : ".*"
      case .patternField(let pattern): text += text.isEmpty ? "/\(pattern)/" : "./\(pattern)/"
      }
    }
    return text
  }
}

/// One place a fragment appears in a root.
public struct FragmentUsage: Hashable, Sendable {
  public let root: RootID
  /// From the root to the fragment. Empty when the root is the fragment.
  public let path: FieldPath
  /// The fragment this one is inside, or `nil` when the root uses it directly.
  public let via: FragmentRef?

  public var isDirect: Bool { via == nil }
}

/// For each fragment, every root and path where it appears, directly or inside other fragments.
public struct FragmentIndex: Sendable {
  public enum Use: Sendable {
    /// The root uses the fragment itself somewhere.
    case direct
    /// The fragment is only inside other fragments the root uses.
    case nested
  }

  private var usages: [NodeLocation: [FragmentUsage]] = [:]

  init(roots: [RootSchema]) {
    for root in roots {
      root.node.walk { node, path, inside in
        for fragment in node.fragmentsUsed {
          // A base the node's fields come from is inside the node's own fragment, if it has one.
          let isBase = fragment != node.fragment && !path.isEmpty
          let via = isBase ? node.fragment ?? inside : inside
          usages[fragment.id, default: []].append(
            FragmentUsage(root: root.id, path: path, via: via))
        }
      }
    }
  }

  /// Every place `fragment` appears, root by root.
  public func usages(of fragment: FragmentRef) -> [FragmentUsage] {
    usages[fragment.id] ?? []
  }

  /// The roots that use `fragment`, directly or not, in the order the spec gives them.
  public func roots(using fragment: FragmentRef) -> [RootID] {
    Array(OrderedSet(usages(of: fragment).map(\.root)))
  }

  /// How `root` uses `fragment`, or `nil` when it doesn't.
  public func use(of fragment: FragmentRef, in root: RootID) -> Use? {
    let inRoot = usages(of: fragment).filter { $0.root == root }
    if inRoot.isEmpty { return nil }
    return inRoot.contains(where: \.isDirect) ? .direct : .nested
  }
}
