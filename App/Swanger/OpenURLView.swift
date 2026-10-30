import AppKit
import SwangerCore
import SwiftUI

/// Asks for the web address of a spec, and opens it in a window of its own.
struct OpenURLView: View {
  static let windowID = "open-url"

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var text = Self.copiedAddress() ?? ""
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Open a spec from a web address").font(.headline)
      TextField(
        "Address", text: $text,
        prompt: Text("https://example.com/openapi.yaml")
      )
      .labelsHidden()
      .textFieldStyle(.roundedBorder)
      .focused($isFocused)
      .onSubmit(open)
      Text("Swanger downloads the spec and any files it refers to on the same server.")
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismissWindow(id: Self.windowID) }
          .keyboardShortcut(.cancelAction)
        Button("Open", action: open)
          .keyboardShortcut(.defaultAction)
          .disabled(address == nil)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { isFocused = true }
  }

  /// The text as an HTTP or HTTPS address, or `nil` when it isn't one.
  private var address: URL? { Self.address(from: text) }

  private func open() {
    guard let address else { return }
    openWindow(value: address)
    dismissWindow(id: Self.windowID)
  }

  static func address(from text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      RemoteFile.isRemote(url), url.host() != nil
    else { return nil }
    return url
  }

  /// A web address on the clipboard, to start from.
  private static func copiedAddress() -> String? {
    guard let text = NSPasteboard.general.string(forType: .string),
      address(from: text) != nil
    else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// File ▸ Open URL…
struct OpenURLCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open URL…") { openWindow(id: OpenURLView.windowID) }
        .keyboardShortcut("o", modifiers: [.command, .shift])
    }
  }
}
