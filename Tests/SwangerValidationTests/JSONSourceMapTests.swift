import OrderedJSON
import SwangerCore
import Testing

@testable import SwangerValidation

@Suite struct JSONSourceMapTests {
  let text = """
    {
      "name": "Ada",
      "tags": [1, {"a/b": true}],
      "caf\\u00e9": null,
      "emoji": "😀", "after": {}
    }
    """

  private func selected(_ pointer: String, in text: String) throws -> String {
    let map = try #require(JSONSourceMap(text))
    let range = map.selection(for: try #require(JSONPointer(pointer)))
    let units = Array(text.utf16)[range]
    return String(decoding: units, as: UTF16.self)
  }

  @Test(arguments: [
    // A member is its key and value; an item, the value alone.
    ("/name", #""name": "Ada""#),
    ("/tags/1", #"{"a/b": true}"#),
    ("/tags/1/a~1b", #""a/b": true"#),
    // Escaped keys are matched unescaped.
    ("/café", #""caf\u00e9": null"#),
    // UTF-16 offsets past a character outside the BMP.
    ("/after", #""after": {}"#),
    // Missing: the nearest key, or opening bracket.
    ("/after/missing", #""after""#),
    ("/tags/7", #""tags""#),
    ("/tags/1/c", "{"),
    ("/missing", "{"),
  ])
  func selection(_ pointer: String, _ expected: String) throws {
    #expect(try selected(pointer, in: text) == expected)
  }

  @Test func wholePayload() throws {
    #expect(try selected("", in: " [1, 2] ") == "[1, 2]")
  }

  @Test func invalid() {
    #expect(JSONSourceMap(#"{"a": }"#) == nil)
    #expect(JSONSourceMap("[1] 2") == nil)
    #expect(JSONSourceMap("") == nil)
  }

  @Test(arguments: [
    (0, 0),
    // "é" is two UTF-8 bytes and one UTF-16 unit; "😀" four and two.
    (3, 2), (7, 4),
    // Past the end, or inside a character.
    (99, 5), (2, 1),
  ])
  func offset(_ utf8Offset: Int, _ expected: Int) {
    #expect(JSONSourceMap.offset(utf8Offset: utf8Offset, in: "aé😀x") == expected)
  }

  @Test(
    arguments: [
      (0, 17), (17, 0), (6, 15), (15, 6), (13, 14),
      // Brackets in strings don't count, and can't be matched.
      (9, nil), (1, nil),
    ] as [(Int, Int?)])
  func matchingBracket(_ offset: Int, _ expected: Int?) {
    //          0         1
    //          012345678901234567
    let text = #"{"a": [ "]", {}] }"#
    #expect(JSONSourceMap.matchingBracket(at: offset, in: text) == expected)
  }

  @Test func unmatchedBrackets() {
    #expect(JSONSourceMap.matchingBracket(at: 0, in: "{ [") == nil)
    #expect(JSONSourceMap.matchingBracket(at: 2, in: "[ }") == nil)
    #expect(JSONSourceMap.matchingBracket(at: 0, in: "[ }") == nil)
  }
}

@Suite struct PathToPointerTests {
  @Test(arguments: [
    ("/amount", "amount"),
    // Through a choice, the variant the discriminator names.
    ("/method/sortCode", "method(BankTransfer).sortCode"),
    // Fields the schema doesn't have climb to the nearest one it does.
    ("/method/cvv", "method"),
    ("/unknown/deeper", ""),
    // Fields not listed take `additionalProperties`.
    ("/metadata/channel", "metadata.*"),
  ])
  func payment(_ pointer: String, _ expected: String) throws {
    let spec = try Spec.load(Fixtures.url("payments/spec.yaml"))
    let root = try spec.root("createPayment")
    let payload = json(
      #"{"amount":1,"method":{"type":"bank-transfer","sortCode":"x"},"metadata":{"channel":"web"}}"#
    )
    let path = root.node.path(to: try #require(JSONPointer(pointer)), in: payload)
    #expect(path.description == expected)
    #expect(root.node.node(at: path) != nil)
  }

  /// A discriminator names one variant; a field it hasn't stops at the choice, not in another
  /// variant that has it.
  @Test func discriminatorMismatch() throws {
    let spec = try Spec.load(Fixtures.url("payments/spec.yaml"))
    let root = try spec.root("createPayment")
    let payload = json(#"{"method":{"type":"card","sortCode":"12-34-56"}}"#)
    let path = root.node.path(to: JSONPointer("/method/sortCode")!, in: payload)
    #expect(path.description == "method")
  }

  /// A discriminator only narrows its own choice; a choice beside it is still searched.
  @Test func discriminatorInOneChoiceOnly() throws {
    let (_, root) = try Fixtures.inline(
      #"{"type":"object","properties":{"v":{"oneOf":[{"properties":{"kind":{"const":"a"}},"required":["kind"]},{"properties":{"kind":{"const":"b"}},"required":["kind"]}],"anyOf":[{"properties":{"count":{"type":"integer"}},"required":["count"]}]}}}"#
    )
    let payload = json(#"{"v":{"kind":"a","count":"bad"}}"#)
    let path = root.node.path(to: JSONPointer("/v/count")!, in: payload)
    #expect(path.fieldNames == ["v", "count"])
  }

  @Test func arrays() throws {
    let spec = try Spec.load(Fixtures.url("payments/spec.yaml"))
    let root = try spec.root("replaceTags")
    let payload = json(#"[{"name":"a","children":[{"name":"b"}]}]"#)
    #expect(root.node.path(to: JSONPointer("/0/name")!, in: payload).description == "[].name")
  }

  @Test func prefixItems() throws {
    let (_, root) = try Fixtures.inline(
      #"{"type":"array","prefixItems":[{"type":"object","properties":{"a":{}}}],"items":{"type":"object","properties":{"b":{}}}}"#
    )
    let payload = json(#"[{"a":1},{"b":2}]"#)
    #expect(root.node.path(to: JSONPointer("/0/a")!, in: payload).description == "[0].a")
    #expect(root.node.path(to: JSONPointer("/1/b")!, in: payload).description == "[].b")
  }
}

@Suite struct PrettyJSONTests {
  @Test func prettyText() {
    let value = json(#"{"a":1,"b":[true,null,{}],"c":{"d":"x\"y"},"e":[]}"#)
    #expect(
      value.prettyText == """
        {
          "a": 1,
          "b": [
            true,
            null,
            {}
          ],
          "c": {
            "d": "x\\"y"
          },
          "e": []
        }
        """)
    #expect(json(#"" é ""#).prettyText == #"" é ""#)
  }
}

@Suite struct JSONSourceMapEdgeTests {
  @Test func duplicateKeysKeepTheLastOnly() throws {
    let text = #"{"user":{"name":"old"},"user":{}}"#
    let map = try #require(JSONSourceMap(text))
    let range = map.selection(for: JSONPointer("/user/name")!)
    #expect(String(decoding: Array(text.utf16)[range], as: UTF16.self) == #""user""#)
    #expect(range.lowerBound == 23)
  }

  /// Text that hasn't been parsed yet can be nested too deep to scan without running out of
  /// stack.
  @Test func tooDeep() {
    #expect(JSONSourceMap(String(repeating: "[", count: 50_000)) == nil)
    #expect(
      JSONSourceMap(String(repeating: "[", count: 50_000) + String(repeating: "]", count: 50_000))
        == nil)
    let deepest = String(repeating: "[", count: 256) + String(repeating: "]", count: 256)
    #expect(JSONSourceMap(deepest) != nil)
  }

  @Test func syntaxErrorOffsetWithCRLF() throws {
    let text = "{\r\n  \"é\": }\r\n"
    let error = try #require(
      { () -> JSONParseError? in
        do {
          _ = try JSONValue.parse(text)
          return nil
        } catch { return error as? JSONParseError }
      }())
    let offset = JSONSourceMap.offset(utf8Offset: error.byteOffset, in: text)
    #expect(Array(text.utf16)[offset] == UInt16(UInt8(ascii: "}")))
  }
}
