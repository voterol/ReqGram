# Tgws integration contract

`SGSimpleSettings` exports `TgwsProxySettings.shared`. No UI/coordinator import
is required to use the model.

* `enabled`: persistent default **true**. Prefer throwing `update(enabled:)`
  for UI error feedback rather than the convenience setter.
* `port`: persistent default **1443**. `update(port:)` rejects values outside
  1024...65535. The port is not automatically changed on bind failure.
* `configuration()` repairs invalid storage to default-enabled port 1443 and
  a fresh secret. `recoveryNotice` durably exposes `invalid_settings_repaired`
  for explanatory UI independently of listener state. Secure random failure
  still throws.
  Secret creation uses Security's `SecRandomCopyBytes`, persists once and is
  never echoed in runtime state. Secret editing/rotation is not supported.
* `didChange`: NotificationCenter notification after a model edit.
* `state` / `stateDidChange`: main-thread runtime observation. States are
  disabled, starting, ready, suspended and failed(fixedCode). Ready means
  listener bound, **not** upstream connectivity verified.
* `isManagedProxy(host:port:secret:)`: exact identity check for hiding the
  generated proxy from sharing. Pass the decoded 17-byte MTProto secret.
* Edits and state observation belong on main. Persisted configuration reads
  and initial identity generation are protected by a recursive lock.
* `snapshot()` / `withCurrentSnapshot(_:mutation:)` provide a revision/config
  fence. Model edits and the complete database mutation are mutually exclusive;
  notifications are emitted only after releasing the model lock.

The native engine supports only port/secret and foreground operation.
`supportedEditableFields` and `unsupportedDesktopFeatures` explicitly expose
the limited capabilities. Do not offer fake upstream, DNS, background daemon,
executable path, Python flags, FakeTLS, fronting or hot-update settings.
Version checks must use the trusted GitHub project/release checks; engine
updates require a replacement signed/re-signed IPA. This model does not add
a downloader, arbitrary execution or a GitHub checker.

## Routing

AppDelegate gates initial presentation/context creation on
`TgwsProxyCoordinator.shared.prepare(accountManager:)`. A private namespaced
account-manager shared-data record snapshots the old route and owned identity
atomically with installing 127.0.0.1 / validated port / `dd` + 16-byte secret.
This precedes account network construction and does not wait for readiness.
Reopening the app reuses the record; it does not duplicate managed entries or
replace the previous-route snapshot with the loopback route.

Model and foreground notifications drive a process singleton. Stop barriers
and generation fencing prevent overlapping listeners/stale ready callbacks.
The transaction fence holds its version lock through the model snapshot check
and both ownership/route writes inside AccountManager. Superseded cold-start
transactions retry before allowing account-context creation. Revisions reject
ABA edits as well as simple stale disables.
Errors and background transitions do not restore a direct/prior route.
Explicit disable stops workers before conditional restoration. Restoration
preserves concurrent list edits and only changes the routing tuple while it
still equals the owned tuple. An external explicit route edit wins; there is
no continuous enforcement that would fight the proxy editor.
If the saved active proxy was removed from the current server list, explicit
disable restores direct (disabled, no active server, no proxy-for-calls), rather
than resurrecting that deleted proxy. No saved server is reinserted.

Corrupt settings are repaired before the initial route transaction: UI is not
blocked on a never-ending signal. Even secure random failure installs/reuses a
blocking loopback route before releasing app startup, reports
`secure_random_unavailable`, and never starts a service with the placeholder
identity. Without an owned identity the blocking endpoint is 127.0.0.1:0,
which cannot be a listening service. A later successful configuration read can
replace it atomically. Explicit disable of corrupt storage repairs first and
then persists the user's disable intent.

## Calls boundary (not a VPN)

Fail-closed routing here is **MTProto-only**, not all traffic. The shared proxy
model has one active server and one `useForCalls` flag, not a separate call proxy.
Installing the managed MTProto route sets `useForCalls = false`; this does NOT
preserve the previous SOCKS call route while Tgws is enabled and does NOT stop
direct call/media traffic. The saved call flag is restored on explicit disable
only if the saved proxy is still present and no concurrent route edit won.
No call-layer change or all-traffic privacy guarantee is implemented.

## Offline verification

Compile `Sources/TgwsProxySettings.swift` with `Tests/Tgws/main.swift` using
`xcrun swiftc -warnings-as-errors`, then run the resulting binary. It uses an
isolated temporary UserDefaults suite and no network.

Route tests are included in `//Swiftgram/SGSettingsUI:SGSettingsUIMTProtoTests`.
They cover restoration to proxy/direct, duplicate installation, record coding,
concurrent route edits, deleted prior proxies, preserving concurrent list additions,
queued disable/re-enable and ABA ordering, plus lock-held transaction/version
serialization using the same fence as the coordinator. Simulator test
execution does not create Telegram accounts or start the native service.
Device sideload lifecycle and production connectivity remain unverified.
