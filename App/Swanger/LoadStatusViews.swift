import SwangerCore
import SwiftUI

/// Why a spec couldn't be opened, filling the window, with a way to try again.
struct LoadErrorView: View {
  let error: LoadError
  let isLoading: Bool
  let reload: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      VStack(spacing: 6) {
        Text(error.message)
        if let position = error.position {
          Text(position).font(.callout.monospaced()).foregroundStyle(.secondary)
        }
      }
      .textSelection(.enabled)
    } actions: {
      Button("Reload", action: reload)
        .keyboardShortcut("r")
        .disabled(isLoading)
    }
  }

  private var title: String {
    switch error.reason {
    case .unreadable: "Couldn’t open \(error.file.lastPathComponent)"
    case .syntax: "Couldn’t read \(error.file.lastPathComponent)"
    case .unsupportedVersion: "Unsupported version"
    case .notOpenAPI: "Not an OpenAPI document"
    }
  }

  private var systemImage: String {
    switch error.reason {
    case .unreadable: "doc.badge.ellipsis"
    case .syntax: "exclamationmark.triangle"
    case .unsupportedVersion, .notOpenAPI: "doc.questionmark"
    }
  }
}

/// Over a spec that loaded before: the latest reload failed, so the window still shows the last
/// version that loaded.
struct ReloadFailedBanner: View {
  let error: LoadError
  let reload: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
      VStack(alignment: .leading, spacing: 2) {
        Text(
          "Couldn’t reload \(error.file.lastPathComponent). Showing the last version that loaded."
        )
        .fontWeight(.medium)
        Text([error.position, error.message].compactMap(\.self).joined(separator: ": "))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Reload", action: reload).keyboardShortcut("r")
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}

/// A toolbar badge counting the spec's warnings, listing them when clicked.
struct WarningsButton: View {
  let warnings: [LoadWarning]
  @State private var isShowingList = false

  var body: some View {
    Button {
      isShowingList.toggle()
    } label: {
      Label(title, systemImage: "exclamationmark.triangle")
        .labelStyle(.titleAndIcon)
    }
    .help("Problems found while loading the spec")
    .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
      List(warnings, id: \.self) { warning in
        VStack(alignment: .leading, spacing: 2) {
          Text(LocalizedStringKey(warning.message))
          Text(warning.location.description)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
      }
      .frame(width: 420, height: min(CGFloat(warnings.count) * 52 + 20, 360))
    }
  }

  private var title: String {
    warnings.count == 1 ? "1 warning" : "\(warnings.count) warnings"
  }
}

extension LoadError {
  /// `spec.yaml, line 12, column 3`, when the problem's place is known.
  var position: String? {
    guard let location else { return nil }
    return "\(file.lastPathComponent), line \(location.line), column \(location.column)"
  }
}
