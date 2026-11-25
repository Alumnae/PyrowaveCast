import SwiftUI
#if canImport(SPPWCommon)
import SPPWCommon
#endif

/// Main-actor mirror of `SPPWFileTransfers` for SwiftUI.
@MainActor
final class FileTransferMonitor: ObservableObject {
    @Published private(set) var transfers: [SPPWFileTransferStatus] = []
    private var token: UUID?

    init() {
        token = SPPWFileTransfers.shared.addObserver { [weak self] list in
            Task { @MainActor in self?.transfers = list }
        }
    }

    deinit {
        if let token { SPPWFileTransfers.shared.removeObserver(token) }
    }

    /// Running transfers plus finished/failed ones until the user clears them.
    var visible: [SPPWFileTransferStatus] { Array(transfers.prefix(4)) }

    func cancel(_ id: UUID) { SPPWFileTransfers.shared.cancel(id) }
    func clearFinished() { SPPWFileTransfers.shared.clearFinished() }
}

/// Compact list of background clipboard transfers with progress and cancel.
struct FileTransfersView: View {
    @StateObject private var monitor = FileTransferMonitor()
    var compact = false

    var body: some View {
        let items = monitor.visible
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    row(item)
                }
                if items.contains(where: { !$0.isActive }) {
                    Button(SPPWLocalization.tr("transfer.clear")) { monitor.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }
            .padding(compact ? 8 : 10)
            .frame(maxWidth: compact ? 280 : .infinity, alignment: .leading)
            .background(compact ? AnyShapeStyle(.black.opacity(0.65)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(compact ? Color.white : Color.primary)
        }
    }

    private func row(_ item: SPPWFileTransferStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if item.isActive {
                    Button {
                        monitor.cancel(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help(SPPWLocalization.tr("transfer.cancel"))
                }
            }
            .font(.caption)
            ProgressView(value: item.fraction)
                .progressViewStyle(.linear)
                .tint(tint(item.state))
            Text(detail(item))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(compact ? Color.white.opacity(0.7) : Color.secondary)
        }
    }

    private func tint(_ state: SPPWFileTransferStatus.State) -> Color {
        switch state {
        case .finished: .green
        case .failed, .cancelled: .orange
        case .waiting, .running: .accentColor
        }
    }

    private func detail(_ item: SPPWFileTransferStatus) -> String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.doneBytes), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: item.totalBytes), countStyle: .file)
        switch item.state {
        case .waiting: return SPPWLocalization.tr("transfer.waiting_fmt", total)
        case .running: return "\(done) / \(total)"
        case .finished: return SPPWLocalization.tr("transfer.done_fmt", total)
        case let .failed(reason): return SPPWLocalization.tr("transfer.failed_fmt", reason)
        case .cancelled: return SPPWLocalization.tr("transfer.cancelled")
        }
    }
}
