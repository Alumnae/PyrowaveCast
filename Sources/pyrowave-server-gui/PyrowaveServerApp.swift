import Foundation
import SwiftUI
import PyrowaveGUI

@main
struct PyrowaveServerApp: App {
    /// `@State`, not `@StateObject`: the scene must not observe the model, or every status
    /// update rebuilds the menu bar (blank rows, menus closing). The content view observes it.
    @State private var model = ServerModel()

    var body: some Scene {
        WindowGroup {
            ServerContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
