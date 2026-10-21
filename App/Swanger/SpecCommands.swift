import AppKit
import SwiftUI

extension FocusedValues {
  /// The spec of the window in front.
  @Entry var specStore: SpecStore?
}

/// Find, and going back and forward, for the window in front.
struct SpecCommands: Commands {
  @FocusedValue(\.specStore) private var store

  var body: some Commands {
    CommandGroup(replacing: .textEditing) {
      Button("Find…") { store?.find() }
        .keyboardShortcut("f")
        .disabled(store?.spec == nil)
    }
    CommandGroup(before: .sidebar) {
      Button("Diagram") { store?.show(.diagram) }
        .keyboardShortcut("d", modifiers: [.command, .option])
        .disabled(store?.spec == nil)
      Button("Try It") { store?.show(.tryIt) }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(store?.spec == nil)
      Divider()
    }
    CommandMenu("Go") {
      Button("Back") { store?.goBack() }
        .keyboardShortcut("[")
        .disabled(store?.history.canGoBack != true)
      Button("Forward") { store?.goForward() }
        .keyboardShortcut("]")
        .disabled(store?.history.canGoForward != true)
      Divider()
      Button("Overview") { store?.show(.overview) }
        .keyboardShortcut("1")
        .disabled(store?.spec == nil)
    }
  }
}

/// Goes back and forward when the window gets a swipe, such as three fingers across the
/// trackpad.
struct SwipeNavigation: NSViewRepresentable {
  let store: SpecStore

  func makeNSView(context: Context) -> SwipeView {
    let view = SwipeView()
    view.store = store
    return view
  }

  func updateNSView(_ view: SwipeView, context: Context) {
    view.store = store
  }

  static func dismantleNSView(_ view: SwipeView, coordinator: ()) {
    view.stopMonitoring()
  }

  final class SwipeView: NSView {
    weak var store: SpecStore?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
        let isUsed = MainActor.assumeIsolated { self?.handleSwipe(event) ?? false }
        return isUsed ? nil : event
      }
    }

    /// Whether the swipe was used.
    private func handleSwipe(_ event: NSEvent) -> Bool {
      guard event.window === window, event.deltaX != 0, let store else { return false }
      return event.deltaX > 0 ? store.goBack() : store.goForward()
    }

    func stopMonitoring() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
