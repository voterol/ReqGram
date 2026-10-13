# .ixplugin format and installation foundation

> The current runtime/API reference is
> [`../ReqGramPythonRuntime/ReqGramPluginAPI.md`](../ReqGramPythonRuntime/ReqGramPluginAPI.md).
> The detailed main-client integration and diagnostics reference is
> [`../ReqGramPythonRuntime/MAIN_CLIENT_INTEGRATION.md`](../ReqGramPythonRuntime/MAIN_CLIENT_INTEGRATION.md).

## Current status

The `.ixplugin` format is implemented for the main-client path: a package is a
strict ZIP containing `manifest.json`, `main.py`, and optional `.py`/`.json`
assets. Installed packages can run through embedded CPython when the runtime
is present. Installation is not a trust decision: local imports remain
untrusted, `trusted` is always false, and CPython is **not a sandbox**. The
current host operations, permissions, limits, lifecycle and unsupported surface
are defined in the current API reference above, not by the historical notes
below.

This document's original foundation slice restored the inspected backup's
manifest/archive-inspector foundation, not its unsafe trust switch. The current
main-client execution path is documented in the current references above.

## Historical foundation (all remaining sections)

Everything below records the pre-runtime implementation, not current behavior.
In particular, claims about no execution/enable UI, deferred settings, manifest-
only extraction, future runtime work and missing Python dependencies are stale.
The handoff list is historical, not a promise of future APIs or distribution.

The optional `capabilities` array currently accepts `message.events`,
`message.send`, `message.edit`, `message.delete`, and `message.forward`.
Capabilities are independent grants: `message.send` enables only the bounded
plain-text local-queue mutation documented in `ReqGramPluginAPI.md`; it does not
grant edit, delete, forward, media, scheduling, send-as, effects, or raw Telegram
API access.

## User flow

ReqGram Settings → Installed plugins → turn off Trusted installs only → Import
.ixplugin file → review untrusted-code warning for at least ten monotonic seconds
→ install the exact inspected snapshot → refreshed installed list. Local files
are always untrusted. Trusted-only defaults on and is rechecked at commit. There
is no authenticated trusted installer yet. Crash safe mode is a distinct persisted
startup policy, not a trust flag. No enable UI is exposed without a real runtime.

The management screen supports metadata, logs, removal with explicit keep/delete
data choice, and log retention (default seven days, UI choices 1/7/30/90 days).
Retention is enforced when logs are read or state is changed. Full plugin settings
are not fabricated: an optional `settings` declaration is retained; rendering is
deferred until the runtime/schema contract is agreed. Management copy is currently
English; the entry row is localized in English/Russian.

## Package boundary

ZIP with root `manifest.json` and `main.py`. Required JSON fields:

```json
{"id":"demo","name":"Demo","version":"1","description":"Example",
 "author":"Unverified author","entry":"main.py","api_version":"1","permissions":[]}
```

Optional `settings` is a string-to-string dictionary, not a final UI schema.
Other API versions/entrypoints are rejected. No archive extraction occurs beyond
the manifest read. Duplicate, absolute, traversal and backslash entry paths are
rejected; this strict initial format rejects directory entries too. Limits: 8 MiB
compressed package, 512 entries, 8 MiB per declared uncompressed entry, 32 MiB
declared total, 256 KiB manifest, 64 MiB total installed compressed archives.
ZIP central-directory size claims are checked by the UI adapter; the runtime must
independently validate actual extracted sizes, symlink attributes, UTF-8 Python
source and permissions before execution. This installer is not a Python sandbox.

## Storage and transaction

`Application Support/ReqGramPlugins/state.json` atomically publishes one Codable
state containing records, archive bytes, opaque retained data, policies and dated
logs. It replaces the backup's split filesystem/UserDefaults transaction. A write
failure before publication leaves the old complete state; tests inject that failure.
All manager instances serialize through one queue. Root and state-file symlinks
are rejected. Platform parent aliases are resolved separately from the owned leaf;
Darwin's fixed `/var -> private/var` alias is allowed. Assumes an app-private root,
not adversarial concurrent filesystem writers. Atomic rename does not promise
power-loss fsync durability. State-file rewrites/base64 archives are a deliberately
bounded foundation, not a scalable runtime database. No legacy WIP migration is
implemented; backup UserDefaults/packages are not silently treated as new installs.

Notifications are delivered on the main queue after successful writes. UI observes
them and fetches current records, rather than retaining stale detail snapshots.
Read errors are shown and do not silently overwrite corrupt storage.

## Historical runtime handoff notes (stale; do not use as the current contract)

The original foundation slice recorded the following as future work. The main
client now has the adapter and embedded runtime described in the current
references; this list is retained only as historical context:

1. Validated archive/data access, declared capability enforcement and real Python.
2. Startup check for persisted crash safe mode; explicit manual restart after exit.
3. Load/enable/disable/cancel results, crash markers/quarantine and structured logs.
4. Runtime shutdown before replacement/removal, plus transactional data writes.
5. Declarative settings schema/versioning, only rendering settings when declared.
6. Authenticated distribution/signature verification before any trusted install path.

The current manager still keeps `trusted` false and does not persist execution
intent. `enabled` is a session-derived running status, not an installer trust
flag. Do not add a caller-controlled trust setter.

## Historical verification notes (stale)

Compile the manager and `Tests/Plugins/main.swift` together using `swiftc
-warnings-as-errors`; run the output. Also compile for the iOS simulator SDK and
run with `xcrun simctl spawn booted <binary>`. Fixtures use a unique temporary
directory and defer cleanup, never `/tmp/demo.ixplugin` or standard UserDefaults.
Tests cover countdown, policy recheck, snapshot identity, failed atomic publication,
retention/reopen, keep/delete data, malformed paths, duplicate ZIP names, corrupt
storage and pre-existing root symlinks. Swift parse checks syntax of the controller,
not module linkage or UIKit interactions. Full app build and Files/warning/removal
UI tests remain required; old backup IPA is not evidence for this implementation.

Build dependencies: SGSimpleSettings already globs Sources; no new dependency.
SGSettingsUI adds only `//third-party/ZipArchive:ZipArchive`. No Python dependency
or runtime shim is added by this slice.
# Tap-only selected-message permission

`messages.context` is opt-in and displayed in the existing manifest permission
review. It permits session-owned native context-menu actions, not history access,
listening, sending, editing or networking. A snapshot is delivered only after a
user taps the branded action on one eligible cloud text message. See
`../ReqGramPythonRuntime/ReqGramPluginAPI.md` for the bounded wire contract and
conservative content exclusions. Registrations are never stored in plugin data.
