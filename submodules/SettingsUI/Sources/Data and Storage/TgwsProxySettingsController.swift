import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import SGSimpleSettings

func tgwsRuntimeLabel(languageCode: String = "en") -> String {
    let ru = languageCode.lowercased().hasPrefix("ru")
    switch TgwsProxySettings.shared.state {
    case .disabled: return ru ? "Выключен" : "Disabled"
    case .starting: return ru ? "Запуск…" : "Starting"
    case .ready: return ru ? "Готов" : "Ready"
    case .upstreamConnected: return ru ? "Подключён" : "Connected"
    case .handshakeRejected: return ru ? "Ошибка авторизации" : "Authentication failed"
    case .upstreamConnectFailed: return ru ? "Ошибка подключения" : "Connection failed"
    case .suspended: return ru ? "Приостановлен" : "Paused"
    case .failed: return ru ? "Недоступен" : "Unavailable"
    }
}

private func tgwsUpstreamFailureLabel(_ code: String) -> String {
    switch code {
    case "dns": return "name resolution failed"
    case "refused": return "connection was refused"
    case "tls": return "secure connection could not be verified"
    case "protocol": return "WebSocket handshake failed"
    case "timeout": return "connection timed out"
    case "network": return "network is unavailable"
    default: return "the service could not be reached"
    }
}

/// Retain exact identities across port edits until the coordinator removes the
/// old route. Never classify unrelated loopback proxies as managed.
private var tgwsKnownIdentities: [TgwsProxySettings.Configuration] = []
private let tgwsIdentityLock = NSLock()
func tgwsIsManagedProxy(_ server: ProxyServerSettings) -> Bool {
    guard case let .mtp(secret) = server.connection else { return false }
    if TgwsProxySettings.shared.isManagedProxy(host: server.host, port: Int(server.port), secret: secret) { return true }
    tgwsIdentityLock.lock()
    defer { tgwsIdentityLock.unlock() }
    return tgwsKnownIdentities.contains { server.host == "127.0.0.1" && Int(server.port) == $0.port && secret == Data([0xdd]) + $0.secretData }
}

func tgwsSettingsChanges() -> Signal<Int, NoError> {
    return Signal { subscriber in
        var revision = 0
        func emit() {
            if let configuration = try? TgwsProxySettings.shared.configuration() {
                tgwsIdentityLock.lock()
                if !tgwsKnownIdentities.contains(configuration) { tgwsKnownIdentities.append(configuration) }
                tgwsIdentityLock.unlock()
            }
            revision += 1
            subscriber.putNext(revision)
        }
        emit()
        let observers = [TgwsProxySettings.didChange, TgwsProxySettings.stateDidChange, TgwsProxyReleaseChecker.didChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in emit() }
        }
        return ActionDisposable { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

private final class TgwsDetailArguments {
    var observers: [NSObjectProtocol] = []
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    var toggle: (Bool) -> Void = { _ in }
    var editPort: () -> Void = {}
    var secret: () -> Void = {}
    var automatic: (Bool) -> Void = { _ in }
    var check: () -> Void = {}
    var releases: () -> Void = {}
    var compatibility: () -> Void = {}
}

private struct TgwsDetailEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case text(String)
        case toggle(String, Bool, Bool)
        case action(String, Bool, Int)
        case disclosure(String, String, Bool, Int)
    }
    let stableId: Int
    let section: ItemListSectionId
    let theme: PresentationTheme
    let content: Content
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stableId == rhs.stableId && lhs.section == rhs.section && lhs.theme === rhs.theme && lhs.content == rhs.content
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.stableId < rhs.stableId }
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TgwsDetailArguments
        switch content {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .toggle(title, value, automatic):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: !automatic, sectionId: section, style: .blocks, updated: automatic ? arguments.automatic : arguments.toggle)
        case let .action(title, enabled, action):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: enabled, label: "", sectionId: section, style: .blocks, disclosureStyle: .none, action: {
                guard enabled else { return }
                switch action {
                case 1: arguments.check()
                case 2: arguments.releases()
                case 4: arguments.compatibility()
                case 5: arguments.editPort()
                default: arguments.secret()
                }
            })
        case let .disclosure(title, label, enabled, action):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, enabled: enabled, label: label, labelStyle: .text, sectionId: section, style: .blocks, disclosureStyle: .arrow, action: {
            guard enabled else { return }
            switch action {
            case 3: arguments.secret()
            case 4: arguments.compatibility()
            case 5: arguments.editPort()
            default: break
            }
            })
        }
    }
}

private struct TgwsDetailState: Equatable {
    var error: String?
}

