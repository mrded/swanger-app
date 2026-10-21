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
      AboutCommands()
    }

    Window("About Swanger", id: AboutView.windowID) {
      AboutView()
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .restorationBehavior(.disabled)
    .commandsRemoved()
  }
}
