import Foundation
import OrderedJSON
import Testing

@testable import SwangerCore

/// Nodes and rule wording for small schemas.
@Suite struct SchemaNodeTests {
  // MARK: - Constraints

  @Test(arguments: [
    ("{type: string, maxLength: 70}", "allows at most 70 characters"),
    ("{type: string, minLength: 1}", "needs at least 1 character"),
    ("{type: string, minLength: 2, maxLength: 5}", "must have between 2 and 5 characters"),
    ("{type: string, minLength: 8, maxLength: 8}", "must have exactly 8 characters"),
    ("{type: string, enum: [a]}", #"must be "a""#),
    ("{type: string, enum: [a, b, c]}", #"must be one of "a", "b" or "c""#),
    ("{const: 5}", "must be 5"),
    ("{type: string, pattern: '^x$'}", "must match `^x$`"),
    ("{type: string, format: date}", "must be a date, such as 2024-01-31"),
    ("{type: string, format: postcode}", "must be in the `postcode` format"),
    ("{type: number, minimum: 0}", "must be at least 0"),
    ("{type: number, minimum: 1, maximum: 9}", "must be between 1 and 9"),
    ("{type: number, exclusiveMinimum: 0}", "must be more than 0"),
    ("{type: number, exclusiveMaximum: 1.5}", "must be less than 1.5"),
    ("{type: integer, multipleOf: 5}", "must be a multiple of 5"),
    ("{type: array, minItems: 1}", "needs at least 1 item"),
    ("{type: array, maxItems: 3}", "allows at most 3 items"),
    ("{type: array, uniqueItems: true}", "items must all be different"),
    ("{type: object, minProperties: 2}", "needs at least 2 fields"),
    ("{type: object, additionalProperties: false}", "allows no other fields"),
    ("{type: string, not: {enum: [x]}}", #"mustn't be "x""#),
  ])
  func constraintWording(schema: String, rule: String) throws {
    #expect(try node(schema).rules.map(\.text) == [rule])
  }

  @Test func stricterBoundWins() throws {
    let schema = "{allOf: [{type: string, maxLength: 70}, {maxLength: 10, minLength: 0}]}"

    #expect(try node(schema).rules.map(\.text) == ["allows at most 10 characters"])
  }

  // MARK: - Types

  @Test(arguments: [
    ("{type: string}", "string"),
    ("{type: [string, 'null']}", "string or null"),
    ("{type: [string, integer]}", "string or integer"),
    ("{type: 'null'}", "null"),
    ("{}", "any"),
    ("{const: card}", "string"),
    ("{type: array, items: {type: integer}}", "array of integer"),
    ("{type: object}", "object"),
    ("{properties: {a: {type: string}}}", "object"),
    ("{oneOf: [{type: string}, {type: integer}]}", "one of string or integer"),
    ("{allOf: [{type: number}, {type: integer}]}", "integer"),
    ("false", "nothing"),
  ])
  func typeDescriptions(schema: String, type: String) throws {
    #expect(try node(schema).shapeDescription == type)
  }

  // MARK: - Choices

  @Test func choiceWithoutDistinguishingFieldsNamesItsVariants() throws {
    let schema = try node("{anyOf: [{type: string}, {type: integer}]}")

    #expect(schema.choice?.variants.map(\.name) == ["string", "integer"])
    #expect(schema.rules.map(\.text) == ["Must match at least one of string or integer"])
  }

  @Test func choiceByRequiredFieldsGroupsThem() throws {
    let schema = try node(
      "{type: object, anyOf: [{required: [email]}, {required: [phone, countryCode]}]}")

    #expect(
      schema.rules.map(\.text) == ["Needs at least one of `email` or (`phone` and `countryCode`)"])
  }

  @Test func explicitDiscriminatorWithMapping() throws {
    let nodes = try components(
      """
      Pet:
        oneOf:
          - $ref: '#/components/schemas/Cat'
          - $ref: '#/components/schemas/Dog'
        discriminator:
          propertyName: kind
          mapping:
            kitty: '#/components/schemas/Cat'
      Cat: {type: object, properties: {kind: {type: string}}}
      Dog: {type: object, properties: {kind: {type: string}}}
      """)
    let pet = try #require(nodes("Pet").choice)

    #expect(pet.discriminator == "kind")
    // Mapped, then OpenAPI's default of the schema's name.
    #expect(pet.variants.map(\.discriminatorValue) == ["kitty", "Dog"])
    #expect(
      try nodes("Pet").rules.map(\.text) == [
        #"When `kind` is "kitty": it's a `Cat`"#, #"When `kind` is "Dog": it's a `Dog`"#,
      ])
  }

  @Test func inlineVariantsWithADiscriminator() throws {
    let schema = try node(
      """
      oneOf:
        - {type: object, required: [type, number], properties: {type: {const: card}, number: {type: string}}}
        - {type: object, required: [type], properties: {type: {const: cash}}}
      """)

    #expect(schema.choice?.variants.map(\.name) == ["card", "cash"])
    #expect(
      schema.rules.map(\.text) == [
        #"When `type` is "card": `number` is required"#,
        #"When `type` is "cash": it's the cash option"#,
      ])
  }

