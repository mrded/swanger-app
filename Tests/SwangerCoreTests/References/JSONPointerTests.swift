import OrderedJSON
import Testing

@testable import SwangerCore

@Suite struct JSONPointerTests {
  @Test(
    arguments: [
      ("", []),
      ("/", [""]),
      ("/components/schemas/Pet", ["components", "schemas", "Pet"]),
      ("/paths/~1pets~1{id}/get", ["paths", "/pets/{id}", "get"]),
      ("/til~0de/~01", ["til~de", "~1"]),
    ] as [(String, [String])])
  func parsesAndEscapes(text: String, tokens: [String]) throws {
    let pointer = try #require(JSONPointer(text))

    #expect(pointer.tokens == tokens)
    #expect(pointer.description == text)
  }

  @Test(arguments: ["components", "/a~", "/a~2", "/~x"])
  func refusesInvalidPointers(text: String) {
    #expect(JSONPointer(text) == nil)
  }

  @Test(
    arguments: [
      ("/a/0", "first"),
      ("/a/1", "second"),
      ("/a/01", nil),
      ("/a/-", nil),
      ("/a/2", nil),
      ("/b/", "empty key"),
      ("/b/c", nil),
    ] as [(String, JSONValue?)])
  func findsValues(text: String, expected: JSONValue?) throws {
    let document: JSONValue = ["a": ["first", "second"], "b": ["": "empty key"]]

    #expect(try #require(JSONPointer(text)).value(in: document) == expected)
  }
}
