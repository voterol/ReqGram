import Foundation
import Postbox
import SGSimpleSettings
import SwiftSignalKit

private struct LocalEmojiStatusOverride: Codable, Equatable {
    enum Value: Equatable {
        case none
        case status(PeerEmojiStatus)
    }

    let value: Value

    private enum CodingKeys: String, CodingKey {
        case kind
        case status
        case value
    }

    private enum LegacyValueKeys: String, CodingKey {
        case none
        case status
    }

    private enum LegacyStatusKeys: String, CodingKey {
        case value = "_0"
    }

    private struct LegacyValue: Decodable {
        let status: PeerEmojiStatus?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: LegacyValueKeys.self)
            if container.contains(.status) {
                self.status = try container.decode(LegacyStatus.self, forKey: .status).value
            } else {
                self.status = nil
            }
        }
    }

    private struct LegacyStatus: Decodable {
        let value: PeerEmojiStatus

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: LegacyStatusKeys.self)
            self.value = try container.decode(PeerEmojiStatus.self, forKey: .value)
        }
    }

    init(value: Value) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(Int32.self, forKey: .kind) {
            if kind == 1, let status = try container.decodeIfPresent(PeerEmojiStatus.self, forKey: .status) {
                self.value = .status(status)
            } else {
                self.value = .none
            }
            return
        }

        // Read values written by the former synthesized nested enum without
        // asking Codable to instantiate that enum's crashing metadata or the
        // Postbox decoder for its unsupported nestedContainer operation.
        if container.contains(.value) {
            if let status = try container.decode(LegacyValue.self, forKey: .value).status {
                self.value = .status(status)
            } else {
                self.value = .none
            }
        } else {
            self.value = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.value {
        case .none:
            try container.encode(Int32(0), forKey: .kind)
        case let .status(status):
            try container.encode(Int32(1), forKey: .kind)
            try container.encode(status, forKey: .status)
        }
    }
}

private let localEmojiStatusOverrideKey = applicationSpecificPreferencesKey(927)

private func localPremiumEnabledSignal() -> Signal<Bool, NoError> {
    let initial = Signal<Bool, NoError>.single(SGSimpleSettings.shared.ayuLocalPremium)
    let updates = Signal<Bool, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            DispatchQueue.main.async {
                subscriber.putNext(SGSimpleSettings.shared.ayuLocalPremium)
            }
        }
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    return (initial |> then(updates)) |> distinctUntilChanged
}

func setLocalEmojiStatusOverride(transaction: Transaction, status: PeerEmojiStatus?) {
    let value: LocalEmojiStatusOverride.Value = status.flatMap { .status($0) } ?? .none
    transaction.updatePreferencesEntry(key: localEmojiStatusOverrideKey, { _ in
        return PreferencesEntry(LocalEmojiStatusOverride(value: value))
    })
}

private func clearExpiredLocalEmojiStatusOverride(transaction: Transaction) {
    transaction.updatePreferencesEntry(key: localEmojiStatusOverrideKey, { _ in
        return nil
    })
}

public extension TelegramEngine.AccountData {
    func resolvedEmojiStatus(serverStatus: PeerEmojiStatus?) -> Signal<PeerEmojiStatus?, NoError> {
        let override = self.account.postbox.preferencesView(keys: [localEmojiStatusOverrideKey])
        |> map { view -> LocalEmojiStatusOverride? in
            return view.values[localEmojiStatusOverrideKey]?.get(LocalEmojiStatusOverride.self)
        }
        return combineLatest(override, localPremiumEnabledSignal())
        |> mapToSignal { override, enabled -> Signal<PeerEmojiStatus?, NoError> in
            guard enabled, let override else {
                return .single(serverStatus)
            }
            switch override.value {
            case .none:
                return .single(nil)
            case let .status(status):
                if let expirationDate = status.expirationDate {
                    let remaining = Double(expirationDate) - Date().timeIntervalSince1970
                    let normalize = self.account.postbox.transaction { transaction -> Void in
                        guard let current = transaction.getPreferencesEntry(key: localEmojiStatusOverrideKey)?.get(LocalEmojiStatusOverride.self), current == override else {
                            return
                        }
                        clearExpiredLocalEmojiStatusOverride(transaction: transaction)
                    }
                    if remaining <= 0.0 {
                        // Normalize immediately. The equality check prevents a
                        // stale expiry callback from clearing a newer choice.
                        return normalize |> map { _ in serverStatus }
                    }
                    return .single(Optional(status))
                    |> then(.single(()) |> delay(remaining, queue: Queue.mainQueue()) |> then(normalize) |> map { _ in serverStatus })
                }
                return .single(status)
            }
        }
        |> distinctUntilChanged
    }
}
