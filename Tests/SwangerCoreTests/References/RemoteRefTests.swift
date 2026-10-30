import Foundation
import Testing

@testable import SwangerCore

/// A spec on a web server follows `$ref`s to other files on the web, and never to files on disk.
@Suite struct RemoteRefTests {
  private static let base = URL(string: "https://example.com/api/v1/")!

  private static let files: [String: String] = [
    "openapi.yaml": """
    openapi: 3.1.0
    info: {title: Remote, version: "1"}
    paths: {}
    components:
      schemas:
        Relative: {$ref: "common/types.yaml#/Tag"}
        Parent: {$ref: "../shared/types.yaml#/Id"}
        Absolute: {$ref: "https://other.example.com/types.yaml#/Name"}
        OnDisk: {$ref: "file:///etc/types.yaml"}
        Redirected: {$ref: "latest.yaml#/Tag"}
    """,
    "common/types.yaml": "Tag: {type: string}",
    "v2/types.yaml": "Tag: {$ref: 'names.yaml#/Name'}",
    "v2/names.yaml": "Name: {type: string}",
  ]

  /// Files the server redirects, to where it sends them.
  private static let redirects = ["latest.yaml": "v2/types.yaml"]

  /// The URLs asked for, in order.
  private final class Requests {
    var urls: [URL] = []
  }

  private let requests = Requests()
  private let resolver: RefResolver

  init() throws {
    let url = URL(string: "openapi.yaml", relativeTo: Self.base)!.absoluteURL
    let spec = try SpecLoader.parse(Data(Self.files["openapi.yaml"]!.utf8), from: url)
    let requests = self.requests
    resolver = RefResolver(root: spec, version: .v31) { url throws(LoadError) in
      requests.urls.append(url)
      var path = url.absoluteString.replacingOccurrences(of: Self.base.absoluteString, with: "")
      path = Self.redirects[path] ?? path
      guard let text = Self.files[path] else {
        throw LoadError(file: url, reason: .unreadable("Not found"))
      }
      return try SpecLoader.parse(Data(text.utf8), from: URL(string: path, relativeTo: Self.base)!)
    }
  }

  @Test func relativeRefIsDownloadedFromTheSameFolder() throws {
    let target = try #require(reference(of: "Relative"))

    #expect(
      target.origin?.location.file.absoluteString == "https://example.com/api/v1/common/types.yaml")
    #expect(target.origin?.name == "common/types.yaml#/Tag")
    #expect(resolver.schema(at: target.origin!.location) != nil)
  }

  @Test func dotDotIsStandardised() throws {
    _ = reference(of: "Parent")

    #expect(requests.urls.map(\.absoluteString) == ["https://example.com/api/shared/types.yaml"])
  }

  @Test func absoluteRefToAnotherServerIsFollowed() throws {
    _ = reference(of: "Absolute")

    #expect(requests.urls.map(\.absoluteString) == ["https://other.example.com/types.yaml"])
  }

  @Test func refToAFileOnDiskIsNotRead() throws {
    let target = try #require(reference(of: "OnDisk"))

    #expect(target == .unresolved(.remote("file:///etc/types.yaml")))
    #expect(requests.urls.isEmpty)
  }

  @Test func refsInARedirectedFileAreRelativeToWhereItWasRedirected() throws {
    let target = try #require(reference(of: "Redirected"))
    let tag = try #require(resolver.schema(at: target.origin!.location))
    let name = try #require(tag.object?.reference?.target)

    #expect(name.origin?.name == "v2/names.yaml#/Name")
    #expect(
      requests.urls.map(\.absoluteString) == [
        "https://example.com/api/v1/latest.yaml", "https://example.com/api/v1/v2/names.yaml",
      ])
  }

  @Test func remoteFileIsKnownByScheme() {
    #expect(RemoteFile.isRemote(URL(string: "https://example.com/a.yaml")!))
    #expect(RemoteFile.isRemote(URL(string: "HTTP://localhost:8080/a.json")!))
    #expect(!RemoteFile.isRemote(URL(filePath: "/specs/a.yaml")))
    #expect(!RemoteFile.isRemote(URL(string: "ftp://example.com/a.yaml")!))
  }

  private func reference(of component: String) -> Reference.Target? {
    let location = resolver.rootLocation.appending("components").appending("schemas")
      .appending(component)
    return resolver.schema(at: location)?.object?.reference?.target
  }
}
