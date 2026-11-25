import SwiftUI
import UIKit
#if canImport(SPPWCommon)
import SPPWCommon
#endif

// MARK: - Server: encryption, pairing PIN, password, paired receivers

/// Security card of the iOS server screen (hosted in UIKit).
struct IOSServerSecurityPanel: View {
    @ObservedObject var model: IOSServerModel
    @State private var newPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SPPWLocalization.tr("security.section"))
                .font(.headline)
            if let prompt = model.pairingPIN {
                pinBanner(prompt)
            }
            Toggle(SPPWLocalization.tr("security.encryption"), isOn: $model.encryptionEnabled)
            Text(SPPWLocalization.tr("security.encryption.help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.encryptionEnabled {
                Picker(SPPWLocalization.tr("security.pairing_mode"), selection: $model.pairingMode) {
                    Text(SPPWLocalization.tr("security.mode.pin")).tag(SPPWPairingMode.pin)
                    Text(SPPWLocalization.tr("security.mode.password")).tag(SPPWPairingMode.password)
                    Text(SPPWLocalization.tr("security.mode.open")).tag(SPPWPairingMode.open)
                }
                .pickerStyle(.segmented)
                Text(modeHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.pairingMode == .pin && !model.broadcastSharesSecurity {
                    Text(SPPWLocalization.tr("security.broadcast_open_note"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if model.pairingMode == .password {
                    HStack {
                        SecureField(SPPWLocalization.tr("security.password.placeholder"), text: $newPassword)
                            .textFieldStyle(.roundedBorder)
                        Button(SPPWLocalization.tr("security.password.save")) {
                            model.setPairingPassword(newPassword)
                            newPassword = ""
                        }
                        .disabled(newPassword.isEmpty)
                    }
                    Label(
                        SPPWLocalization.tr(model.hasPairingPassword ? "security.password.set" : "security.password.missing"),
                        systemImage: model.hasPairingPassword ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(model.hasPairingPassword ? Color.green : Color.orange)
                }
                IOSFingerprintRow(fingerprint: model.serverFingerprint)
                IOSPairedDevicesList(
                    title: SPPWLocalization.tr("security.paired_clients_fmt", model.pairedClients.count),
                    peers: model.pairedClients,
                    onForget: model.forgetPairedClient
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeHelp: String {
        switch model.pairingMode {
        case .pin: SPPWLocalization.tr("security.mode.pin.help")
        case .password: SPPWLocalization.tr("security.mode.password.help")
        case .open: SPPWLocalization.tr("security.mode.open.help")
        }
    }

    private func pinBanner(_ prompt: SPPWPairingPINPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(SPPWLocalization.tr("security.pin.title"), systemImage: "lock.shield.fill")
                .font(.subheadline.weight(.semibold))
            Text(prompt.pin)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .kerning(10)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            Text(SPPWLocalization.tr("security.pin.subtitle_fmt", prompt.clientName, prompt.clientFingerprint.short))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(SPPWLocalization.tr("security.pin.expires_fmt", max(0, Int(prompt.expiresAt.timeIntervalSince(context.date).rounded(.up)))))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(SPPWLocalization.tr("security.pin.dismiss"), role: .destructive) { model.dismissPairingPIN() }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Receiver: encryption toggle, fingerprint, paired servers

struct IOSReceiverSecurityPanel: View {
    @ObservedObject var model: IOSReceiverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(SPPWLocalization.tr("security.encryption"), isOn: $model.encryptionEnabled)
                .disabled(model.isConnected)
            Text(SPPWLocalization.tr("security.receiver.encryption.help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.encryptionEnabled {
                IOSFingerprintRow(fingerprint: model.deviceFingerprint)
                IOSPairedDevicesList(
                    title: SPPWLocalization.tr("security.paired_servers_fmt", model.pairedServers.count),
                    peers: model.pairedServers,
                    onForget: model.forgetPairedServer
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IOSFingerprintRow: View {
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SPPWLocalization.tr("security.fingerprint_this"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(fingerprint)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }
}

struct IOSPairedDevicesList: View {
    let title: String
    let peers: [SPPWTrustedPeer]
    let onForget: (SPPWTrustedPeer) -> Void

    var body: some View {
        DisclosureGroup(title) {
            if peers.isEmpty {
                Text(SPPWLocalization.tr("security.none_paired"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(peers) { peer in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(peer.name).font(.subheadline)
                        Text(peer.fingerprint.short).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(SPPWLocalization.tr("security.forget"), role: .destructive) { onForget(peer) }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// A SwiftUI view inside a UIKit stack, sized to its content.
@MainActor
func makeIOSHostedView<Content: View>(_ content: Content, parent: UIViewController) -> UIView {
    let host = UIHostingController(rootView: content)
    host.sizingOptions = .intrinsicContentSize
    host.view.backgroundColor = .clear
    parent.addChild(host)
    host.didMove(toParent: parent)
    return host.view
}

// MARK: - Pairing prompt

extension IOSReceiverModel {
    /// Alert asking for the server's PIN or password.
    func makePairingAlert(_ request: SPPWPairingRequest) -> UIAlertController {
        let isPIN = request.method == .pin
        var message = SPPWLocalization.tr(
            isPIN ? "security.prompt.pin.message_fmt" : "security.prompt.password.message_fmt",
            request.serverName,
            request.serverFingerprint.display
        )
        if request.previousAttemptFailed {
            message += "\n\n" + (isPIN && request.attemptsLeft >= SPPWServerSecurity.pinAttempts
                ? SPPWLocalization.tr("security.prompt.renewed")
                : SPPWLocalization.tr("security.prompt.wrong_fmt", request.attemptsLeft))
        }
        let alert = UIAlertController(
            title: SPPWLocalization.tr(isPIN ? "security.prompt.pin.title" : "security.prompt.password.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            if isPIN {
                field.keyboardType = .numberPad
                field.textContentType = .oneTimeCode
                field.placeholder = "00000"
                field.textAlignment = .center
                field.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
            } else {
                field.isSecureTextEntry = true
                field.textContentType = .password
            }
        }
        alert.addAction(UIAlertAction(title: SPPWLocalization.tr("security.prompt.cancel"), style: .cancel) { [weak self] _ in
            self?.cancelPairing()
        })
        let pair = UIAlertAction(title: SPPWLocalization.tr("security.prompt.pair"), style: .default) { [weak self, weak alert] _ in
            let secret = alert?.textFields?.first?.text ?? ""
            self?.providePairingSecret(isPIN ? String(secret.filter(\.isNumber).prefix(5)) : secret)
        }
        alert.addAction(pair)
        alert.preferredAction = pair
        return alert
    }
}
