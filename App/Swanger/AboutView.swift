import AppKit
import SwiftUI

/// The About window: the icon, name, subtitle and version, with links to the project.
struct AboutView: View {
  static let windowID = "about"

  private let info = Bundle.main.infoDictionary ?? [:]

  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text("Swanger").font(.title.weight(.semibold))
        Text("OpenAPI schema viewer for macOS").foregroundStyle(.secondary)
        Text("Version \(version)")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      HStack(spacing: 16) {
        Link("GitHub", destination: URL(string: "https://github.com/mrded/swanger-app")!)
        Link(
          "Report an Issue",
          destination: URL(string: "https://github.com/mrded/swanger-app/issues")!)
        Link(
          "MIT License",
          destination: URL(string: "https://github.com/mrded/swanger-app/blob/main/LICENSE")!)
      }
      .font(.callout)
      if let copyright = info["NSHumanReadableCopyright"] as? String {
        Text(copyright).font(.caption).foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 32)
    .padding(.vertical, 24)
    .fixedSize()
  }

  /// `0.1.0 (1)`.
  private var version: String {
    let short = info["CFBundleShortVersionString"] as? String ?? "?"
    let build = info["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }
}

/// Replaces the standard About item with one that opens ``AboutView``.
struct AboutCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Swanger") { openWindow(id: AboutView.windowID) }
    }
  }
}
