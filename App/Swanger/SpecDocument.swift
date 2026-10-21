import SwiftUI
import UniformTypeIdentifiers

/// An OpenAPI file opened for viewing.
///
/// It holds nothing itself: the window's ``SpecStore`` reads the file from its URL, so that `$ref`s
/// to sibling files resolve and changes on disk are picked up. Swanger never writes specs.
struct SpecDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json, .yaml]
  static let writableContentTypes: [UTType] = []

  init() {}

  init(configuration: ReadConfiguration) throws {
    guard configuration.file.isRegularFile else { throw CocoaError(.fileReadCorruptFile) }
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    throw CocoaError(.featureUnsupported)
  }
}
