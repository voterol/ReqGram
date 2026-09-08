import Foundation
import SwiftSignalKit
import SGSimpleSettings

// MARK: AyuGram - react to privacy setting changes in long-lived core tasks
func ayuBlockOnlinePresenceSignal() -> Signal<Bool, NoError> {
    return ayuSettingsSignal {
        return SGSimpleSettings.shared.isAyuBlockOnlinePresence
    }
}

func ayuBlockReadReceiptsSignal() -> Signal<Bool, NoError> {
    return ayuSettingsSignal {
        return SGSimpleSettings.shared.isAyuBlockReadReceipts
    }
}

private func ayuSettingsSignal(_ value: @escaping () -> Bool) -> Signal<Bool, NoError> {
    return Signal<Bool, NoError> { subscriber in
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                subscriber.putNext(value())
            }
        }
        subscriber.putNext(value())
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    |> distinctUntilChanged
}
