# Bundled native Tgwsproxy runtime

## Choice and provenance

This is a native port of the smallest production subset of Flowseal
`tg-ws-proxy`, pinned to **3c54c54d36ae59e5e09885fad3ddf6aa60f9cdea**.
It is not a Python launcher or a readiness placeholder. The translated logic
comes from `proxy/tg_ws_proxy.py` (`_try_handshake`, `_generate_relay_init`,
`_build_crypto_ctx`), `proxy/bridge.py` (stream re-encryption and `MsgSplitter`),
and `proxy/utils.py` (protocol constants and WS domain selection). The MIT
notice is bundled in `Resources/FLOWSEAL-LICENSE.txt`.

Evidence against the embedded Python path: `third-party/PythonRuntime/prepare.py`
includes only `.py` in the stored stdlib ZIP and excludes `lib-dynload`.
`third-party/PythonRuntime/BUILD` imports Python.framework, not extension
frameworks. `RGPythonRuntime.m` sets isolated module search paths to that ZIP
and the resource directory. Upstream imports asyncio, socket, ssl, struct,
certifi and its AES module plus additional CF/H2 dependencies. Shipping those
extension frameworks and cryptography would be a separate packaging project.
The native subset instead uses CommonCrypto, Security and Foundation already
available on iOS; no Python runtime API or behavior was changed.

## Implemented boundaries

* Listener binds only IPv4 `127.0.0.1`, configured unprivileged port.
* Exactly 16 clients maximum, each with independent streaming AES-256 CTR
  contexts. Dedicated concurrent worker queue; no RGPythonRuntime queue work.
* Secret-authenticated 64-byte obfuscated MTProto init; abridged, intermediate,
  padded intermediate; production DCs 1–5 and 203; media sign preserved.
* Relay init and both-direction re-encryption preserve upstream CTR offsets.
* Whole transport packets are sent as binary WebSocket messages. Invalid,
  empty or >4 MiB lengths fail closed, including incomplete buffered packets.
* Only canonical `wss://kws<dc>[media -1].web.telegram.org/apiws`, binary
  subprotocol. DC203 selects kws2, as upstream. Media routes try `kws<dc>-1`
   first and then `kws<dc>` on connect/TLS/upgrade failure; other routes have
   only their canonical host. URLSession hostname attempts always run first.
   The delegate waits for successful binary-subprotocol upgrade before sending
   relay init, so a post-open send failure never replays on another route.
   Only pre-open transport/upgrade failures enable the native DC-IP fallback.
   `RGTgwsIPTransport` uses Network.framework `nw_connection_t` (Objective-C's
   NWConnection API), fixed literal production seeds copied from repository
   `TelegramCore/Sources/Network/Network.swift`, port 443, and TCP+TLS only.
   DC203 maps to DC2. Both media aliases use the same DC seed list but retain
   their own canonical `kwsN-1` / `kwsN` identity, in that order.
   TLS server name and HTTP Host come from the same immutable canonical host.
   Default system certificate-chain and hostname validation is retained; there
   is no verify override, trust-all, configurable address, redirect, fronting,
   test DC, plaintext or direct MTProto fallback.
   Manual HTTP/1.1 upgrade requires status 101, Upgrade/Connection tokens,
   exact SHA-1 accept and binary subprotocol, no extensions or duplicate headers.
   Headers are bounded to 16 KiB. RFC6455 output is randomly masked; input must
   be unmasked binary/continuation or bounded control frames. RSV, text, illegal
   opcodes/lengths/fragment ordering fail closed. Binary messages are bounded to
   4 MiB+4 and 1024 fragments, control frames to 125 bytes and 1024 per receive.
   Ping is answered with masked pong. Close terminates without reconnect.
* Foundation verifies the RFC6455 accept and system certificate/hostname trust.
  A local mock test demonstrates valid accept succeeds and wrong accept fails.
  Native diagnostics are allowlisted at the Objective-C event boundary:
  `upstream_attempt` reports only `hostname` or `ip`, and
  `upstream_connect_failed` reports only bounded failure categories. No native
  error, URL, peer, or secret is forwarded.