func tgwsProxySettingsController(presentationData: PresentationData, updatedPresentationData: Signal<PresentationData, NoError>) -> ViewController {
    let settings = TgwsProxySettings.shared
    let updater = TgwsProxyReleaseChecker.shared
    let state = Atomic(value: TgwsDetailState())
    let promise = ValuePromise<TgwsDetailState>(state.with { $0 }, ignoreRepeated: true)
    func update(_ f: (inout TgwsDetailState) -> Void) {
        promise.set(state.modify { current in var current = current; f(&current); return current })
    }
    let arguments = TgwsDetailArguments()
    weak var settingsController: ViewController?
    var presentSecretController: (() -> Void)?
    var dismissSecretAlerts: (() -> Void)?
    weak var activeSecretAlert: UIAlertController?
    arguments.toggle = { value in
        do { try settings.update(enabled: value); update { $0.error = nil } }
        catch { update { $0.error = "Could not save Tgwsproxy settings. The route was not changed." } }
    }
    arguments.editPort = {
        guard let controller = settingsController else { return }
        let alert = UIAlertController(title: "Local port", message: "Choose a port from 1024 to 65535.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = String(settings.port)
            field.keyboardType = .numberPad
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            guard let port = Int(text), settings.validatePortForUI(text) else {
                update { $0.error = "Enter a port from 1024 to 65535." }
                return
            }
            do { try settings.update(port: port); update { $0.error = nil } }
            catch { update { $0.error = "Could not save the local port." } }
        })
        controller.present(alert, animated: true)
    }
    arguments.automatic = { _ in }
    arguments.check = { if UIApplication.shared.applicationState == .active { updater.check(manual: true) } }
    arguments.releases = { UIApplication.shared.open(TgwsProxyReleaseChecker.releasesURL, options: [:], completionHandler: nil) }
    arguments.secret = { presentSecretController?() }
    arguments.compatibility = {
        guard let controller = settingsController else { return }
        guard let config = try? settings.configuration() else { return }
        let alert = UIAlertController(title: "Advanced settings", message: "Optional compatibility values. Changes restart the local route.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Buffer (KB)"; $0.text = String(config.bufferKB); $0.keyboardType = .numberPad }
        alert.addTextField { $0.placeholder = "Pool size"; $0.text = String(config.poolSize); $0.keyboardType = .numberPad }
        alert.addTextField { $0.placeholder = "CF Worker domains (comma-separated)"; $0.text = config.cfWorkerDomains.joined(separator: ",") }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
            let fields = alert.textFields ?? []
            guard fields.count >= 3, let buffer = Int(fields[0].text ?? ""), let pool = Int(fields[1].text ?? "") else { return }
            let domains = (fields[2].text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            do { try settings.update(bufferKB: buffer, poolSize: pool, cfWorkerDomains: domains) }
            catch { update { $0.error = "Compatibility settings were not saved. Check the numeric ranges and domain names." } }
        })
        controller.present(alert, animated: true)
    }
    let signal = combineLatest(updatedPresentationData, promise.get(), tgwsSettingsChanges())
    |> deliverOnMainQueue
    |> map { data, state, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var entries: [TgwsDetailEntry] = []
        func add(_ section: Int32, _ content: TgwsDetailEntry.Content) {
            entries.append(TgwsDetailEntry(stableId: entries.count, section: section, theme: data.theme, content: content))
        }
        add(0, .toggle("Tgwsproxy", settings.enabled, false))
        add(0, .text("Telegram traffic only. Calls and other app traffic are not routed through it."))
        if let notice = settings.recoveryNotice {
            let explanation = notice == "invalid_settings_repaired"
                ? "Invalid stored Tgwsproxy settings were repaired. Tgwsproxy was re-enabled with the default local port and a new private authentication identity. Review the current port and route before relying on connectivity. This repair does not authorize a direct fallback for managed MTProto account traffic."
                : "The app recorded a Tgwsproxy configuration recovery notice. Review the current port, enabled state and selected route before relying on connectivity."
            add(0, .text(explanation))
        }
        add(1, .header("STATUS"))
        let statusSummary: String
        switch settings.state {
        case .disabled: statusSummary = "Off"
        case .starting: statusSummary = "Starting…"
        case .ready: statusSummary = "Ready"
        case .upstreamConnected: statusSummary = "Connected"
        case .handshakeRejected: statusSummary = "Authentication failed"
        case .upstreamConnectFailed: statusSummary = "Connection failed"
        case .suspended: statusSummary = "Paused"
        case .failed: statusSummary = "Unavailable"
        }
        add(1, .disclosure("Connection status", statusSummary, true, 6))
        if let code = settings.lastNativeErrorCode {
            add(1, .text("Error: \(code)"))
        }
        if case let .failed(code) = settings.state {
            let message: String
            switch code {
            case "listener_failed": message = "Could not bind the listener. The port may be in use. Choose another local port."
            case "invalid_settings", "invalid_config": message = "Stored configuration is invalid. Tgwsproxy remains unavailable."
            case "not_foreground": message = "The listener can run only while the app is active."
            case "already_running": message = "A listener is already running. Retry by disabling and enabling Tgwsproxy."
            default: message = "The native listener failed. No direct fallback was enabled for managed MTProto account traffic; calls and other app traffic are outside this guarantee."
            }
            add(1, .text(message))
        }
        if settings.state == .handshakeRejected {
            add(1, .text("Check the private secret. This is not a Telegram authorization result."))
        } else if case .upstreamConnectFailed = settings.state {
            add(1, .text("The local route is ready, but the connection failed."))
        } else if settings.state == .upstreamConnected {
            add(1, .text("Telegram account authorization is separate from this connection."))
        }
        add(2, .header("LISTENER"))
        add(2, .disclosure("Local port", String(settings.port), true, 5))
        add(2, .disclosure("Private secret", "Configured", true, 3))
        if let error = state.error { add(2, .text(error)) }
        if (try? settings.configuration()) != nil {
            add(2, .disclosure("Advanced", "Buffer & pool", true, 4))
        }
        add(3, .header("ABOUT"))
        add(3, .disclosure("Flowseal release", "Unavailable", false, 1))
        add(3, .toggle("Automatic checks", false, true))
        add(3, .action("Open releases", true, 2))
        add(3, .text("Checks GitHub for release metadata only. The native iOS core updates only with a new signed app build."))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text("Tgwsproxy"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back))
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .blocks), arguments))
    }
    let controller = ItemListController(presentationData: ItemListPresentationData(presentationData), updatedPresentationData: updatedPresentationData |> map(ItemListPresentationData.init(_:)), state: signal, tabBarItem: nil)
    settingsController = controller
    presentSecretController = { [weak controller] in
        guard let controller else { return }
        func presentManualInput() {
            let input = UIAlertController(title: "Replace private secret", message: "Enter 32 hexadecimal characters, or dd followed by 32 characters. Replacing it disconnects clients and restarts the managed route.", preferredStyle: .alert)
            input.addTextField { field in field.isSecureTextEntry = true; field.autocorrectionType = .no; field.autocapitalizationType = .none }
            activeSecretAlert = input
            input.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        input.addAction(UIAlertAction(title: "Replace", style: .destructive) { _ in
                guard let value = input.textFields?.first?.text else { return }
                input.textFields?.forEach { $0.text = nil }
                input.message = nil
                do {
                    try settings.update(secret: value)
                } catch {
                    let error = UIAlertController(title: "Invalid private secret", message: "Enter 32 hexadecimal characters, optionally prefixed with dd.", preferredStyle: .alert)
                    error.addAction(UIAlertAction(title: "Try again", style: .default) { _ in presentManualInput() })
                    error.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    activeSecretAlert = error
                    controller.present(error, animated: true)
                }
            })
            controller.present(input, animated: true)
        }
        let alert = UIAlertController(title: "Private authentication secret", message: "The secret is unique to this installation and is masked by default. Revealing or replacing it may disconnect existing clients.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = String(repeating: "•", count: 32)
            field.isSecureTextEntry = true
            field.isUserInteractionEnabled = false
        }
        alert.addAction(UIAlertAction(title: "Reveal", style: .default) { _ in
            let secret = (try? settings.configuration())?.secret ?? "Unavailable"
            let reveal = UIAlertController(title: "Private secret", message: secret, preferredStyle: .alert)
            reveal.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
                guard secret != "Unavailable" else { return }
                UIPasteboard.general.string = secret
            })
            reveal.addAction(UIAlertAction(title: "Done", style: .cancel) { _ in reveal.message = nil })
            activeSecretAlert = reveal
            controller.present(reveal, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Enter manually", style: .default) { _ in
            presentManualInput()
        })
        alert.addAction(UIAlertAction(title: "Regenerate", style: .destructive) { _ in
            let confirm = UIAlertController(title: "Regenerate secret?", message: "Existing clients will be disconnected and the managed route will restart. The previous secret will not be retained in the saved proxy list.", preferredStyle: .alert)
            activeSecretAlert = confirm
            confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            confirm.addAction(UIAlertAction(title: "Regenerate", style: .destructive) { _ in
                do {
                    try settings.regenerateSecret()
                    confirm.dismiss(animated: true)
                } catch {
                    let error = UIAlertController(title: "Could not regenerate secret", message: "The private secret was not changed. Try again.", preferredStyle: .alert)
                    error.addAction(UIAlertAction(title: "OK", style: .default))
                    activeSecretAlert = error
                    controller.present(error, animated: true)
                }
            })
            controller.present(confirm, animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        activeSecretAlert = alert
        dismissSecretAlerts = {
            guard let alert = activeSecretAlert else { return }
            alert.message = nil
            alert.textFields?.forEach { $0.text = nil }
            alert.dismiss(animated: false)
            activeSecretAlert = nil
        }
        controller.present(alert, animated: true)
    }
    controller.didAppear = { (_: Bool) in }
    let foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak controller] _ in
        _ = controller
    }
    let background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
        updater.cancel()
        dismissSecretAlerts?()
    }
    arguments.observers = [foreground, background]
    return controller
}

private extension TgwsProxySettings {
    func validatePortForUI(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let port = Int(text) else { return false }
        return Self.validate(port: port)
    }
}
