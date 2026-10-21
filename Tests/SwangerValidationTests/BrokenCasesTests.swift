import Foundation
import OrderedJSON
import SwangerCore
import Testing

@testable import SwangerValidation

@Suite struct BrokenCasesTests {
  @Test func eachFieldRemovedReplacedAndEachObjectGivenAnExtraField() {
    let cases = BrokenCases.cases(from: json(#"{"a":1,"b":{"c":"zzz"}}"#))
    let replaced = { (field: String) in
      [#""""#, "7", #""zzz""#, "null", "{}", "[]"].map { "\(field) set to \($0)" }
    }
    #expect(
      cases.map(\.description)
        == ["/a removed"] + replaced("/a") + ["/b removed"] + replaced("/b")
        + ["/unexpectedField added", "/b/c removed"]
        + replaced("/b/c").filter { !$0.hasSuffix(#""zzz""#) } + ["/b/unexpectedField added"])
    let removed = cases.first { $0.description == "/b/c removed" }
    #expect(removed?.payload == json(#"{"a":1,"b":{}}"#))
    let added = cases.first { $0.description == "/b/unexpectedField added" }
    #expect(added?.payload == json(#"{"a":1,"b":{"c":"zzz","unexpectedField":"zzz"}}"#))
  }

  @Test func reachesIntoArrays() {
    let cases = BrokenCases.cases(from: json(#"[{"a":1}]"#))
    #expect(cases.first?.description == "/0/a removed")
    #expect(cases.first?.payload == json("[{}]"))
  }

  /// Every broken copy of every fixture example is reported where it was broken: a field the
  /// model says is required is missing, a value of a type the model doesn't allow is the wrong
  /// type, and a field a closed object doesn't list is unexpected.
  @Test(arguments: Fixtures.specs)
  func brokenExamplesReportWhereTheyBreak(_ url: URL) throws {
    let spec = try Spec.load(url)
    let validator = PayloadValidator(spec: spec)
    // Roots and fragments, with their own examples.
    let schemas =
      spec.roots.map { ($0.name, $0.node, $0.id.location, $0.examples.map(\.value)) }
      + spec.fragments.map { ($0.name, $0.node, $0.reference.id, $0.node.examples) }
    var checked = 0
    for (name, node, location, examples) in schemas {
      for example in examples {
        for broken in BrokenCases.cases(from: example) {
          checked += 1
          let issues = validator.issues(in: broken.payload, forSchemaAt: location)
          let context = "\(name): \(broken) gave \(issues)"
          if let kind = Self.expectedKind(of: broken, in: node, spec: spec) {
            #expect(
              issues.contains { $0.kind == kind && $0.pointer == broken.pointer },
              "expected \(kind.rawValue) at \(broken.pointer). \(context)")
          }
          guard !issues.isEmpty else { continue }
          // A choice of fields, such as "needs `email` or `phone`", names the first.
          #expect(
            issues.contains {
              $0.pointer.tokens.starts(with: broken.pointer.tokens)
                || $0.kind == .missing
                  && $0.pointer.tokens.dropLast() == broken.pointer.tokens.dropLast()
            }, "nothing reported at or inside the change. \(context)")
          for issue in issues {
            let parent = SwangerCore.JSONPointer(tokens: issue.pointer.tokens.dropLast())
            if issue.kind == .missing {
              #expect(
                issue.pointer.value(in: broken.payload) == nil
                  && parent.value(in: broken.payload)?.object != nil,
                "a missing field that's there. \(context)")
            } else {
              #expect(
                issue.pointer.value(in: broken.payload) != nil,
                "an issue outside the payload. \(context)")
            }
          }
        }
      }
    }
    print("\(url.lastPathComponent): \(checked) broken cases")
  }

  /// The kind of issue the model says `broken` must give at its pointer, when it's clear.
  private static func expectedKind(of broken: BrokenCase, in root: SchemaNode, spec: Spec)
    -> ValidationIssue.Kind?
  {
    let tokens = broken.pointer.tokens
    guard let name = tokens.last,
      let parent = node(at: tokens.dropLast(), in: root, spec: spec)?.object
    else { return nil }
    switch broken.change {
    case .removed:
      return parent[field: name]?.isRequired == true ? .missing : nil
    case .added:
      return parent[field: name] == nil && parent.patternFields.isEmpty
        && parent.additionalFields == .forbidden ? .unexpectedField : nil
    case .replaced(let value):
      guard let field = parent[field: name], !field.isForbidden else { return nil }
      let node = resolved(field.node, spec: spec)
      if value == .null, node.allowsNull { return nil }
      guard node.choices.isEmpty, !node.isShapeInferred else { return nil }
      let types: [String]
      switch node.kind {
      case .scalar(let scalar): types = scalar.types
      case .object: types = ["object"]
      case .array: types = ["array"]
      default: return nil
      }
      guard !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) else {
        return nil
      }
      return .wrongType
    }
  }

  /// The node at `tokens` in a payload `root` describes, through objects' own fields and arrays,
  /// but not into choices.
  private static func node(at tokens: ArraySlice<String>, in root: SchemaNode, spec: Spec)
    -> SchemaNode?
  {
    let node = resolved(root, spec: spec)
    guard let token = tokens.first else { return node }
    switch node.kind {
    case .object(let object):
      guard let field = object[field: token] else { return nil }
      return self.node(at: tokens.dropFirst(), in: field.node, spec: spec)
    case .array(let array):
      guard let index = Int(token),
        let item = index < array.prefixItems.count ? array.prefixItems[index] : array.items
      else { return nil }
      return self.node(at: tokens.dropFirst(), in: item, spec: spec)
    default:
      return nil
    }
  }

  private static func resolved(_ node: SchemaNode, spec: Spec) -> SchemaNode {
    if case .recursive(let fragment) = node.kind, let target = spec.fragment(fragment) {
      return target.node
    }
    return node
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("null", .null), ("boolean", .boolean), ("string", .string), ("number", .numberLiteral),
      ("object", .object), ("array", .array):
      true
    case ("integer", .numberLiteral(let number)): number.isInteger
    default: false
    }
  }
}