  // MARK: - Conditions

  @Test func nestedConditionAndPresence() throws {
    let schema = try node(
      """
      type: object
      if:
        properties:
          address: {properties: {country: {enum: [GB, IE]}}}
        required: [vatNumber]
      then:
        required: [postcode]
        properties:
          postcode: {maxLength: 8}
      """)

    #expect(
      schema.rules.map(\.text) == [
        #"When `address.country` is one of "GB" or "IE" and `vatNumber` is present: "#
          + "`postcode` is required; `postcode` allows at most 8 characters"
      ])
  }

  @Test func conditionFallsBackToItsDescription() throws {
    let schema = try node(
      "{type: object, if: {description: the order is international, minProperties: 3}, then: {required: [customs]}}"
    )

    #expect(schema.rules.map(\.text) == ["When the order is international: `customs` is required"])
  }

  // MARK: - Fragments

  @Test func refWithNewFieldsIsANewObject() throws {
    let nodes = try components(
      """
      Base: {type: object, required: [id], properties: {id: {type: string}}}
      Extended:
        $ref: '#/components/schemas/Base'
        properties:
          note: {type: string}
      """)
    let extended = try nodes("Extended")

    #expect(extended.fragment?.name == "Extended")
    #expect(extended.object?.fields.map(\.name) == ["id", "note"])
    #expect(extended.object?[field: "id"]?.definedIn?.name == "Base")
    #expect(extended.object?[field: "note"]?.definedIn == nil)
  }

  @Test func refWithOnlyADescriptionIsThePlainFragment() throws {
    let nodes = try components(
      """
      Money: {type: object, properties: {amount: {type: number}}, description: An amount.}
      Price:
        type: object
        properties:
          total: {$ref: '#/components/schemas/Money', description: The total.}
      """)
    let total = try #require(nodes("Price").object?[field: "total"]?.node)

    #expect(total.fragment?.name == "Money")
    #expect(total.isTightened == false)
    #expect(total.description == "The total.")
    #expect(try nodes("Money").description == "An amount.")
  }

  @Test func unresolvedRefIsANode() throws {
    let schema = try node("{type: object, properties: {a: {$ref: '#/components/schemas/Missing'}}}")
    let field = try #require(schema.object?[field: "a"]?.node)

    guard case .unresolved(let ref, _) = field.kind else {
      Issue.record("Expected an unresolved node, got \(field.kind)")
      return
    }
    #expect(ref == "#/components/schemas/Missing")
  }

  @Test func mutuallyRecursiveFragments() throws {
    let nodes = try components(
      """
      Person: {type: object, properties: {pets: {type: array, items: {$ref: '#/components/schemas/Pet'}}}}
      Pet: {type: object, properties: {owner: {$ref: '#/components/schemas/Person'}}}
      """)
    let person = try nodes("Person")
    let pet = try #require(person.object?[field: "pets"]?.node.array?.items)
    let owner = try #require(pet.object?[field: "owner"]?.node)

    #expect(pet.fragment?.name == "Pet")
    guard case .recursive(let fragment) = owner.kind else {
      Issue.record("Expected Person to be recursive inside Pet, got \(owner.kind)")
      return
    }
    #expect(fragment.name == "Person")
    // Pet on its own expands Person once.
    let petOnItsOwn = try nodes("Pet")
    #expect(petOnItsOwn.object?[field: "owner"]?.node.object != nil)
  }

  // MARK: - Helpers

  /// The node for one schema, written as a component named `S`.
  private func node(_ schema: String) throws -> SchemaNode {
    let lines = schema.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
    return try components("S:\n\(lines)")("S")
  }

  /// Builds `components/schemas` from YAML, and returns a way to get each one's node.
  private func components(_ yaml: String) throws -> (String) throws -> SchemaNode {
    let indented = yaml.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n")
    let text = """
      openapi: 3.1.0
      info: {title: Test, version: '1'}
      paths: {}
      components:
        schemas:
      \(indented)
      """
    let document = try SpecLoader.openAPIDocument(
      from: SpecLoader.parse(Data(text.utf8), from: URL(filePath: "/specs/test.yaml")))
    let resolver = RefResolver(spec: document)
    let builder = SchemaBuilder(resolver: resolver)
    return { name in
      let location = resolver.rootLocation.appending("components").appending("schemas")
        .appending(name)
      return builder.fragmentNode(at: location)
    }
  }
}
