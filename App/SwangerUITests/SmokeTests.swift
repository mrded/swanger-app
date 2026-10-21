import XCTest

/// Opens a fixture, selects a schema and checks a payload in Try it.
final class SmokeTests: XCTestCase {
  /// The Payments fixture, read from the source tree.
  private static let spec = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Tests/SwangerValidationTests/Fixtures/payments/spec.yaml")

  @MainActor
  func testValidAndBrokenPayloads() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      // Open the spec named below, as `open -a Swanger spec.yaml` would.
      "-NSTreatUnknownArgumentsAsOpen", "YES",
      // Don't reopen windows from an earlier run.
      "-ApplePersistenceIgnoreState", "YES",
      Self.spec.path,
    ]
    app.launch()
    defer { app.terminate() }

    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10), "The spec's window didn't open")

    // The request schema, listed before the shared fragment of the same name.
    let refund = window.outlines.staticTexts["Refund"].firstMatch
    XCTAssertTrue(refund.waitForExistence(timeout: 10), "The sidebar has no Refund schema")
    refund.click()

    window.radioButtons["Try it"].click()

    // The first example, "requested", is valid. Chosen from the menu because an earlier run left
    // its edit as the draft. (Masking the drafts with `-tryItDrafts` would make the app save over
    // everyone's real drafts.)
    let examples = window.menuButtons["Examples"]
    XCTAssertTrue(examples.waitForExistence(timeout: 10), "Try it has no Examples menu")
    examples.click()
    examples.menuItems.element(boundBy: 0).click()
    XCTAssertTrue(
      window.staticTexts["The payload matches the schema."].waitForExistence(timeout: 10),
      "The first example isn't shown as valid")

    let editor = window.textViews["Payload"]
    editor.click()
    editor.typeKey("a", modifierFlags: .command)
    editor.typeText("{}")

    let missing = window.staticTexts.matching(
      NSPredicate(format: "value CONTAINS 'paymentId' OR label CONTAINS 'paymentId'"))
    XCTAssertTrue(
      missing.firstMatch.waitForExistence(timeout: 10), "No issue about the missing paymentId")
    XCTAssertFalse(window.staticTexts["The payload matches the schema."].exists)
  }
}
