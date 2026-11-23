import SwiftUI
import PyrowaveGUI
import SPPWCommon

/// Unified PyroWave application — server and receiver in a single window.
///
/// The sidebar switches between the server panel (capture + encode + stream)
/// and the receiver panel (connect to a remote server and display video).
/// Both panels can run simultaneously: the server streams to remote clients
/// while the receiver connects to any SPPW/1 server (including this app's own
/// server on localhost).
@main
struct PyrowaveApp: App {
    @StateObject private var serverModel = ServerModel()
    @StateObject private var receiverModel = ReceiverModel()
    @AppStorage(SPPWLocalization.languageDefaultsKey) private var selectedLanguageRaw: String = SPPWAppLanguage.system.rawValue

    enum Panel: String, CaseIterable, Identifiable {
        case server = "Server"
        case receiver = "Receiver"

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .server: return SPPWLocalization.tr("tab.server")
            case .receiver: return SPPWLocalization.tr("tab.receiver")
            }
        }

        var symbolName: String {
            switch self {
            case .server: return "antenna.radiowaves.left.and.right"
            case .receiver: return "dot.radiowaves.left.and.right"
            }
        }
    }

    @State private var selectedPanel: Panel = .server
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Sidebar layout to restore when the receiver leaves video fullscreen.
    @State private var columnVisibilityBeforeFullscreen: NavigationSplitViewVisibility = .all

    /// Receiver video fullscreen: no sidebar and no window toolbar, so the title bar
    /// ("PyrowaveCast") hides with the macOS fullscreen chrome and only comes back
    /// when the pointer reaches the top edge.
    private var isReceiverVideoFullscreen: Bool {
        selectedPanel == .receiver && receiverModel.isVideoFullscreen
    }

    var body: some Scene {
        WindowGroup("PyrowaveCast") {
            let _ = selectedLanguageRaw
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                detailPanel
            }
            .toolbar(isReceiverVideoFullscreen ? .hidden : .automatic, for: .windowToolbar)
            .onChange(of: isReceiverVideoFullscreen) { _, fullscreen in
                if fullscreen {
                    columnVisibilityBeforeFullscreen = columnVisibility
                    columnVisibility = .detailOnly
                } else {
                    columnVisibility = columnVisibilityBeforeFullscreen
                }
            }
            .frame(minWidth: 1100, minHeight: 700)
            .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Image(systemName: "wave.3.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                Text("PyrowaveCast")
                    .font(.headline)
                Text("SPPW/1 Unicast")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)

            Divider()

            List(Panel.allCases, selection: $selectedPanel) { panel in
                Label(panel.localizedTitle, systemImage: panel.symbolName)
                    .tag(panel)
            }
            .listStyle(.sidebar)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(SPPWLocalization.tr("settings.language"), selection: Binding(
                        get: { SPPWAppLanguage(rawValue: selectedLanguageRaw) ?? .system },
                        set: { newLang in
                            selectedLanguageRaw = newLang.rawValue
                            SPPWLocalization.selectedLanguage = newLang
                        }
                    )) {
                        ForEach(SPPWAppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                if serverModel.isRunning {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(SPPWLocalization.tr("sidebar.server_listening_fmt", Int(serverModel.status.port)))
                            .font(.caption2)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(SPPWLocalization.tr("sidebar.server_stopped"))
                            .font(.caption2)
                    }
                }
                if receiverModel.isConnected {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text(SPPWLocalization.tr("sidebar.receiver_connected"))
                            .font(.caption2)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(SPPWLocalization.tr("sidebar.receiver_disconnected"))
                            .font(.caption2)
                    }
                }

                Text(SPPWBuildVersion.current)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.bottom, 12)
            .foregroundStyle(.secondary)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    @ViewBuilder
    private var detailPanel: some View {
        switch selectedPanel {
        case .server:
            ServerContentView()
                .environmentObject(serverModel)
        case .receiver:
            ReceiverContentView()
                .environmentObject(receiverModel)
        }
    }
}
