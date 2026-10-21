import Foundation
import OrderedJSON
import SwangerCore
import SwangerValidation
import Testing

enum Fixtures {
  /// The URL of a file under `Fixtures/`, such as `payments/spec.yaml`.
  static func url(_ path: String) -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures").appending(path: path)
  }

  /// A file under `SwangerCoreTests/Fixtures/`, read from the source tree.
  static func coreURL(_ path: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "SwangerCoreTests/Fixtures").appending(
        path: path)
  }

  /// Every spec fixture of both test targets.
  static let specs: [URL] =
    ["payments/spec.yaml", "legacy.yaml"].map(url)
    + [
      "model/spec.yaml", "model/composed.yaml", "refs/spec.yaml", "normalising/v30/spec.yaml",
      "normalising/v31/spec.yaml", "loading/petstore.yaml", "loading/petstore.json",
    ].map(coreURL)

  static func validator(_ path: String) throws -> PayloadValidator {
    PayloadValidator(spec: try Spec.load(url(path)))
  }

  /// A validator for a spec whose only request body is `schema`, written as JSON, with
  /// `components` as its `components/schemas`.
  static func inline(_ schema: String, components: String = "{}") throws -> (
    PayloadValidator, RootSchema
  ) {
    let text =
      #"{"openapi":"3.1.0","info":{"title":"Inline","version":"1"},"paths":{"/x":{"post":{"operationId":"x","requestBody":{"content":{"application/json":{"schema":\#(schema)}}},"responses":{"204":{"description":"ok"}}}}},"components":{"schemas":\#(components)}}"#
    let url = FileManager.default.temporaryDirectory.appending(
      path: "swanger-inline-\(UUID().uuidString).json")
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let spec = try Spec.load(url)
    return (PayloadValidator(spec: spec), try #require(spec.requestSchemas.first))
  }
}

extension Spec {
  /// The root an operation uses as its request body, or as its response body for `status`.
  func root(_ operationId: String, status: String? = nil) throws -> RootSchema {
    try #require(
      roots.first { root in
        root.operations.contains { $0.operationId == operationId && $0.status == status }
      }, "No root for \(operationId) \(status ?? "request")")
  }
}

func json(_ text: String) -> JSONValue {
  try! JSONValue.parse(text)
}
