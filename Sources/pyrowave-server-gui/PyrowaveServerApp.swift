import Foundation
import SwiftUI
import PyrowaveGUI

@main
struct PyrowaveServerApp: App {
    @StateObject private var model = ServerModel()

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
