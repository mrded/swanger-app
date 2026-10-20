import Foundation
import OrderedJSON
import Testing

@testable import SwangerCore

@Suite struct RefResolverTests {
  /// Counts how often each file is loaded.
  private final class LoadCounter {
    var counts: [String: Int] = [:]
  }

  private let counter = LoadCounter()
  private let resolver: RefResolver

  init() throws {
    let spec = try SpecLoader.loadDocument(Fixtures.url("refs/spec.yaml"))
    let counter = self.counter
    resolver = RefResolver(root: spec, version: .v31) { url throws(LoadError) in
      counter.counts[url.lastPathComponent, default: 0] += 1
      return try SpecLoader.loadDocument(url)
    }
  }

  // MARK: - Following references

  @Test func localRefLinksToTheComponent() throws {
    let owner = try property("owner", of: "Pet")
    let reference = try #require(owner.object?.reference)

    #expect(reference.ref == "#/components/schemas/Person")
    #expect(reference.target.origin?.name == "Person")
    #expect(reference.target.origin?.location == component("Person"))
    if case .link = reference.target {
    } else {
      Issue.record("Expected a link, got \(reference.target)")
    }
    // Keywords beside `$ref` are kept.
    #expect(owner.object?["description"] == .value("Who looks after the pet."))
  }

  @Test(arguments: [("slash", "a/b"), ("tilde", "til~de"), ("space", "My Schema")])
  func pointerEscapesAreDecoded(property name: String, component: String) throws {
    let schema = try property(name, of: "Escapes")

    #expect(schema.object?.reference?.target.origin?.name == component)
  }

  @Test func crossFileRefIsResolvedAgainstTheSpec() throws {
    let address = try property("address", of: "Pet")
    let origin = try #require(address.object?.reference?.target.origin)

    #expect(origin.name == "common/address.yaml")
    #expect(origin.location.file == Fixtures.url("refs/common/address.yaml").standardizedFileURL)
    #expect(origin.location.pointer == .root)

    let tags = try property("tags", of: "Pet")
    let items = try #require(tags.object?["items"]?.schema)
    #expect(items.object?.reference?.target.origin?.name == "common/types.yaml#/Tag")
  }

  @Test func refsInsideReferencedFilesAreRelativeToThatFile() throws {
    let address = try #require(
      try property("address", of: "Pet").object?.reference?.target.origin?.location)
    let schema = try #require(resolver.schema(at: address))
    let properties = try #require(schema.object?["properties"]?.schemaMap)

