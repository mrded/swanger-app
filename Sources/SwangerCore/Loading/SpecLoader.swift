import Foundation
import OrderedJSON

/// Reads JSON and YAML files into ``SourceDocument``s, and checks that a spec is OpenAPI 3.0 or 3.1.
public enum SpecLoader {
  /// Reads and parses the spec at `url`, and checks its version.
  public static func load(_ url: URL) throws(LoadError) -> OpenAPIDocument {
    try openAPIDocument(from: loadDocument(url))
  }

  /// Reads and parses any JSON or YAML file, such as one a spec refers to with a `$ref`.
  public static func loadDocument(_ url: URL) throws(LoadError) -> SourceDocument {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw LoadError(file: url, reason: .unreadable(error.localizedDescription))
    }
    return try parse(data, from: url)
  }

  /// Parses file contents already in memory.
  ///
  /// - Parameter format: The syntax to read. When `nil`, it's taken from the file's extension, or
  ///   guessed from the text when the extension doesn't say.
  public static func parse(
    _ data: Data,
    from url: URL,
    format: SourceFormat? = nil
  ) throws(LoadError) -> SourceDocument {
    let text = try decodeText(data, from: url)
    let format =
      format ?? SourceFormat(pathExtension: url.pathExtension) ?? SourceFormat(sniffing: text)
    let root: JSONValue
    switch format {
    case .json:
      do {
        root = try JSONValue.parse(text)
      } catch let error as JSONParseError {
        let location = SourceLocation(line: error.line, column: error.column)
        throw LoadError(file: url, reason: .syntax(error.message), location: location)
      } catch {
        throw LoadError(file: url, reason: .syntax(String(describing: error)))
      }
    case .yaml:
      var converter = YAMLConverter(file: url)
      root = try converter.convert(text)
    }
    return SourceDocument(url: url, format: format, root: root)
  }

  /// Checks a parsed file is an OpenAPI 3.0 or 3.1 document.
  public static func openAPIDocument(
    from source: SourceDocument
  ) throws(LoadError) -> OpenAPIDocument {
    let fields = source.root.object
    if let openapi = fields?["openapi"] {
      let declared = versionText(openapi)
      guard let version = OpenAPIVersion(declared: declared) else {
        throw LoadError(file: source.url, reason: .unsupportedVersion(found: "OpenAPI \(declared)"))
      }
      return OpenAPIDocument(source: source, version: version, declaredVersion: declared)
    }
    if let swagger = fields?["swagger"] {
      throw LoadError(
        file: source.url,
        reason: .unsupportedVersion(found: "Swagger \(versionText(swagger))")
      )
    }
    throw LoadError(file: source.url, reason: .notOpenAPI)
  }

  /// The version as written. In YAML, an unquoted `openapi: 3.0` is a number, not a string.
  private static func versionText(_ value: JSONValue) -> String {
    switch value {
    case .string(let text): text
    case .numberLiteral(let number): number.rawValue
    default: value.description
    }
  }

  /// Decodes UTF-8 (with or without a byte order mark) or UTF-16 with a byte order mark.
  private static func decodeText(_ data: Data, from url: URL) throws(LoadError) -> String {
    let text: String?
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      text = String(data: data.dropFirst(3), encoding: .utf8)
    } else if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
      text = String(data: data, encoding: .utf16)
    } else {
      text = String(data: data, encoding: .utf8)
    }
    guard let text else {
      throw LoadError(file: url, reason: .unreadable("The file isn't UTF-8 text."))
    }
    return text
  }
}
