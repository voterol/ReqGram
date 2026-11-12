import SGSimpleSettings
import Foundation
import SwiftSignalKit

public func sgSimpleSettingsBoolSignal(_ key: SGSimpleSettings.Keys, defaultValue: Bool) -> Signal<Bool, NoError> {
    let initial = Signal<Bool, NoError>.single(UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? defaultValue)
    let changes = Signal<Bool, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            let value = UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? defaultValue
            subscriber.putNext(value)
        }
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    return (initial |> then(changes)) |> distinctUntilChanged
}

public func sgSimpleSettingsStringSignal(_ key: SGSimpleSettings.Keys, defaultValue: String) -> Signal<String, NoError> {
    let initial = Signal<String, NoError>.single(UserDefaults.standard.object(forKey: key.rawValue) as? String ?? defaultValue)
    let changes = Signal<String, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in
            let value = UserDefaults.standard.object(forKey: key.rawValue) as? String ?? defaultValue
            subscriber.putNext(value)
        }
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    return (initial |> then(changes)) |> distinctUntilChanged
}