* Listener/client descriptors remain worker-owned. Stop marks cancellation,
   shuts down sockets, cancels URLSession tasks and NW connections, drains the
   native receive worker, waits for all client workers, and only
  then emits stopped and completes. Poll/WS waits observe cancellation.
* Handshake timeout 10s, WS send/local write timeout 15s, idle cutoff 300s;
   close on upstream failure, never reroute directly. Each native connect and
   upgrade has a 15s deadline; there is no pooling or post-upgrade retry.
* No config/secret/remote exception logging. Input JSON is bounded to 4 KiB,
  unknown fields and boolean/fractional/out-of-range ports are rejected.
* iOS start requires main-thread foreground-active state (other threads are
  marshalled to main). Resign-active/background notifications stop the service.
  Coordinator must explicitly restart when active again.
  A lock-protected foreground epoch is invalidated synchronously in notification
  handlers and explicit stop, before control-queue teardown. Starts capture that
  epoch (including off-main submissions), revalidate it on control entry and
  under the lifecycle lock around bind/publication/worker registration. Rapid
  reactivation cannot revive a cancelled pending start. Published runs are
  marked stopping and sockets shut down before the suspension handler returns;
  stale main-queue readiness callbacks are suppressed. UIKit state is read only
  on main for initial state; subsequent lifecycle state comes from notifications.

Engine updates ship only in signed replacement IPAs. A separately owned GitHub
version check may notify the user; this runtime never downloads/executes code.

## Coordinator contract

Import `ReqGramPythonRuntime`; the public Objective-C header is
`Sources/RGTgwsService.h`:

```objc
[[RGTgwsService shared] startWithConfigJSON:jsonData event:^(NSDictionary *event) {
    // Main queue: state ready/error/stopped; ready has host and port.
}];
[[RGTgwsService shared] stopWithCompletion:^{ /* all socket workers exited */ }];
```

Swift importer: `RGTgwsService.shared().start(withConfigJSON:event:)` and
`stop(completion:)`. JSON contains only `port` (1024…65535 integer) and `secret`
(32 hexadecimal digits, raw 16-byte secret, no `dd` prefix). Ready contains
`state`, `host: "127.0.0.1"`, `port`. Error contains `state` and fixed `code`:
`invalid_config`, `already_running`, `not_foreground`, `start_cancelled`, or
`listener_failed`. `start_cancelled` means suspension/stop invalidated the
submitted foreground generation before publication (no stopped event is needed
for a start that never published).
Stopped contains only `state`. No secret is echoed. Ready means listener bound,
not successful Telegram/upstream reachability. Client-level upstream failures
close the local connection without changing listener readiness.

The coordinator owns default-on state, persistence, route snapshot/restore,
account coverage, foreground restart, and generation fencing of stale events.
Configure MTProxySettings with localhost/port and the **17-byte decoded hex
`dd` + secret** for padded-intermediate transport. Establish fail-closed routing
before allowing account traffic: do not wait for ready with a direct route
enabled. On startup error, listener failure or foreground suspension retain
the selected localhost route, disable automatic direct fallback, and show
unavailability. Only explicit disable restores the previous route, after the
stop completion barrier. Never interpret stopped/error as permission to go
direct. This runtime intentionally does not mutate SGSimpleSettings,
AppDelegate, or proxy UI. The separately implemented `TgwsProxyCoordinator`
integrates this contract before account-context creation. The guarantee covers
managed MTProto account routing only, not calls, URLSession or extensions.

## Offline verification

Compile/run `Tests/tgws_native.m` with Crypto, Service and IPTransport sources,
`-fobjc-arc -fmodules -Wall -Wextra -Werror`, Foundation and Security, and the
Sources include path, linking Network as well. Tests cover NIST AES-256 CTR/non-block updates, all three
protocol tags, media DC extraction, wrong secret, relay init, both directions,
partial packet splitting, malformed lengths, invalid JSON, duplicate start,
three start/stop cycles with partial-handshake clients, and local-only WS accept
verification. No valid service handshake is transmitted, hence no Telegram
network request occurs in tests.

