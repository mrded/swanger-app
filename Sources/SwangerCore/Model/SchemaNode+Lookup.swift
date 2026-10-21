import Foundation
import OrderedJSON

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

  /// The path to the nearest row the schema has for the value at `pointer` in `payload`, such as
  /// `lines[].sku` for `/lines/0/sku`. It climbs to the nearest field above when the schema has
  /// nothing there, such as for an unexpected field. Through a choice, it takes the variant whose
  /// discriminator value the payload has, else the first that has the next field.
  public func path(to pointer: JSONPointer, in payload: JSONValue) -> FieldPath {
    var node = self
    var value: JSONValue? = payload
    var path = FieldPath()
    for token in pointer.tokens {
      guard let (components, next) = node.step(token, in: value) else { break }
      path.components += components
      node = next
      value = value.flatMap { JSONPointer(tokens: [token]).value(in: $0) }
    }
    return path
  }

  /// The components from this node to its value for `token`, and the node there.
  private func step(_ token: String, in value: JSONValue?) -> ([FieldPath.Component], SchemaNode)? {
    switch kind {
    case .object(let object):
      if let field = object[field: token] { return ([.field(token)], field.node) }
      if let pattern = object.patternFields.first(where: {
        (try? NSRegularExpression(pattern: $0.pattern))?.firstMatch(
          in: token, range: NSRange(token.startIndex..., in: token)) != nil
      }) {
        return ([.patternField(pattern.pattern)], pattern.node)
      }
      if let step = stepIntoVariant(token, value) { return step }
      if case .schema(let other) = object.additionalFields { return ([.otherFields], other) }
      return nil
    case .array(let array):
      guard let index = Int(token), index >= 0 else { break }
      if index < array.prefixItems.count { return ([.prefixItem(index)], array.prefixItems[index]) }
      if let items = array.items { return ([.items], items) }
    case .scalar, .choice, .recursive, .unresolved, .never:
      break
    }
    return stepIntoVariant(token, value)
  }

  /// The step through the variant the payload most likely is, to its value for `token`.
  private func stepIntoVariant(_ token: String, _ value: JSONValue?)
    -> ([FieldPath.Component], SchemaNode)?
  {
    let choices = (choice.map { [$0] } ?? []) + choices
    // Variants the discriminators name first, then the other choices' variants.
    var named: [(index: Int, variant: Variant)] = []
    var others: [(index: Int, variant: Variant)] = []
    var index = 0
    for choice in choices {
      let variants = choice.variants.map { variant in
        defer { index += 1 }
        return (index: index, variant: variant)
      }
      let given = choice.discriminator.flatMap { value?.object?[$0] }
      let matching = variants.filter {
        $0.variant.discriminatorValue != nil && $0.variant.discriminatorValue == given
      }
      // A variant its choice's discriminator names is the only one of that choice tried, so a
      // field it hasn't isn't found in another variant the payload isn't.
      if matching.isEmpty { others += variants } else { named += matching }
    }
    for candidate in named + others {
      if let (components, node) = candidate.variant.node.step(token, in: value) {
        return ([.variant(candidate.variant.name, index: candidate.index)] + components, node)
      }
    }
    return nil
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
