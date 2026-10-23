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
    ("{type: number, not: {type: integer}}", "mustn't be an integer"),
    ("{type: integer, multipleOf: 5}", "must be a multiple of 5"),
    ("{type: array, minItems: 1}", "needs at least 1 item"),
    ("{type: array, maxItems: 3}", "allows at most 3 items"),
    ("{type: array, uniqueItems: true}", "items must all be different"),
    ("{type: array, contains: {type: string}}", "needs at least one item matching `contains`"),
    (
      "{type: array, contains: {type: string}, minContains: 2}",
      "needs at least 2 items matching `contains`"
    ),
    (
      "{type: array, contains: {type: string}, minContains: 0, maxContains: 3}",
      "allows at most 3 items matching `contains`"
    ),
    ("{type: array, contains: {type: string}, minContains: 0}", nil),
    ("{type: object, minProperties: 2}", "needs at least 2 fields"),
    ("{type: object, additionalProperties: false}", "allows no other fields"),
    ("{type: string, not: {enum: [x]}}", #"mustn't be "x""#),
    ("{type: object, not: {required: [a]}}", "mustn't have `a`"),
    ("{type: object, not: {required: [a, b]}}", "mustn't have both `a` and `b`"),
    ("{type: object, not: {required: [a], properties: {a: {const: 1}}}}", "mustn't match `not`"),
    ("{type: string, not: {enum: [x], maxLength: 3}}", "mustn't match `not`"),
  ])
  func constraintWording(schema: String, rule: String?) throws {
    #expect(try node(schema).rules.map(\.text) == (rule.map { [$0] } ?? []))
  }

  @Test(arguments: [
    "{type: string, minimum: 5}",
    "{type: integer, maxLength: 3}",
    "{type: boolean, minItems: 1}",
    "{allOf: [{type: string}, {multipleOf: 2}]}",
  ])
  func constraintsForOtherTypesArentShown(schema: String) throws {
    #expect(try node(schema).rules.isEmpty)
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
    ("{type: [object, string]}", "one of object or string"),
    ("{type: [array, object]}", "one of array or object"),
    ("{type: 'null'}", "null"),
    ("{}", "any"),
    ("{const: card}", #""card""#),
    ("{enum: [null, card]}", #""card" or null"#),
    ("{const: null}", "null"),
    ("{type: [string, 'null'], enum: [a]}", #""a""#),
    ("{type: [string, 'null'], enum: [a, null]}", #""a" or null"#),
    ("{type: number, const: 2}", "2"),
    ("{const: true}", "true"),
    ("{type: array, items: {type: integer}}", "array of integer"),
    ("{type: object}", "object"),
    ("{type: string, properties: {a: {type: integer}}}", "string"),
    ("{type: array, items: {type: string}, properties: {a: {}}}", "array of string"),
    ("{type: 'null', properties: {a: {type: integer}}}", "null"),
    ("{type: 'null', items: {type: string}}", "null"),
    ("{properties: {a: {type: string}}}", "object"),
    ("{oneOf: [{type: string}, {type: integer}]}", "one of string or integer"),
    ("{allOf: [{type: number}, {type: integer}]}", "integer"),
    ("false", "nothing"),
    ("{allOf: [{type: string}, {type: integer}]}", "nothing"),
    ("{allOf: [{type: [string, 'null']}, {type: [integer, 'null']}]}", "null"),
    ("{allOf: [{enum: [a]}, {enum: [b]}]}", "nothing"),
    ("{required: [b], properties: {b: false}}", "object"),
    ("{not: {}}", "nothing"),
    ("{not: true}", "nothing"),
    ("{not: {description: Anything.}}", "nothing"),
    ("{type: [string, 'null'], not: {}}", "nothing"),
    ("{type: array, items: {not: {}}}", "array of nothing"),
  ])
  func typeDescriptions(schema: String, type: String) throws {
    #expect(try node(schema).shapeDescription == type)
  }

  /// The model shows what the keywords say and doesn't prove that nothing can match them: that's
  /// for the validator (see `docs/model-boundaries.md`).
  @Test(arguments: [
    ("{type: string, oneOf: [{type: string}, {type: integer}]}", "one of string or integer"),
    ("{type: string, oneOf: [{type: integer}, {type: boolean}]}", "one of integer or boolean"),
    ("{allOf: [{type: integer}, {enum: [y]}]}", "integer"),
    ("{type: object, required: [b], properties: {b: false}}", "object"),
    ("{type: [string, 'null'], not: {type: 'null'}}", "string or null"),
    ("{type: [string, 'null'], anyOf: [{type: string}]}", "any of string or null"),
  ])
  func contradictionsAreShownAsWritten(schema: String, type: String) throws {
    #expect(try node(schema).shapeDescription == type)
  }

  @Test func typesThatDontOverlapAllowNothing() throws {
    let schema = try node("{allOf: [{type: string, maxLength: 5}, {type: integer}]}")

    #expect(schema.kind == .never)
    #expect(schema.rules.isEmpty)
  }

  @Test func typeUnionKeepsEachTypesKeywords() throws {
    let schema = try node(
      """
      type: [object, string, integer, 'null']
      properties: {a: {type: string}}
      maxLength: 3
      minimum: 1
      not: {const: x}
      """)
    let variants = try #require(schema.choice?.variants)

    #expect(variants.map(\.name) == ["object", "string or integer"])
    #expect(variants[0].node.object?.fields.map(\.name) == ["a"])
    #expect(variants[0].node.rules.isEmpty)
    #expect(
      variants[1].node.rules.map(\.text) == ["allows at most 3 characters", "must be at least 1"])
    #expect(schema.allowsNull)
    #expect(schema.rules.map(\.text) == [#"mustn't be "x""#])
  }

  @Test func closedObjectInAllOfOnlyAllowsItsOwnFields() throws {
    let schema = try node(
      """
      allOf:
        - {type: object, properties: {a: {}}, patternProperties: {'^x-': {}}, additionalProperties: false}
        - {properties: {b: {}, x-note: {}}}
      """)
    let object = try #require(schema.object)

    #expect(object.fields.map(\.name) == ["a", "b", "x-note"])
    #expect(object.fields.map(\.isForbidden) == [false, true, false])
  }

  @Test(arguments: [
    ("{type: object, unevaluatedProperties: false}", "allows no unevaluated fields"),
    (
      "{type: object, unevaluatedProperties: {type: string}}",
      "unevaluated fields must match `unevaluatedProperties`"
    ),
  ])
  func unevaluatedPropertiesIsARuleOnly(schema: String, rule: String) throws {
    let schema = try node(schema)

    #expect(schema.object?.additionalFields == .allowed)
    #expect(schema.rules.map(\.text) == [rule])
  }

  @Test func unevaluatedPropertiesBesideARefSeesItsFields() throws {
    let nodes = try components(
      """
      S: {$ref: '#/components/schemas/Base', unevaluatedProperties: false}
      Base: {type: object, properties: {a: {type: string}}}
      """)

    #expect(try nodes("S").object?[field: "a"]?.isForbidden == false)
  }

  @Test func impossibleFieldIsForbidden() throws {
    let schema = try node(
      "{type: object, properties: {a: {allOf: [{type: string}, {type: integer}]}}}")

    #expect(schema.object?[field: "a"]?.isForbidden == true)
  }

  @Test func refToASchemaThatRejectsEverythingAllowsNothing() throws {
    let nodes = try components(
      """
      Nothing: {not: {}}
      S: {$ref: '#/components/schemas/Nothing'}
      """)

    #expect(try nodes("S").kind == .never)
  }

  @Test func tuplePositionsShowOnlyTheirOwnPrefixItems() throws {
    let schema = try node(
      """
      allOf:
        - {prefixItems: [{type: string}, {}]}
        - {prefixItems: [{maxLength: 3}], items: {type: integer}}
      """)
    let array = try #require(schema.array)

    #expect(array.prefixItems.map(\.shapeDescription) == ["string", "any"])
    #expect(array.items?.shapeDescription == "integer")
  }

  @Test func tuplePositionsMergeAcrossAllOf() throws {
    let schema = try node(
      """
      allOf:
        - {type: array, prefixItems: [{type: string}]}
        - {prefixItems: [{maxLength: 5}, {type: integer}]}
      """)
    let positions = try #require(schema.array?.prefixItems)

    #expect(positions.map(\.shapeDescription) == ["string", "integer"])
    #expect(positions.first?.rules.map(\.text) == ["allows at most 5 characters"])
  }

  // MARK: - Choices

  @Test func requiredFieldsBesideAChoiceAreKept() throws {
    let schema = try node(
      "{type: object, required: [id], anyOf: [{required: [email]}, {required: [phone]}]}")

    #expect(schema.object?.fields.map(\.name) == ["id"])
    #expect(schema.object?[field: "id"]?.isRequired == true)
    #expect(schema.rules.map(\.text) == ["Needs at least one of `email` or `phone`"])
  }

  @Test func closedObjectBesideAChoiceKeepsItsRule() throws {
    let schema = try node(
      "{additionalProperties: false, oneOf: [{required: [email]}, {required: [phone]}]}")

    #expect(schema.object != nil)
    #expect(schema.rules.map(\.text).contains("allows no other fields"))
  }

  @Test func variantsBesideCommonFieldsAreKept() throws {
    let nodes = try components(
      """
      Payment:
        type: object
        properties:
          id: {type: string}
        oneOf:
          - $ref: '#/components/schemas/Card'
          - $ref: '#/components/schemas/Cash'
      Card: {type: object, required: [number], properties: {number: {type: string}}}
      Cash: {type: object, properties: {change: {type: boolean}}}
      """)
    let payment = try nodes("Payment")
    let variants = try #require(payment.choices.first?.variants)

    #expect(payment.object?.fields.map(\.name) == ["id"])
    #expect(variants.map(\.name) == ["Card", "Cash"])
    #expect(variants.first?.node.object?[field: "number"]?.isRequired == true)
  }

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

  @Test func recursiveConditionEnds() throws {
    let nodes = try components(
      """
      S: {type: object, if: {$ref: '#/components/schemas/Node'}, then: {required: [x]}}
      Node: {type: object, properties: {child: {$ref: '#/components/schemas/Node'}}}
      """)

    #expect(try nodes("S").rules.map(\.text) == ["When the `if` schema matches: `x` is required"])
  }

  @Test func optionalFieldInAConditionCanBeMissing() throws {
    let schema = try node(
      """
      type: object
      if: {properties: {status: {const: Rejected}}}
      then: {required: [reason]}
      """)

    #expect(
      schema.rules.map(\.text) == [
        #"When `status` is missing or is "Rejected": `reason` is required"#
      ])
  }

  @Test func fieldTheObjectRequiresCantBeMissingInACondition() throws {
    let schema = try node(
      """
      type: object
      required: [status]
      if: {properties: {status: {const: Rejected}}}
      then: {required: [reason]}
      """)

    #expect(schema.rules.map(\.text) == [#"When `status` is "Rejected": `reason` is required"#])
  }

  @Test func conditionBranchesThatSetATypeSaySo() throws {
    let schema = try node(
      """
      type: object
      required: [kind]
      if: {properties: {kind: {const: count}}}
      then: {properties: {value: {type: integer}}}
      else: {properties: {value: {type: [string, 'null']}}}
      """)

    #expect(
      schema.rules.map(\.text) == [
        #"When `kind` is "count": `value` must be an integer. "#
          + "Otherwise: `value` must be a string or null"
      ])
  }

  /// Only the flat shape is worded; anything else falls back, so a condition is never shown as
  /// matching more or asking less than it does.
  @Test(arguments: [
    (
      "{if: {properties: {address: {properties: {country: {const: GB}}}}}, then: {required: [vat]}}",
      "When the `if` schema matches: `vat` is required"
    ),
    (
      "{if: {properties: {amount: {type: integer, minimum: 100}}}, then: {required: [approval]}}",
      "When the `if` schema matches: `approval` is required"
    ),
    (
      "{if: {required: [ship]}, then: {properties: {address: {required: [zip]}}}}",
      "When `ship` is present: the `then` schema applies"
    ),
    (
      "{if: {required: [a]}, then: {dependentRequired: {b: [c]}}}",
      "When `a` is present: the `then` schema applies"
    ),
    (
      "{if: {required: [a]}, then: {allOf: [{required: [b]}]}}",
      "When `a` is present: the `then` schema applies"
    ),
  ])
  func conditionsBeyondTheFlatShapeFallBack(schema: String, rule: String) throws {
    #expect(try node("{type: object, \(schema.dropFirst())").rules.map(\.text) == [rule])
  }

  @Test func branchLimitsAndForbidsFields() throws {
    let schema = try node(
      """
      type: object
      if: {required: [ship]}
      then: {required: [zip], properties: {zip: {maxLength: 8}, box: false}}
      """)

    #expect(
      schema.rules.map(\.text) == [
        "When `ship` is present: `zip` is required; `zip` allows at most 8 characters; "
          + "`box` isn't allowed"
      ])
  }

  @Test func conditionThatCantBeFullyWordedSaysSo() throws {
    let schema = try node(
      """
      type: object
      if: {required: [amount], properties: {amount: {not: {multipleOf: 7}}}}
      then: {required: [approval]}
      """)

    #expect(schema.rules.map(\.text) == ["When the `if` schema matches: `approval` is required"])
  }

  @Test func branchThatCantBeWordedSaysItApplies() throws {
    let schema = try node(
      """
      type: object
      if: {required: [ship]}
      then: {properties: {address: {oneOf: [{required: [zip]}, {required: [box]}]}}}
      """)

    #expect(schema.rules.map(\.text) == ["When `ship` is present: the `then` schema applies"])
  }

  @Test func fieldsAConditionRequiresOrForbidsAreConditional() throws {
    let schema = try node(
      """
      type: object
      required: [kind]
      properties: {kind: {type: string}, zip: {type: string}, box: {type: string}, note: {type: string}}
      if: {properties: {kind: {const: parcel}}}
      then: {required: [zip], properties: {zip: {maxLength: 8}}}
      else: {properties: {box: false}}
      """)
    let object = try #require(schema.object)

    #expect(object.fields.map(\.presence) == [.required, .conditional, .conditional, .optional])
    #expect(object[field: "zip"]?.decidedBy == schema.rules.filter { $0.kind == .condition })
  }

  @Test func fieldADependencyRequiresIsConditional() throws {
    let schema = try node(
      "{type: object, properties: {a: {}, b: {}}, dependentRequired: {a: [b]}}")

    #expect(schema.object?.fields.map(\.presence) == [.optional, .conditional])
    #expect(schema.object?[field: "b"]?.decidedBy.map(\.kind) == [.dependency])
  }

  @Test func typeUnionsObjectVariantKeepsConditionalFields() throws {
    let schema = try node(
      """
      type: [object, string]
      properties: {kind: {}, zip: {}}
      if: {properties: {kind: {const: parcel}}}
      then: {required: [zip]}
      """)
    let object = try #require(schema.choice?.variants.first?.node.object)

    #expect(object[field: "zip"]?.presence == .conditional)
    #expect(object[field: "zip"]?.decidedBy == schema.rules.filter { $0.kind == .condition })
  }

  @Test func conditionThatFallsBackDecidesNoField() throws {
    let schema = try node(
      """
      type: object
      properties: {b: {}}
      if: {required: [a]}
      then: {allOf: [{required: [b]}]}
      """)

    #expect(schema.object?[field: "b"]?.presence == .optional)
  }

  @Test func conditionWithADependencyFallsBack() throws {
    let schema = try node(
      "{type: object, if: {required: [a], dependentRequired: {b: [c]}}, then: {required: [d]}}")

    #expect(schema.rules.map(\.text) == ["When the `if` schema matches: `d` is required"])
  }

  @Test func optionalParentsNestedRequirementFallsBack() throws {
    let schema = try node(
      """
      type: object
      if: {properties: {flag: {const: true}, parent: {required: [child], properties: {child: {const: 1}}}}, required: [flag]}
      then: {required: [x]}
      """)

    #expect(schema.rules.map(\.text) == ["When the `if` schema matches: `x` is required"])
  }

  @Test func conditionOnTheValueItselfIsWorded() throws {
    let schema = try node(
      """
      if: {type: number}
      then: {type: number, exclusiveMinimum: 0}
      else: {enum: [null, '']}
      """)

    #expect(
      schema.rules.map(\.text) == [
        #"When it's a number: must be more than 0. Otherwise: must be one of null or """#
      ])
  }

  @Test(arguments: [
    ("{if: {const: x}, then: {maxLength: 1}}", #"When it's "x": allows at most 1 character"#),
    (
      "{if: {enum: [a, b]}, then: {type: string}}",
      #"When it's one of "a" or "b": must be a string"#
    ),
    ("{if: {type: string}, then: {type: integer}}", "When it's a string: must be an integer"),
  ])
  func valueConditionsAreWorded(schema: String, rule: String) throws {
    #expect(try node(schema).rules.map(\.text) == [rule])
  }

  @Test(arguments: [
    // Each branch limits the type, so a valid value is one of them.
    (
      "{if: {type: number}, then: {type: number}, else: {enum: [null, '']}}",
      "number or string or null"
    ),
    ("{if: {type: string}, then: {const: 1}, else: {type: number}}", "number"),
    ("{if: {type: string}, then: {not: {}}, else: {type: boolean}}", "boolean"),
    // A branch that doesn't limit the type, or is missing, allows anything.
    ("{if: {type: number}, then: {type: number}}", "any"),
    ("{if: {type: number}, then: {type: number}, else: {maxLength: 2}}", "any"),
    (
      "{if: {type: number}, then: {type: number}, else: {$ref: '#/components/schemas/S'}}",
      "any"
    ),
    // A `type` or allowed values of its own say more.
    ("{type: string, if: {minLength: 1}, then: {type: string}, else: {type: number}}", "string"),
    ("{enum: [1], if: {type: number}, then: {type: number}, else: {type: string}}", "1"),
  ])
  func typeComesFromConditionBranches(schema: String, type: String) throws {
    #expect(try node(schema).shapeDescription == type)
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

  @Test func unresolvedRefBesideOtherKeywordsIsKept() throws {
    let schema = try node(
      "{$ref: '#/components/schemas/Missing', type: object, properties: {a: {type: string}}}")

    #expect(schema.object?.fields.map(\.name) == ["a"])
    #expect(schema.unresolvedRefs.map(\.ref) == ["#/components/schemas/Missing"])
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

  @Test func variantsWithTheSameNameAreFoundByPosition() throws {
    let node = try node(
      """
      oneOf:
        - {type: string, format: email}
        - {type: string, format: uuid}
      """)

    #expect(node.variants.map(\.name) == ["string", "string"])
    #expect(node.node(at: FieldPath([.variant("string", index: 1)]))?.scalar?.format == "uuid")
    #expect(node.node(at: FieldPath([.variant("integer", index: 1)])) == nil)
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
