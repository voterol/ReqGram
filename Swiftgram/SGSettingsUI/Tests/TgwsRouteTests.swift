import Foundation
import XCTest
import TelegramCore
import SGSettingsUI
import SGSimpleSettings
import SwiftSignalKit

final class TgwsRouteTests: XCTestCase {
    func testSignalCompletionDisposesAttemptWithoutCancellation() {
        var disposed = false
        var completed = false
        let signal = Signal<Void, NoError> { subscriber in
            subscriber.putCompletion()
            return ActionDisposable {
                disposed = true
                XCTAssertTrue(completed)
            }
        }

        let disposable = signal.start(completed: { completed = true })

        XCTAssertTrue(disposed)
        // SwiftSignalKit disposes the generator after completion. The
        // coordinator therefore needs a separate finished flag to distinguish
        // that disposal from subscriber cancellation.
        XCTAssertTrue(completed)
        disposable.dispose()
        XCTAssertTrue(disposed)
    }

    func testSignalDisposalDoesNotCompleteSubscriber() {
        var completed = false
        let signal = Signal<Void, NoError> { _ in
            return ActionDisposable {}
        }

        let disposable = signal.start(completed: { completed = true })
        disposable.dispose()

        XCTAssertFalse(completed)
    }

    func testUpstreamFailureDiagnosticsAreAllowlistedAndRedacted() {
        XCTAssertEqual(TgwsProxySettings.upstreamFailureCode("tls"), "tls")
        XCTAssertEqual(TgwsProxySettings.upstreamFailureCode("timeout"), "timeout")
        XCTAssertEqual(TgwsProxySettings.upstreamFailureCode("NSError(domain: secret)"), "unknown")
        XCTAssertEqual(TgwsProxySettings.upstreamFailureCode(nil), "unknown")
    }

    func testClientHandshakeDiagnosticsAreAllowlistedAndRedacted() {
        XCTAssertEqual(TgwsProxySettings.clientHandshakeRejectionCode("invalid_protocol"), "invalid_protocol")
        XCTAssertEqual(TgwsProxySettings.clientHandshakeRejectionCode("unsupported_dc"), "unsupported_dc")
        XCTAssertNil(TgwsProxySettings.clientHandshakeRejectionCode("secret=deadbeef"))
        XCTAssertNil(TgwsProxySettings.clientHandshakeRejectionCode(nil))
    }

    func testLifecycleStartFailuresAreTransientAndAllowlisted() {
        XCTAssertTrue(TgwsProxySettings.isTransientStartupFailure("not_foreground"))
        XCTAssertTrue(TgwsProxySettings.isTransientStartupFailure("start_cancelled"))
        XCTAssertEqual(TgwsProxySettings.startupLifecycleCode("start_cancelled"), "start_cancelled")
        XCTAssertFalse(TgwsProxySettings.isTransientStartupFailure("listener_failed"))
        XCTAssertNil(TgwsProxySettings.startupLifecycleCode("NSError(domain: secret)"))
    }

    func testDeletedPriorRouteIsNotReactivated() {
        let prior = ProxyServerSettings(host: "deleted.invalid", port: 1080, connection: .socks5(username: nil, password: nil))
        let local = ProxyServerSettings(host: "127.0.0.1", port: 1443, connection: .mtp(secret: Data(repeating: 1, count: 17)))
        let original = ProxySettings(enabled: true, servers: [prior], activeServer: prior, useForCalls: true)
        let record = TgwsManagedRoute(previous: original, server: local)
        var current = record.install(into: original)
        current.servers.removeAll { $0 == prior }
        let restored = record.restore(from: current)
        XCTAssertNil(restored.activeServer)
        XCTAssertFalse(restored.enabled)
        XCTAssertFalse(restored.useForCalls)
        XCTAssertFalse(restored.servers.contains(prior))
    }

