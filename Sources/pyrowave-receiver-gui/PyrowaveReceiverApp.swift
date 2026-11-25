import SwiftUI
import PyrowaveGUI

@main
struct PyrowaveReceiverApp: App {
    /// `@State`, not `@StateObject`: the scene must not observe the model, or every statistics
    /// update rebuilds the menu bar (blank rows, menus closing). The content view observes it.
    @State private var model = ReceiverModel()

    var body: some Scene {
        WindowGroup("PyrowaveCast Receiver") {
            ReceiverContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}
