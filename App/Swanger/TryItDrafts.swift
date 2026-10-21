import Foundation
import SwangerCore

/// Try it's edits, kept per spec file and schema across launches.
enum TryItDrafts {
  private static let key = "tryItDrafts"

  /// What was last typed for `schema` in the spec at `spec`, or `nil` when nothing was.
  static func draft(for schema: TryItSchema, in spec: URL) -> String? {
    all()[id(of: schema, in: spec)]
  }

  static func save(_ text: String, for schema: TryItSchema, in spec: URL) {
    var drafts = all()
    drafts[id(of: schema, in: spec)] = text
    UserDefaults.standard.set(drafts, forKey: key)
  }

  private static func all() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
  }

  /// The spec's path, then the schema: `/path/spec.yaml request spec.yaml#/components/…`.
  private static func id(of schema: TryItSchema, in spec: URL) -> String {
    let location: NodeLocation
    let kind: String
    switch schema {
    case .root(let id):
      kind = id.direction.rawValue
      location = id.location
    case .fragment(let id):
      kind = "fragment"
      location = id
    }
    // The schema's own file, in full, since a fragment can be in a sibling file.
    return [
      spec.standardizedFileURL.path, kind, location.file.standardizedFileURL.path,
      location.pointer.description,
    ].joined(separator: "\n")
  }
}

/// The schema a Try it page checks payloads against.
enum TryItSchema: Hashable {
  case root(RootID)
  case fragment(NodeLocation)
}
