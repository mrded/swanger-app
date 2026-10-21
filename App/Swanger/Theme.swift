import AppKit
import SwiftUI

/// Swanger's colours, each with a light and a dark variant.
extension Color {
  /// Top-level cards and required fields.
  static let swangerTeal = dynamic(
    light: NSColor(red: 0.05, green: 0.52, blue: 0.53, alpha: 1),
    dark: NSColor(red: 0.30, green: 0.78, blue: 0.77, alpha: 1))
  /// Rules, choices and conditions: anything that decides.
  static let swangerAmber = dynamic(
    light: NSColor(red: 0.72, green: 0.45, blue: 0.0, alpha: 1),
    dark: NSColor(red: 0.98, green: 0.72, blue: 0.25, alpha: 1))
  /// Shared fragments.
  static let swangerViolet = dynamic(
    light: NSColor(red: 0.45, green: 0.30, blue: 0.80, alpha: 1),
    dark: NSColor(red: 0.70, green: 0.58, blue: 1.0, alpha: 1))

  private static func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      })
  }
}

extension Text {
  /// Markdown text, such as a rule with field names in backticks, or the plain text if it isn't
  /// valid Markdown.
  init(markdown: String) {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    self.init(
      (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown))
  }
}
