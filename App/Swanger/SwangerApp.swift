import SwiftUI

@main
struct SwangerApp: App {
  var body: some Scene {
    DocumentGroup(viewing: SpecDocument.self) { file in
      if let url = file.fileURL {
        SpecWindow(url: url)
      } else {
        ContentUnavailableView(
          "Nothing to show", systemImage: "doc.questionmark",
          description: Text("Swanger opens OpenAPI files saved on disk."))
      }
    }
    .commands {
      SpecCommands()
      OpenURLCommands()
      AboutCommands()
    }

    // A spec opened from a web address. Its address is restored with the window.
    WindowGroup("Spec", for: URL.self) { $url in
      if let url {
        SpecWindow(url: url)
          .navigationTitle(url.lastPathComponent)
      }
    }
    .commandsRemoved()

    Window("Open URL", id: OpenURLView.windowID) {
      OpenURLView()
    }
    .windowResizability(.contentSize)
    .restorationBehavior(.disabled)
    .commandsRemoved()

    Window("About Swanger", id: AboutView.windowID) {
      AboutView()
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .restorationBehavior(.disabled)
    .commandsRemoved()
  }
}
