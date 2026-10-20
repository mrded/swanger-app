import Foundation

/// A position in a source file. Both numbers start at 1.
public struct SourceLocation: Sendable, Hashable, CustomStringConvertible {
  public let line: Int
  public let column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }

  public var description: String { "\(line):\(column)" }
}

/// Why a file couldn't be opened as a spec.
public struct LoadError: Error, Sendable, Hashable {
  public enum Reason: Sendable, Hashable {
    /// The file couldn't be read, or isn't text.
    case unreadable(String)
    /// The file isn't valid JSON or YAML.
    case syntax(String)
    /// The file is Swagger 2.0 or an OpenAPI version other than 3.0 and 3.1, such as
    /// "Swagger 2.0" or "OpenAPI 3.2.0".
    case unsupportedVersion(found: String)
    /// The file parses but has no `openapi` field.
    case notOpenAPI
  }

  public let file: URL
  public let reason: Reason
  /// Where in the file the problem is, when it's known.
  public let location: SourceLocation?

  public init(file: URL, reason: Reason, location: SourceLocation? = nil) {
    self.file = file
    self.reason = reason
    self.location = location
  }

  public var line: Int? { location?.line }
  public var column: Int? { location?.column }

  /// A sentence describing the problem, without the file name or location.
  public var message: String {
    switch reason {
    case .unreadable(let message), .syntax(let message):
      message
    case .unsupportedVersion(let found):
      "\(found) isn't supported. Swanger opens OpenAPI 3.0 and 3.1 documents."
    case .notOpenAPI:
      "This isn't an OpenAPI document: it has no `openapi` field."
    }
  }
}

extension LoadError: CustomStringConvertible {
  /// `file.yaml:12:3: message`, as compilers print it.
  public var description: String {
    let position = location.map { ":\($0)" } ?? ""
    return "\(file.lastPathComponent)\(position): \(message)"
  }
}

extension LoadError: LocalizedError {
  public var errorDescription: String? { message }
}
