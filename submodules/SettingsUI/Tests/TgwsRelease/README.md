# Tgwsproxy Settings UI verification

User-facing names: **Tgwsproxy**, **Tgwsproxy Settings**, **Automatic release
checks**, and **Open official GitHub releases**. Release checks are metadata
checks, not engine updates. The native iOS subset does not provide desktop
engine/settings parity.

The managed route's no-silent-direct-fallback guarantee applies only to MTProto
account traffic while that route remains selected. Calls may connect directly;
the previous SOCKS call route is not preserved while enabled. URLSession
requests and app extensions are outside this protection. The detail screen and
proxy list disclose this boundary. Recovery notices are mapped to fixed text;
raw stored notices, errors and authentication secrets must never be displayed.

Offline metadata/cache tests (from repository root):

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors \
  "submodules/SettingsUI/Sources/Data and Storage/TgwsProxyReleaseChecker.swift" \
  submodules/SettingsUI/Tests/TgwsRelease/main.swift \
  -o /var/folders/sf/41t_mpf92kxckyxgs9xcwk6w0000gn/T/opencode/tgws-release-tests
/var/folders/sf/41t_mpf92kxckyxgs9xcwk6w0000gn/T/opencode/tgws-release-tests
```

Device/simulator checks still needed: number-pad and hardware-keyboard port
submission, invalid port feedback, repaired settings notice, arbitrary notice
sanitization, foreground suspension, explicit disable restoration, managed
entry visibility with native readiness, read-only row tap/info navigation,
share/edit/delete/reveal exclusion, VoiceOver, Dynamic Type and narrow/iPad layouts.
No live Telegram account or production network is required for UI inspection.

## Simulator build evidence (2026-10-06)

The direct library target needs both the Apple simulator platform and legacy CPU
selection (third-party genrules use the latter):

```sh
build-input/bazel-8.4.2-darwin-arm64 build //submodules/SettingsUI:SettingsUI \
  --platforms=@build_bazel_apple_support//platforms:ios_sim_arm64 \
  --cpu=ios_sim_arm64 --apple_platform_type=ios --ios_multi_cpus=sim_arm64 \
  --ios_minimum_os=14.0 -c opt \
  --nofetch --repository_disable_download --lockfile_mode=off
```

This command was resumed after two 600-second time limits while dependencies
compiled. The final invocation failed after 295.811 seconds in the unchanged
`LegacyMediaPickerUI/Sources/LegacyICloudFilePicker.swift`: lines 57 and 85 use
`UIDocumentPickerMode` and `init(documentTypes:in:)`, deprecated in iOS 14.0;
that dependency treats warnings as errors. SettingsUI compilation was not
reached, so this is not evidence of a successful SettingsUI typecheck or full
application build. The earlier platform-only attempt timed out after 120 seconds
and selected macOS for legacy third-party genrules; do not use it as proof of a
complete simulator configuration.

Source parsing passed using:

```sh
xcrun swiftc -frontend -parse \
  "submodules/SettingsUI/Sources/Data and Storage/ProxyListSettingsController.swift" \
  "submodules/SettingsUI/Sources/Data and Storage/TgwsProxySettingsController.swift" \
  "submodules/SettingsUI/Sources/Data and Storage/TgwsProxyReleaseChecker.swift"
```

The offline test command above passed with warnings treated as errors, printing
`Tgws release metadata/cache tests passed (offline)`. No signing credentials,
live Telegram traffic or git mutations were used for this verification.

## Visible managed row follow-up

The coordinator-added localhost entry is visible exactly once in Saved Proxies
(existing server deduplication is retained). It displays native listener status,
not a connectivity-probe result. Both row and info taps open Tgwsproxy Settings;
edit, delete, reorder and swipe-reveal controls are disabled. It remains excluded
from sharing and availability probes. Only host/port and a fixed runtime label
are rendered; the authentication secret is never displayed.

A warnings-as-errors override was accepted with this exact command:

```sh
build-input/bazel-8.4.2-darwin-arm64 build //submodules/SettingsUI:SettingsUI \
  --platforms=@build_bazel_apple_support//platforms:ios_sim_arm64 \
  --cpu=ios_sim_arm64 --apple_platform_type=ios --ios_multi_cpus=sim_arm64 \
  --ios_minimum_os=14.0 -c opt \
  --@build_bazel_rules_swift//swift:copt=-no-warnings-as-errors \
  --nofetch --repository_disable_download --lockfile_mode=off
```

It caused Swift dependency recompilation and timed out at 899.154 seconds after
reaching 517/561 actions, while compiling TelegramCallsUI/TelegramUI dependencies
before SettingsUI. No completed target or full-app build is claimed.
`--swiftcopt` is not accepted by this Bazel version; the rules Swift build setting
is `copt` (singular) under the repository's `@build_bazel_rules_swift` alias.
Resume the exact command to reuse its cache.
