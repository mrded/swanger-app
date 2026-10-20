import Foundation
import OrderedJSON
import Testing

@testable import SwangerCore

@Suite struct YAMLConverterTests {
  @Test(
    arguments: [
      // YAML 1.2 core schema: only these spellings are null and booleans.
      ("~", nil),
      ("null", nil),
      ("NULL", nil),
      ("", nil),
      ("true", true),
      ("False", false),
      // YAML 1.1 booleans and dates stay strings, as in JSON.
      ("yes", "yes"),
      ("no", "no"),
      ("on", "on"),
      ("off", "off"),
      ("y", "y"),
      ("2024-01-31", "2024-01-31"),
      ("2024-01-31T10:00:00Z", "2024-01-31T10:00:00Z"),
      // Numbers, spelled as JSON spells them.
      ("12", 12),
      ("-12", -12),
      ("+12", 12),
      ("007", 7),
      ("0", 0),
      ("0x1F", 31),
      ("0o17", 15),
      ("1.5", 1.5),
      (".5", 0.5),
      ("-.5", -0.5),
      ("1e3", 1000),
      ("2.5E-2", 0.025),
      // Not numbers in YAML 1.2.
      ("1_000", "1_000"),
      ("0b101", "0b101"),
      ("1.2.3", "1.2.3"),
      ("0x", "0x"),
      ("-0x1F", "-0x1F"),
      ("1e", "1e"),
      (".", "."),
      // JSON has no infinity or NaN.
      (".inf", ".inf"),
      ("-.Inf", "-.Inf"),
      (".nan", ".nan"),
      // Quoted and tagged scalars are strings.
      ("'12'", "12"),
      (#""true""#, "true"),
      ("'~'", "~"),
      ("!!str 12", "12"),
      ("! 12", "12"),
      ("!!timestamp 2024-01-31", "2024-01-31"),
      ("!!int '12'", 12),
      ("!!float 1", 1),
      ("!!bool 'true'", true),
      ("!!null ''", nil),
    ] as [(String, JSONValue)])
  func plainScalarsFollowTheCoreSchema(yaml: String, expected: JSONValue) throws {
    #expect(try value(of: "value: \(yaml)") == ["value": expected])
  }

  @Test func numbersKeepTheirSpelling() throws {
    let root = try value(of: "a: 1.0\nb: 1.\nc: -0\nd: 1E+3\ne: 0.50")
    let raw = root.object?.values.map { $0.numberLiteral?.rawValue }

    #expect(raw == ["1.0", "1", "-0", "1e+3", "0.50"])
  }

  @Test func hexTooLargeFor64BitsStaysAString() throws {
    #expect(try value(of: "a: 0x1FFFFFFFFFFFFFFFF") == ["a": "0x1FFFFFFFFFFFFFFFF"])
  }

  @Test func keysAreStrings() throws {
    let root = try value(of: "200: OK\n404: Not found\ntrue: yes\n~: nothing\n1.5: half")

    #expect(root.object.map { Array($0.keys) } == ["200", "404", "true", "~", "1.5"])
  }

  @Test func blockScalarsAreStrings() throws {
    let root = try value(of: "a: |\n  12\nb: >\n  true\n")

    #expect(root == ["a": "12\n", "b": "true\n"])
  }

  @Test func aliasesAreExpanded() throws {
    let root = try value(
      of: """
        base: &base
          type: string
          maxLength: 10
        copy: *base
        """)

    #expect(root.object?["copy"] == root.object?["base"])
  }

  @Test func mergeKeysAddMissingFields() throws {
    let root = try value(
      of: """
        base: &base { type: string, maxLength: 10, format: uuid }
        extra: &extra { maxLength: 20, pattern: x }
        merged:
          maxLength: 5
          <<: [*base, *extra]
          description: d
        """)
    let merged = try #require(root.object?["merged"]?.object)

    // Own keys win wherever they are; among merged mappings the earlier one wins.
    #expect(merged["maxLength"] == 5)
    #expect(merged["type"] == "string")
    #expect(merged["format"] == "uuid")
    #expect(merged["pattern"] == "x")
    #expect(Array(merged.keys) == ["maxLength", "type", "format", "pattern", "description"])
  }

  @Test func quotedMergeKeyIsAnOrdinaryKey() throws {
    #expect(try value(of: "'<<': 1") == ["<<": 1])
  }

  @Test func keyOrderIsPreservedInFlowAndBlockMappings() throws {
    let root = try value(of: "z: 1\na: {y: 2, b: 3}\nm: 4")

    #expect(keyPaths(root) == ["/z", "/a", "/a/y", "/a/b", "/m"])
  }

  @Test func emptyDocumentIsNull() throws {
    #expect(try value(of: "") == nil)
    #expect(try value(of: "# only a comment\n") == nil)
  }

  @Test(arguments: [
    // Duplicates point at the first use of the key.
    ("a: 1\nb: 2\na: 3", 1, "Duplicate key `a`"),
    // Different in YAML, but the same key in JSON.
    ("a: 1\n200: x\n'200': y", 2, "Duplicate key `200`"),
    ("? [a, b]\n: 1", 1, "Keys must be plain values"),
    ("a: !!int twelve", 1, "`twelve` isn't a number"),
    ("a: !!bool yes", 1, "`yes` isn't true or false"),
    ("a: 1\n  b: 2", 2, "Mapping values are not allowed"),
    ("a: [1, 2", 2, "Did not find expected ',' or ']'"),
    ("a: *missing", 1, "Found undefined alias"),
    ("a: 1\n---\nb: 2", 2, "A file can hold only one YAML document"),
    ("a:\n  <<: 1", 2, "`<<` can only merge"),
  ])
  func errorsHaveALineAndAMessage(yaml: String, line: Int, message: String) throws {
    let error = try #require(throws: LoadError.self) { try value(of: yaml) }

    guard case .syntax(let text) = error.reason else {
      Issue.record("Expected a syntax error, got \(error.reason)")
      return
    }
    #expect(text.hasPrefix(message), "\(text)")
    #expect(error.line == line)
  }

  private func value(of yaml: String) throws -> JSONValue {
    try SpecLoader.parse(Data(yaml.utf8), from: URL(filePath: "/specs/test.yaml")).root
  }
}