    func testQueuedDisableCannotWriteAfterReenableOrABA() throws {
        // Queue the SAME mutation fence used inside AccountManager transactions.
        // No native listener/accounts are created by this deterministic schedule.
        let suite = "tgws.transaction.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TgwsProxySettings(defaults: defaults)
        let fence = TgwsRouteTransactionFence()
        let local = ProxyServerSettings(host: "127.0.0.1", port: 1443, connection: .mtp(secret: Data(repeating: 1, count: 17)))
        let record = TgwsManagedRoute(previous: .defaultSettings, server: local)
        var route = record.install(into: .defaultSettings)
        var ownership: TgwsManagedRoute? = record
        var writes = 0
        try settings.update(enabled: false)
        let disabled = try settings.snapshot()
        let version = fence.advance()
        let queuedDisable = {
            fence.mutate(version: version, settings: settings, snapshot: disabled) {
                route = record.restore(from: route)
                ownership = nil
                writes += 1
            }
        }
        try settings.update(enabled: true)
        // Even before notification/version advancement, the MODEL edit fences
        // both database writes. A callback-only fence cannot pass this test.
        XCTAssertFalse(queuedDisable())
        XCTAssertTrue(route.enabled)
        XCTAssertNotNil(ownership)
        XCTAssertEqual(writes, 0)
        try settings.update(enabled: false)
        XCTAssertFalse(queuedDisable()) // same config, different revision (ABA)
        let latest = try settings.snapshot()
        let latestVersion = fence.advance()
        XCTAssertFalse(fence.mutate(version: version, settings: settings, snapshot: latest) { writes += 1 })
        XCTAssertTrue(fence.mutate(version: latestVersion, settings: settings, snapshot: latest) {
            route = record.restore(from: route)
            ownership = nil
            writes += 1
        })
        XCTAssertFalse(route.enabled)
        XCTAssertNil(ownership)
        XCTAssertEqual(writes, 1)
    }

    func testVersionCannotAdvanceBetweenCheckAndWrites() throws {
        let suite = "tgws.lock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TgwsProxySettings(defaults: defaults)
        let snapshot = try settings.snapshot()
        let fence = TgwsRouteTransactionFence()
        let version = fence.advance()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let attemptingAdvance = DispatchSemaphore(value: 0)
        let advanced = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let applied = fence.mutate(version: version, settings: settings, snapshot: snapshot) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            XCTAssertTrue(applied)
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            attemptingAdvance.signal()
            fence.advance()
            advanced.signal()
        }
        XCTAssertEqual(attemptingAdvance.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(advanced.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(advanced.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(fence.mutate(version: version, settings: settings, snapshot: snapshot) { XCTFail("stale mutation") })
    }
    func testRestoreAndDeduplicate() {
        let prior = ProxyServerSettings(host: "prior.invalid", port: 1080, connection: .socks5(username: nil, password: nil))
        let local = ProxyServerSettings(host: "127.0.0.1", port: 1443, connection: .mtp(secret: Data([0xdd]) + Data(repeating: 1, count: 16)))
        let original = ProxySettings(enabled: true, servers: [prior], activeServer: prior, useForCalls: true)
        let record = TgwsManagedRoute(previous: original, server: local)
        let installed = record.install(into: original)
        XCTAssertEqual(record.install(into: installed), installed)
        XCTAssertEqual(record.restore(from: installed), original)
        let encoded = try! JSONEncoder().encode(record)
        let decoded = try! JSONDecoder().decode(TgwsManagedRoute.self, from: encoded)
        XCTAssertEqual(decoded.restore(from: installed), original)
        var edited = installed
        edited.activeServer = prior
        edited.enabled = false
        XCTAssertEqual(record.restore(from: edited).activeServer, prior)
        XCTAssertFalse(record.restore(from: edited).enabled)
        edited = installed
        edited.useForCalls = true
        XCTAssertTrue(record.restore(from: edited).useForCalls)
    }
    func testRestoreDirectPreservesConcurrentListChanges() {
        let local = ProxyServerSettings(host: "127.0.0.1", port: 1443, connection: .mtp(secret: Data(repeating: 1, count: 17)))
        let added = ProxyServerSettings(host: "added.invalid", port: 1080, connection: .socks5(username: nil, password: nil))
        let record = TgwsManagedRoute(previous: .defaultSettings, server: local)
        var installed = record.install(into: .defaultSettings)
        installed.servers.append(added)
        let restored = record.restore(from: installed)
        XCTAssertFalse(restored.enabled)
        XCTAssertNil(restored.activeServer)
        XCTAssertEqual(restored.servers, [added])
    }

    func testRotatingManagedRouteRemovesPreviousIdentityAndPreservesRouteOwnership() {
        let previous = ProxyServerSettings(host: "127.0.0.1", port: 1443, connection: .mtp(secret: Data([0xdd]) + Data(repeating: 1, count: 16)))
        let rotated = ProxyServerSettings(host: "127.0.0.1", port: 1443, connection: .mtp(secret: Data([0xdd]) + Data(repeating: 2, count: 16)))
        let record = TgwsManagedRoute(previous: .defaultSettings, server: previous)
        var current = record.install(into: .defaultSettings)
        let replacement = TgwsManagedRoute(previous: record.restore(from: current), server: rotated)
        current = replacement.install(into: record.restore(from: current))
        XCTAssertFalse(current.servers.contains(previous))
        XCTAssertTrue(current.servers.contains(rotated))
        XCTAssertTrue(current.enabled)
        XCTAssertEqual(current.activeServer, rotated)
    }
}