Compile the same harness with `-DRG_TGWS_TESTING=1` for deterministic lifecycle
regression tests. Test-only control/prepublication stalls are compiled out of
the shipped service. Semaphore barriers exercise suspension while a start is
queued, suspension after initial control validation but before bind/publication,
explicit stop of a queued start, rapid inactive/active transitions, inactive
start rejection, and suspension after publication but before ready delivery.
Assertions require cancellation/no stale ready, stop completion, released ports,
and successful subsequent fresh start/stop cycles. These tests do not rely on
timing sleeps. Fresh ephemeral ports avoid unrelated client TIME_WAIT reuse.

The WebSocket mock exercises **Foundation itself**: a real local TCP server
reads the key generated by `NSURLSessionWebSocketTask`, sends an HTTP 101 with
either the computed or deliberately incorrect accept plus a binary frame, and
the test asserts the Foundation receive callback's success/error. There is no
client-side handshake-validation helper being tested instead. This is local
plain WS handshake evidence, not a production WSS/TLS connectivity test.

Both implementations also pass iPhoneOS arm64/iOS14 SDK syntax compilation.
The linked simulator smoke IPA builds successfully with:

```
bazel build //Swiftgram/ReqGramPythonRuntime:ReqGramPythonSmoke \
  --ios_multi_cpus=sim_arm64 --nofetch --repository_disable_download --lockfile_mode=off
```

The device smoke target is blocked at analysis by its existing missing
`provisioning_profile` attribute. No signing credentials were inspected or used.
Building the objc library without an iOS transition selects macOS and correctly
fails because the existing Python XCFramework only supports iOS; use the iOS
application target rather than treating that as a native port compilation error.
Additional offline harness `Tests/tgws_ip.m` links IPTransport, Foundation,
Security and Network with the same warning/ARC flags. It covers all fixed DC
seeds, DC203/media aliases, canonical Host requests, invalid endpoint/key
rejection, RFC6455 accept/status/header rejection, client masking and extended
length boundaries, fragmented binary input with ping/pong, and malformed frames.
No public endpoint or trust override exists in the test transport; receive/write
are replaced by local byte fixtures. This is not live TLS evidence.
`Tests/test_tgws_ip_invariants.py` additionally checks the seed map against
Network.swift and source wiring for shared SNI/Host identity, default validation,
hostname-first/pre-open-only fallback, and cancellation draining.

Reproduce from the repository root (set `OUT` to an existing temporary directory):

```sh
xcrun clang -fobjc-arc -fmodules -Wall -Wextra -Werror \
  -framework Foundation -framework Security -framework Network \
  -I Swiftgram/ReqGramPythonRuntime/Sources \
  Swiftgram/ReqGramPythonRuntime/Tests/tgws_ip.m \
  Swiftgram/ReqGramPythonRuntime/Sources/RGTgwsIPTransport.m -o "$OUT/tgws-ip"
"$OUT/tgws-ip"
python3 -m unittest discover -s Swiftgram/ReqGramPythonRuntime/Tests \
  -p test_tgws_ip_invariants.py
```

Verification for this implementation: both native offline harnesses pass with
`-Wall -Wextra -Werror` (lifecycle harness with `RG_TGWS_TESTING=1`); all three
source-invariant tests pass; iPhoneOS arm64/iOS14 syntax compilation passes.
Simulator smoke and full `//Telegram:Swiftgram` IPA builds pass. Full build uses
`--ios_multi_cpus=sim_arm64 --//Telegram:disableExtensions
--//Telegram:disableProvisioningProfiles --define=buildNumber=1
--features=apple.skip_codesign_simulator_bundles -c dbg` and both builds use
`--nofetch --repository_disable_download --lockfile_mode=off`.
Remaining verification: actual iOS sideload lifecycle, production TLS/connectivity
and full coordinator routing. Those are not claimed by offline tests. Blocking
all allowlisted TLS routes remains fail closed rather than using direct MTProto.
