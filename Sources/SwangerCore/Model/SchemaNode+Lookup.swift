extension SchemaNode {
  /// The variants of the node's own choice, then of the choices beside its shape, in the order
  /// ``FieldPath/Component/variant(_:index:)`` counts them.
  public var variants: [Variant] {
    (choice?.variants ?? []) + choices.flatMap(\.variants)
  }

  /// The node `path` leads to from this one, or `nil` when there's nothing there.
  public func node(at path: FieldPath) -> SchemaNode? {
    var node = self
    for component in path.components {
      guard let next = node.child(component) else { return nil }
      node = next
    }
    return node
  }

  /// The field `path` ends at, or `nil` when it ends at an item, a variant or unlisted fields.
  public func field(at path: FieldPath) -> Field? {
    guard case .field(let name) = path.components.last else { return nil }
    return node(at: FieldPath(path.components.dropLast()))?.object?[field: name]
  }

  private func child(_ component: FieldPath.Component) -> SchemaNode? {
    switch component {
    case .field(let name):
      return object?[field: name]?.node
    case .items:
      return array?.items
    case .prefixItem(let index):
      return array?.prefixItems.indices.contains(index) == true ? array?.prefixItems[index] : nil
    case .variant(let name, let index):
      // The name too, so a path kept from before a reload doesn't land on another variant.
      guard variants.indices.contains(index), variants[index].name == name else { return nil }
      return variants[index].node
    case .otherFields:
      if case .schema(let other) = object?.additionalFields { return other }
      return nil
    case .patternField(let pattern):
      return object?.patternFields.first { $0.pattern == pattern }?.node
    }
  }
}
