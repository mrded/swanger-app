import Foundation
import OrderedCollections
import OrderedJSON
import Testing

@testable import SwangerCore

@Suite struct OpenAPI30NormaliserTests {
  // MARK: - nullable

  @Test func nullableAddsNullToType() throws {
    let schema = try normalise("{type: string, nullable: true, maxLength: 3}")

    #expect(schema == ["type": ["string", "null"], "maxLength": 3])
    #expect(keyPaths(schema) == ["/type", "/maxLength"])
  }

  @Test func nullableAddsNullToEnum() throws {
    #expect(
      try normalise("{type: string, enum: [a, b], nullable: true}")
        == ["type": ["string", "null"], "enum": ["a", "b", nil]])
    #expect(
      try normalise("{type: string, enum: [a, null], nullable: true}")
        == ["type": ["string", "null"], "enum": ["a", nil]])
  }

  @Test func nullableFalseIsRemoved() throws {
    #expect(try normalise("{type: string, nullable: false}") == ["type": "string"])
  }

  @Test func nullableWithoutATypeHasNoEffect() throws {
    // OpenAPI 3.0.3: `nullable` only applies alongside `type` in the same schema.
    #expect(
      try normalise("{allOf: [{type: string}], nullable: true, enum: [a]}")
        == ["allOf": [["type": "string"]], "enum": ["a"]])
  }

  // MARK: - exclusiveMinimum and exclusiveMaximum

  @Test func booleanExclusiveBoundsBecomeNumbers() throws {
    let schema = try normalise(
      "{minimum: 0, exclusiveMinimum: true, maximum: 10, exclusiveMaximum: false, type: number}")

    #expect(schema == ["exclusiveMinimum": 0, "maximum": 10, "type": "number"])
    #expect(keyPaths(schema) == ["/exclusiveMinimum", "/maximum", "/type"])
  }

  @Test func exclusiveWithoutABoundIsRemoved() throws {
    #expect(try normalise("{exclusiveMaximum: true, type: number}") == ["type": "number"])
  }

  @Test func numericExclusiveBoundsAreKept() throws {
    #expect(try normalise("{exclusiveMinimum: 5}") == ["exclusiveMinimum": 5])
  }

  // MARK: - example

  @Test func exampleBecomesExamples() throws {
    let schema = try normalise("{type: string, example: abc, format: uuid}")

    #expect(schema == ["type": "string", "examples": ["abc"], "format": "uuid"])
    #expect(keyPaths(schema).map { $0 } == ["/type", "/examples", "/format"])
  }

  @Test func exampleIsAddedToExistingExamples() throws {
    #expect(try normalise("{examples: [b, c], example: a}") == ["examples": ["a", "b", "c"]])
  }

  @Test func exampleThatIsAListStaysOneExample() throws {
    #expect(
      try normalise("{type: array, example: [1, 2]}") == ["type": "array", "examples": [[1, 2]]])
  }

  // MARK: - $ref

  @Test func keywordsBesideRefAreDroppedExceptDescription() throws {
    let schema = try normalise(
      "{$ref: '#/components/schemas/Pet', description: d, required: [a], nullable: true, x-a: 1}")

    #expect(schema == ["$ref": "#/components/schemas/Pet", "description": "d"])
  }

  // MARK: - Subschemas and data

  @Test func subschemasAreNormalised() throws {
    let schema = try normalise(
      """
      type: object
      properties:
        a: {type: string, nullable: true}
      additionalProperties: {type: integer, example: 1}
      items: {type: string, nullable: true}
      allOf:
        - {type: number, minimum: 1, exclusiveMinimum: true}
      not: {example: 2}
      """)

    #expect(
      schema == [
        "type": "object",
        "properties": ["a": ["type": ["string", "null"]]],
        "additionalProperties": ["type": "integer", "examples": [1]],
        "items": ["type": ["string", "null"]],
        "allOf": [["type": "number", "exclusiveMinimum": 1]],
        "not": ["examples": [2]],
      ])
  }

  @Test func dataIsNotTouched() throws {
    // `enum`, `default` and examples are values, even when they look like schemas.
    let schema = try normalise(
      """
      type: object
      default: {type: string, nullable: true}
      enum: [{example: 1}]
      example: {minimum: 1, exclusiveMinimum: true}
      properties:
        nullable: {type: boolean}
      """)

    #expect(
      schema == [
        "type": "object",
        "default": ["type": "string", "nullable": true],
        "enum": [["example": 1]],
        "examples": [["minimum": 1, "exclusiveMinimum": true]],
        "properties": ["nullable": ["type": "boolean"]],
      ])
  }

  @Test func booleanSchemasAreUnchanged() {
    #expect(OpenAPI30Normaliser.normalise(true) == true)
    #expect(OpenAPI30Normaliser.normalise(false) == false)
  }

  // MARK: - Through the resolver

  @Test func onlyOpenAPI30IsNormalised() throws {
    let v30 = try resolver("v30")
    let v31 = try RefResolver(
      root: SpecLoader.loadDocument(Fixtures.url("normalising/v30/spec.yaml")), version: .v31)
    let note = ["components", "schemas", "Order", "properties", "note"]

    let normalised = try #require(v30.schema(at: location(note, in: v30)))
    let untouched = try #require(v31.schema(at: location(note, in: v31)))
    #expect(normalised.object?["type"] == .value(["string", "null"]))
    #expect(normalised.object?["nullable"] == nil)
    #expect(untouched.object?["nullable"] == .value(true))
  }

  @Test func schemasInReferencedFilesAreNormalised() throws {
    let resolver = try resolver("v30")
    let email = NodeLocation(
      file: Fixtures.url("normalising/v30/common.yaml"),
      pointer: JSONPointer(tokens: ["Customer", "properties", "email"]))
    let schema = try #require(resolver.schema(at: email))

    #expect(schema.object?["type"] == .value(["string", "null"]))
    #expect(schema.object?["examples"] == .value(["someone@example.com"]))
  }

  @Test func mediaTypeExampleIsNotASchema() throws {
    let resolver = try resolver("v30")
    let mediaType = ["paths", "/orders", "post", "requestBody", "content", "application/json"]

    let value = try resolver.value(at: location(mediaType, in: resolver)).get()
    #expect(value.object?["example"] == ["quantity": 2])
  }

  @Test(arguments: ["Order"])
  func openAPI30And31DescribingTheSameSchemaAreEqual(component: String) throws {
    let v30 = try resolver("v30")
    let v31 = try resolver("v31")
    let path = ["components", "schemas", component]

    let normalised = try shape(#require(v30.expandedSchema(at: location(path, in: v30))))
    let written = try shape(#require(v31.expandedSchema(at: location(path, in: v31))))
    #expect(normalised == written)
    #expect(keyPaths(normalised) == keyPaths(written))
    #expect(v30.warnings.isEmpty && v31.warnings.isEmpty)
  }

  @Test func requestBodySchemasAreEqual() throws {
    let v30 = try resolver("v30")
    let v31 = try resolver("v31")
    let path = ["paths", "/orders", "post", "requestBody", "content", "application/json", "schema"]

    let normalised = try shape(#require(v30.expandedSchema(at: location(path, in: v30))))
    let written = try shape(#require(v31.expandedSchema(at: location(path, in: v31))))
    #expect(normalised == written)
  }

  // MARK: - Helpers

  private func normalise(_ yaml: String) throws -> JSONValue {
    let document = try SpecLoader.parse(Data(yaml.utf8), from: URL(filePath: "/specs/schema.yaml"))
    return OpenAPI30Normaliser.normalise(document.root)
  }

  private func resolver(_ folder: String) throws -> RefResolver {
    try RefResolver(spec: SpecLoader.load(Fixtures.url("normalising/\(folder)/spec.yaml")))
  }

  private func location(_ tokens: [String], in resolver: RefResolver) -> NodeLocation {
    NodeLocation(file: resolver.rootFile, pointer: JSONPointer(tokens: tokens))
  }

  /// The schema as JSON without its locations, so schemas from different files can be compared.
  private func shape(_ schema: ResolvedSchema) -> JSONValue {
    guard case .object(let object) = schema else {
      if case .boolean(let bool, _) = schema { return .boolean(bool) }
      return .null
    }
    var fields = OrderedDictionary<String, JSONValue>()
    if let reference = object.reference {
      fields["$ref"] =
        switch reference.target {
        case .link(let origin): ["link": .string(origin.name)]
        case .expanded(let origin, let target):
          ["origin": .string(origin.name), "schema": shape(target)]
        case .recursive(let origin): ["recursive": .string(origin.name)]
        case .unresolved(let failure): ["unresolved": .string(failure.description)]
        }
    }
    for (name, keyword) in object.keywords {
      fields[name] =
        switch keyword {
        case .value(let value): value
        case .schema(let schema): shape(schema)
        case .schemas(let schemas): .array(schemas.map(shape))
        case .schemaMap(let schemas): .object(schemas.mapValues(shape))
        }
    }
    return .object(fields)
  }
}
