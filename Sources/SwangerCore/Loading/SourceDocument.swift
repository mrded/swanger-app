import Foundation
import OrderedJSON

/// The syntax a file is written in.
public enum SourceFormat: Sendable, Hashable {
  case json
  case yaml

  /// The format a file's extension promises, or `nil` when it doesn't say.
  init?(pathExtension: String) {
    switch pathExtension.lowercased() {
    case "json": self = .json
    case "yaml", "yml": self = .yaml
    default: return nil
    }
  }

  /// Guesses the format from the text: JSON documents start with `{` or `[`, anything else is
  /// read as YAML (which is close to a superset of JSON anyway).
  init(sniffing text: String) {
    let first = text.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
    self = first == "{" || first == "[" ? .json : .yaml
  }
}

/// One parsed file: the spec itself, or a file it refers to with a `$ref`.
public struct SourceDocument: Sendable {
  public let url: URL
  public let format: SourceFormat
  /// The file's contents, with object keys in the order the file gives them.
  public let root: JSONValue

  public init(url: URL, format: SourceFormat, root: JSONValue) {
    self.url = url
    self.format = format
    self.root = root
  }
}

/// The OpenAPI versions Swanger reads.
public enum OpenAPIVersion: String, Sendable, Hashable {
  case v30 = "3.0"
  case v31 = "3.1"

  /// Reads the `openapi` field, such as `3.0.3` or `3.1.0`. Patch versions and suffixes are
  /// accepted; other major and minor versions aren't.
  init?(declared: String) {
    let parts = declared.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts[0] == "3" else { return nil }
    switch parts[1] {
    case "0": self = .v30
    case "1": self = .v31
    default: return nil
    }
  }
}

/// A spec file that has been parsed and checked to be OpenAPI 3.0 or 3.1.
public struct OpenAPIDocument: Sendable {
  public let source: SourceDocument
  public let version: OpenAPIVersion
  /// The `openapi` field as written, such as `3.1.0`.
  public let declaredVersion: String

  public var url: URL { source.url }
  public var root: JSONValue { source.root }
}
