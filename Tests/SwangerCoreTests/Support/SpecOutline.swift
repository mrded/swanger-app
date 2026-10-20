import Foundation

@testable import SwangerCore

/// The spec as indented text: each root and fragment with its fields, types and rules. Fragments
/// used inside another schema are named, not expanded, unless they're tightened there.
func outline(_ spec: Spec) -> String {
  var lines = [
    "\(spec.title ?? "Untitled") \(spec.apiVersion ?? "") (OpenAPI \(spec.declaredVersion))"
  ]
  for (heading, roots) in [
    ("Request schemas", spec.requestSchemas), ("Response schemas", spec.responseSchemas),
  ] {
    lines += ["", "# \(heading)"]
    for root in roots {
      let stats = root.stats
      lines += [
        "",
        "## \(root.name)",
        "used by: " + root.operations.map { "\($0) [\($0.mediaType)]" }.joined(separator: ", "),
        "stats: \(stats.fields) fields, \(stats.fragments) fragments, \(stats.rules) rules",
      ]
      for example in root.examples {
        let name = example.name.map { " \"\($0)\"" } ?? ""
        lines.append("example (\(example.source)\(name)): \(example.value)")
      }
      render(root.node, label: "(root)", into: &lines)
    }
  }
  lines += ["", "# Shared fragments"]
  for fragment in spec.fragments {
    lines += ["", "## \(fragment.name) (\(fragment.id))"]
    render(fragment.node, label: "(fragment)", into: &lines)
  }
  return lines.joined(separator: "\n") + "\n"
}

/// Every fragment, and each root and path it appears at.
func fragmentIndexOutline(_ spec: Spec) -> String {
  var lines: [String] = []
  for fragment in spec.fragments {
    lines.append("\(fragment.name)")
    for usage in spec.fragmentIndex.usages(of: fragment.reference) {
      let root = spec.root(usage.root).map { "\($0.direction) \($0.name)" } ?? "\(usage.root)"
      let path = usage.path.isEmpty ? "(root)" : usage.path.description
      let via = usage.via.map { "via \($0.name)" } ?? "direct"
      lines.append("  \(root) · \(path) · \(via)")
    }
  }
  return lines.joined(separator: "\n") + "\n"
}

private func render(
  _ node: SchemaNode,
  label: String,
  field: Field? = nil,
  depth: Int = 0,
  into lines: inout [String]
) {
  let indent = String(repeating: "  ", count: depth)
  var line = "\(indent)\(label)\(field?.isRequired == true ? "*" : ""): \(node.typeDescription)"
  var notes: [String] = []
  if field?.isForbidden == true { notes.append("forbidden") }
  if node.isTightened { notes.append("tightened") }
  if let definedIn = field?.definedIn { notes.append("from \(definedIn.name)") }
  if node.isReadOnly { notes.append("read only") }
  if let value = node.defaultValue { notes.append("default \(value)") }
  if case .recursive = node.kind { notes.append("recursive") }
  if case .unresolved(let ref, let failure) = node.kind {
    notes.append("unresolved \(ref): \(failure)")
  }
  if !notes.isEmpty { line += " [\(notes.joined(separator: ", "))]" }
  lines.append(line)
  for rule in node.rules {
    lines.append("\(indent)  - \(rule.text)")
  }

  // Fragments are shown on their own; only expand one used as it is at the top.
  guard depth == 0 || node.fragment == nil || node.isTightened else { return }
  switch node.kind {
  case .object(let object):
    for field in object.fields {
      render(field.node, label: field.name, field: field, depth: depth + 1, into: &lines)
    }
    if case .schema(let other) = object.additionalFields {
      render(other, label: "(other fields)", depth: depth + 1, into: &lines)
    }
  case .array(let array):
    for item in array.prefixItems {
      render(item, label: "[n]", depth: depth + 1, into: &lines)
    }
    if let items = array.items {
      render(items, label: "[]", depth: depth + 1, into: &lines)
    }
  case .choice(let choice):
    for variant in choice.variants {
      let value = variant.discriminatorValue.map { " = \($0)" } ?? ""
      render(variant.node, label: "(\(variant.name)\(value))", depth: depth + 1, into: &lines)
    }
  case .scalar, .recursive, .unresolved, .never:
    break
  }
}
