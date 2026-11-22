import SwiftUI
import PyrowaveGUI

@main
struct PyrowaveReceiverApp: App {
    @StateObject private var model = ReceiverModel()

    var body: some Scene {
        WindowGroup("PyrowaveCast Receiver") {
            ReceiverContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
    }
}
