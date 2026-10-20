import Foundation
import OrderedJSON
import Testing

@testable import SwangerCore

@Suite struct SpecLoaderTests {
  @Test func jsonAndYAMLLoadToEqualTrees() throws {
    let json = try SpecLoader.load(Fixtures.url("loading/petstore.json"))
    let yaml = try SpecLoader.load(Fixtures.url("loading/petstore.yaml"))

    #expect(json.source.format == .json)
    #expect(yaml.source.format == .yaml)
    #expect(json.root == yaml.root)
    // `JSONValue` equality ignores key order, so compare that separately.
    #expect(keyPaths(json.root) == keyPaths(yaml.root))
  }

  @Test(arguments: ["loading/petstore.json", "loading/petstore.yaml"])
  func keyOrderIsPreserved(path: String) throws {
    let spec = try SpecLoader.load(Fixtures.url(path))
    let pet = spec.root.object?["components"]?.object?["schemas"]?.object?["Pet"]?.object
    let properties = pet?["properties"]?.object

    #expect(
      properties.map { Array($0.keys) } == [
        "name", "kind", "id", "weight", "born", "vaccinated", "nickname", "tags",
      ])
    #expect(spec.root.object.map { Array($0.keys) } == ["openapi", "info", "paths", "components"])
  }

  @Test(arguments: ["loading/petstore.json", "loading/petstore.yaml"])
  func readsTheVersion(path: String) throws {
    let spec = try SpecLoader.load(Fixtures.url(path))

    #expect(spec.version == .v31)
    #expect(spec.declaredVersion == "3.1.0")
  }

  @Test func badYAMLReportsItsLine() throws {
    let url = Fixtures.url("loading/bad.yaml")
    let error = try #require(throws: LoadError.self) { try SpecLoader.load(url) }

    guard case .syntax = error.reason else {
      Issue.record("Expected a syntax error, got \(error.reason)")
      return
    }
    #expect(error.file == url)
    #expect(error.line == 9)
    #expect(error.description.hasPrefix("bad.yaml:9:"))
  }

  @Test func badJSONReportsItsLine() throws {
    let error = try #require(throws: LoadError.self) {
      try SpecLoader.load(Fixtures.url("loading/bad.json"))
    }

    guard case .syntax = error.reason else {
      Issue.record("Expected a syntax error, got \(error.reason)")
      return
    }
    #expect(error.line == 6)
  }

  @Test func swagger2IsRefused() throws {
    let error = try #require(throws: LoadError.self) {
      try SpecLoader.load(Fixtures.url("loading/swagger2.yaml"))
    }

    #expect(error.reason == .unsupportedVersion(found: "Swagger 2.0"))
    #expect(error.message.contains("OpenAPI 3.0 and 3.1"))
  }

  @Test(arguments: [
    ("openapi: 3.0.3", OpenAPIVersion.v30),
    ("openapi: 3.0.0", .v30),
    ("openapi: 3.1.1", .v31),
    ("openapi: '3.1.0'", .v31),
    // Unquoted, YAML reads this as the number 3.0.
    ("openapi: 3.0", .v30),
  ])
  func acceptsOpenAPI30And31(line: String, version: OpenAPIVersion) throws {
    let spec = try SpecLoader.openAPIDocument(from: parseYAML(line))

    #expect(spec.version == version)
  }

  @Test(arguments: [
    ("openapi: 3.2.0", "OpenAPI 3.2.0"),
    ("openapi: 2.0", "OpenAPI 2.0"),
    ("openapi: '4.0.0'", "OpenAPI 4.0.0"),
    ("swagger: '1.2'", "Swagger 1.2"),
  ])
  func refusesOtherVersions(line: String, found: String) throws {
    let document = try parseYAML(line)
    let error = try #require(throws: LoadError.self) {
      try SpecLoader.openAPIDocument(from: document)
    }

    #expect(error.reason == .unsupportedVersion(found: found))
  }

  @Test(arguments: ["title: Not a spec", "- a list", "just text", ""])
  func refusesFilesWithoutAnOpenAPIField(text: String) throws {
    let document = try parseYAML(text)
    let error = try #require(throws: LoadError.self) {
      try SpecLoader.openAPIDocument(from: document)
    }

    #expect(error.reason == .notOpenAPI)
  }

  @Test func missingFileIsUnreadable() throws {
    let error = try #require(throws: LoadError.self) {
      try SpecLoader.load(Fixtures.url("loading/missing.yaml"))
    }

    guard case .unreadable = error.reason else {
      Issue.record("Expected an unreadable error, got \(error.reason)")
      return
    }
  }

  @Test func formatComesFromTheExtension() throws {
    // JSON is valid YAML, so a `.yaml` file containing JSON is read as YAML, and the result
    // is the same.
    let text = #"{"openapi": "3.0.3", "info": {"title": "T"}}"#
    let asYAML = try parse(text, file: "spec.yaml")
    let asJSON = try parse(text, file: "spec.JSON")

    #expect(asYAML.format == .yaml)
    #expect(asJSON.format == .json)
    #expect(asYAML.root == asJSON.root)
  }

  @Test(arguments: [
    ("  \n{\"openapi\": \"3.0.3\"}", SourceFormat.json),
    ("[1, 2]", .json),
    ("openapi: 3.0.3", .yaml),
    ("# comment\n{a: 1}", .yaml),
  ])
  func formatIsSniffedWithoutAKnownExtension(text: String, format: SourceFormat) throws {
    #expect(try parse(text, file: "spec").format == format)
    #expect(try parse(text, file: "spec.txt").format == format)
  }

  @Test func byteOrderMarkIsSkipped() throws {
    let data = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"openapi": "3.1.0"}"#.utf8)
    let document = try SpecLoader.parse(data, from: URL(filePath: "/specs/spec.json"))

    #expect(document.root == ["openapi": "3.1.0"])
  }

  @Test func textThatIsNotUTF8IsUnreadable() throws {
    let data = Data([0x6F, 0x70, 0xFF, 0xFE, 0x00, 0xC3])
    let error = try #require(throws: LoadError.self) {
      try SpecLoader.parse(data, from: URL(filePath: "/specs/spec.yaml"))
    }

    #expect(error.reason == .unreadable("The file isn't UTF-8 text."))
  }

  private func parse(_ text: String, file: String) throws -> SourceDocument {
    try SpecLoader.parse(Data(text.utf8), from: URL(filePath: "/specs/\(file)"))
  }

  private func parseYAML(_ text: String) throws -> SourceDocument {
    try parse(text, file: "spec.yaml")
  }
}
