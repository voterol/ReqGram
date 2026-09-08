import Foundation
import SGLogging
import SGSimpleSettings
#if canImport(UIKit)
import UIKit
#endif

/// iOS adaptation of AyuGram's Streamer Mode.
///
/// The desktop original excludes windows from screen capture outright
/// (`NSWindowSharingNone` / `SetWindowDisplayAffinity`). iOS exposes no such
/// per-window API, so this instead *observes* capture state: the app reports
/// when the screen is being mirrored or recorded, and the UI layer blurs or
/// hides sensitive content in response. Screenshots are reported separately,
/// since they cannot be prevented, only detected after the fact.
public final class AyuStreamerMode {
    public static let shared = AyuStreamerMode()

    /// Called on the main queue whenever the effective "should obscure content"
    /// state changes. Subscribers must use weak captures.
    public static var onStateChanged: ((Bool) -> Void)?

    /// Called on the main queue when the user takes a screenshot while streamer
    /// mode is enabled, so the UI can warn.
    public static var onScreenshotTaken: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var lastReportedState = false

    private init() {}

    /// True when streamer mode is on and the screen is currently being captured.
    public var shouldObscureContent: Bool {
        guard SGSimpleSettings.shared.ayuStreamerMode else { return false }
        #if canImport(UIKit)
        return UIScreen.main.isCaptured
        #else
        return false
        #endif
    }

    /// Begins observing capture state. Idempotent; safe to call on every launch.
    public func start() {
        #if canImport(UIKit)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.start()
            }
            return
        }
        guard !self.started else { return }
        self.started = true

        let center = NotificationCenter.default
        self.observers.append(center.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyStateChanged()
        })
        self.observers.append(center.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard SGSimpleSettings.shared.ayuStreamerMode else { return }
            AyuStreamerMode.onScreenshotTaken?()
        })

        self.lastReportedState = self.shouldObscureContent
        SGLogger.shared.log("AyuGram", "StreamerMode: observing capture state")
        #endif
    }

    /// Re-evaluates and republishes state, e.g. after the setting is toggled.
    public func notifyStateChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.notifyStateChanged()
            }
            return
        }
        let state = self.shouldObscureContent
        guard state != self.lastReportedState else { return }
        self.lastReportedState = state
        SGLogger.shared.log("AyuGram", "StreamerMode: obscure=\(state)")
        AyuStreamerMode.onStateChanged?(state)
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