    #expect(
      properties["postcode"]?.object?.reference?.target.origin?.name
        == "common/types.yaml#/Postcode")
    #expect(
      properties["country"]?.object?.reference?.target.origin?.name
        == "common/address.yaml#/$defs/Country")
  }

  @Test func refBackIntoTheSpecUsesTheComponentName() throws {
    let response = try resolver.dereference(
      operation().appending("responses").appending("201")
    ).get()
    let schemaLocation = response.appending("content").appending("application/json")
      .appending("schema")
    let schema = try #require(resolver.schema(at: schemaLocation))

    #expect(response.description == "responses.yaml#/Created")
    #expect(schema.object?.reference?.target.origin?.name == "Pet")
    #expect(schema.object?.reference?.target.origin?.location == component("Pet"))
  }

  @Test func eachFileIsLoadedOnce() throws {
    for name in ["Pet", "Person", "TreeNode", "Escapes", "Broken"] {
      _ = resolver.expandedSchema(at: component(name))
      _ = resolver.expandedSchema(at: component(name))
    }
    _ = resolver.dereference(operation().appending("responses").appending("201"))

    #expect(counter.counts.values.allSatisfy { $0 == 1 }, "\(counter.counts)")
    #expect(
      Set(counter.counts.keys) == [
        "address.yaml", "types.yaml", "responses.yaml", "nope.yaml", "broken.yaml",
      ])
    #expect(resolver.referencedFiles.first == resolver.rootFile)
    #expect(resolver.referencedFiles.count == 6)
    // The two that failed aren't documents.
    #expect(resolver.documents.count == 4)
  }

  @Test func dataThatLooksLikeARefIsLeftAlone() throws {
    let name = try property("name", of: "Pet")

    #expect(name.object?["examples"] == .value([["$ref": "#/not/a/reference"]]))
    #expect(resolver.warnings.isEmpty)
  }

  // MARK: - Recursion

  @Test func recursiveTreeSchemaStopsAtItself() throws {
    let tree = try #require(resolver.expandedSchema(at: component("TreeNode")))
    let children = try #require(tree.object?["properties"]?.schemaMap?["children"])
    let items = try #require(children.object?["items"]?.schema)

    #expect(
      items.object?.reference?.target == .recursive(resolver.origin(of: component("TreeNode"))))
  }

  @Test func mutuallyRecursiveSchemasExpandOnce() throws {
    let pet = try #require(resolver.expandedSchema(at: component("Pet")))
    let owner = try #require(pet.object?["properties"]?.schemaMap?["owner"]?.object?.reference)
    guard case .expanded(let origin, let person) = owner.target else {
      Issue.record("Expected Person to be expanded, got \(owner.target)")
      return
    }
    let pets = try #require(person.object?["properties"]?.schemaMap?["pets"])
    let items = try #require(pets.object?["items"]?.schema)

    #expect(origin.name == "Person")
    #expect(items.object?.reference?.target == .recursive(resolver.origin(of: component("Pet"))))
  }

  @Test func refThatOnlyLeadsBackToItselfIsRecursive() throws {
    let alias = try #require(resolver.expandedSchema(at: component("Alias")))
    guard case .expanded(let origin, let again) = alias.object?.reference?.target else {
      Issue.record("Expected AliasAgain to be expanded")
      return
    }

    #expect(origin.name == "AliasAgain")
    #expect(again.object?.reference?.target == .recursive(resolver.origin(of: component("Alias"))))
  }

  @Test func expandingUsesTheResolvedSchemaForEachLink() throws {
    let expanded = try #require(resolver.expandedSchema(at: component("Pet")))
    let graph = try #require(resolver.schema(at: component("Pet")))

    // The graph form keeps links, so the same fragment isn't resolved twice.
    let owner = graph.object?["properties"]?.schemaMap?["owner"]?.object?.reference?.target
    if case .link = owner {
    } else {
      Issue.record("Expected a link, got \(String(describing: owner))")
    }
    #expect(expanded != graph)
  }

  // MARK: - Broken references

  @Test func missingFileIsUnresolved() throws {
    let failure = try failure(of: "missingFile")
    guard case .fileNotLoaded(let error) = failure, case .unreadable = error.reason else {
      Issue.record("Expected an unreadable file, got \(failure)")
      return
    }
    #expect(error.file.lastPathComponent == "nope.yaml")
  }

  @Test func fileThatDoesNotParseIsUnresolved() throws {
    let failure = try failure(of: "brokenFile")
    guard case .fileNotLoaded(let error) = failure, case .syntax = error.reason else {
      Issue.record("Expected a syntax error, got \(failure)")
      return
    }
    #expect(error.line == 3)
  }

  @Test func badPointerIsUnresolved() throws {
    #expect(try failure(of: "badPointer") == .missingTarget(component("Nope")))
  }

  @Test(arguments: [
    ("badEscape", RefFailure.invalidPointer("/components/schemas/Pet~2")),
    ("remote", .remote("https://example.com/schemas/pet.yaml")),
    ("anchor", .anchor("pet")),
    ("notAString", .notAString),
  ])
  func otherBrokenRefsAreUnresolved(property name: String, expected: RefFailure) throws {
    #expect(try failure(of: name) == expected)
  }

  @Test func refToSomethingThatIsNotASchemaIsUnresolved() throws {
    let title = NodeLocation(file: resolver.rootFile, pointer: JSONPointer("/info/title")!)

    #expect(try failure(of: "notASchema") == .notASchema(title))
  }

  @Test func eachBrokenRefIsOneWarning() throws {
    _ = resolver.schema(at: component("Broken"))
    _ = resolver.expandedSchema(at: component("Broken"))
    _ = resolver.expandedSchema(at: component("Broken"))

    let broken = component("Broken").appending("properties")
    #expect(
      resolver.warnings.map(\.location)
        == [
          "missingFile", "badPointer", "badEscape", "remote", "anchor", "notASchema", "notAString",
          "brokenFile",
        ].map { broken.appending($0) })
    #expect(
      resolver.warnings[1].message
        == "`$ref: #/components/schemas/Nope` couldn't be followed. spec.yaml has nothing at "
        + "`/components/schemas/Nope`.")
  }

  // MARK: - Dereferencing other objects

  @Test func dereferenceFollowsAChain() throws {
    let body = try resolver.dereference(operation().appending("requestBody")).get()

    #expect(body.pointer.description == "/components/requestBodies/PetBody")
  }

  @Test func dereferenceOfAPlainValueIsItself() throws {
    let location = operation().appending("operationId")

    #expect(try resolver.dereference(location).get() == location)
  }

  @Test func dereferenceLoopIsCircular() throws {
    let loop = resolver.rootLocation.appending("components").appending("requestBodies")
      .appending("LoopA")

    #expect(throws: RefFailure.circular) { try resolver.dereference(loop).get() }
    #expect(resolver.warnings.count == 1)
  }

  // MARK: - Helpers

  private func component(_ name: String) -> NodeLocation {
    resolver.rootLocation.appending("components").appending("schemas").appending(name)
  }

  private func operation() -> NodeLocation {
    resolver.rootLocation.appending("paths").appending("/pets").appending("post")
  }

  private func property(_ name: String, of component: String) throws -> ResolvedSchema {
    let schema = try #require(resolver.schema(at: self.component(component)))
    return try #require(schema.object?["properties"]?.schemaMap?[name])
  }

  private func failure(of property: String) throws -> RefFailure {
    let schema = try self.property(property, of: "Broken")
    let target = try #require(schema.object?.reference?.target)
    guard case .unresolved(let failure) = target else {
      Issue.record("Expected \(property) to be unresolved, got \(target)")
      throw CancellationError()
    }
    return failure
  }
}
