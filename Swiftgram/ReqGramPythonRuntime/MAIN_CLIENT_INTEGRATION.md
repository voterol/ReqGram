# Main-client plugin integration

The earlier SGSimpleSettings foundation document describes the pre-runtime slice.
The main client now connects Installed plugins → immutable archive snapshot →
strict ZIP reader → fresh private extraction directory → ReqGramEmbeddedExecutor
→ embedded CPython → plugin-bound host callbacks → atomic manager state → UI.

`on_enable()` and `on_disable()` are required synchronous hooks in `main.py`.
`host_request('log', bytes)`, `host_request('load')` and
`host_request('save', bytes)` and `host_request('settings')` are part of the
implemented API. Log/storage declarations gate these callbacks. Storage is
opaque bytes (64 KiB); logs are UTF-8 (4 KiB). ReqGram also implements the
bounded local read, explicit-message event, text mutation, selected-message,
network, and UI contracts in `ReqGramPluginAPI.md`. There is no general Telegram
or MTProto facade and no arbitrary native UI API.
This is not a full ixplugin compatibility implementation.

## Account-free host APIs

## Read-only account metadata

`accounts.list` and `account.context` require `accounts.read`, take no payload,
and return JSON bytes. The list is `{"accounts":[{"handle":"account_<local record id>",
"is_primary":true}],"consistency":"session_snapshot"}`. Context is
`{"current_account":"account_<local record id>","consistency":"session_snapshot"}`;
current_account is null if the originating context is absent from the snapshot.
Handles are local account-manager identifiers, not Telegram user IDs or credentials.
With the additional `accounts.profile` permission each user row includes `profile`
with first_name, last_name, username (missing strings are empty). No phone numbers,
tokens, session keys, message history or account mutation operations are exposed.
The separate `messages.context` permission allows only a bounded text/ID snapshot
after a user taps a plugin-branded action on one eligible message; see
`ReqGramPluginAPI.md` for exclusions and account/session invalidation.

The settings controller supplies its actual AccountContext; the provider takes one
sharedContext.activeAccountsWithInfo emission on main before Python starts. Values
remain fixed for that module lifetime; stop/re-enable refreshes them. No synchronous
main wait occurs under the GIL. Missing provider or a five-second snapshot timeout
returns account_context_unavailable. Permission is checked before snapshot acquisition
and on every call; safe mode/stopping deny calls. These are host capability gates,
not a sandbox against arbitrary in-process Python. Diagnostic runs exclusively use
the fake provider and assert exact fixture schemas without logging account metadata.

## Account-free host API details

All calls remain plugin-bound `host_request(operation, optional_bytes)`. Structured
payloads/results are UTF-8 JSON bytes, not Python dictionaries. New operations:

* `app.info` (no payload): `platform`, `client`, `bundle_id`, `version`, `build`,
  `os_version`, `api_version`. No account identifiers or device identifiers.
* `events.subscribe` / `events.unsubscribe`: JSON array containing only
  `app.active`, `app.inactive`, `ui.action`, `network.response`, `message.action`,
  `message.change`, or `message.mutation`.
  Idempotent, at most three entries per call, counting duplicates; empty arrays
  are accepted. All seven types can be subscribed/unsubscribed in separate calls.
  Message event types require their matching permission or capability for either
  operation; see `ReqGramPluginAPI.md` for the exact authorization mapping.
* `events.poll` (no payload): drains this module's event queue as a JSON array.
  Maximum 64 events; overflow drops the oldest. App events have an `event` field.
* `ui.alert`: requires manifest permission `ui.alert` and a `ui.action`
  subscription. Payload exactly `{"title":"...","message":"..."}`; nonempty
  title <=128 UTF-8 bytes, message <=2048 bytes. Returns `{"request_id":"UUID"}`.
  This means **queued**, not displayed. UIKit presentation is asynchronous on main,
  never a synchronous main-queue wait under the GIL. The alert is visibly prefixed
  `Plugin:` and has fixed OK/Cancel buttons. Completion is queued as
  `{"event":"ui.action","request_id":"UUID","action":"ok|cancel|unavailable"}`.
  Inactive app, missing presenter or an existing alert produces `unavailable`.
  One pending alert per module; requests are limited to one per five seconds.

Subscriptions, queue and alert are session-only, never persisted. Stop closes them
before `on_disable`; failed start/stop closes them too. Old host callbacks cannot
use a new module's session. Safe mode rejects new host calls. No Python callbacks
run on UIKit's thread. Polling remains the default. Explicit `events.callback`
opts into serial, bounded `on_event(dict)` delivery after enable succeeds;
`events.status` reports delivery counters/failure. See
[the exact callback contract](ReqGramPluginAPI.md#optional-automatic-callbacks).
Do not block `on_enable` waiting for UI; it must
return. Python-created threads remain cooperative and are not terminated by host.
The example only shows an alert; it does not start a polling thread.

Host-reported failures raise `RuntimeError` with a JSON string containing
`operation` and `error`. New stable codes: `invalid_payload`, `permission_denied`,
`session_inactive`, `subscription_required`, `ui_busy`, `rate_limited`,
`unsupported_operation`. Existing storage/settings/log failures still use their
legacy localized description in `error`. Argument type and >64-KiB payload checks
happen earlier in C and retain `TypeError`/`ValueError`, not this envelope.
Uncaught exceptions become the individual plugin's failed status/quarantine reason
and persisted lifecycle log; caught errors do not stop the plugin.

Generate `Examples/create_alert_plugin.py OUTPUT.ixplugin` using desktop Python.
The debug main-client diagnostic tests host metadata, denied UI permission,
subscriptions and a real visible alert. An isolated notification center tests queue
bounds, draining, isolation, unsubscribe and close without simulating lifecycle
notifications on the rest of the app. Button-tap delivery needs additional UI
automation; the diagnostic currently verifies stop dismissing the visible alert.

No trusted-source backend was added: no current plugin endpoint contract was found
in the local server Python code. No endpoint, authentication scheme or trust proof
is invented. Local imports remain untrusted. CPython remains **not a sandbox**.

## Declarative settings (schema version 1)

Legacy `settings` string metadata remains readable but is not rendered. Optional
`settings_schema` declares editable fields independently:

```json
{"settings_schema":{"version":1,"fields":[
  {"key":"enabled","label":"Enabled","type":"boolean","default_value":true},
  {"key":"greeting","label":"Greeting","type":"string","default_value":"Hello"},
  {"key":"style","label":"Style","type":"selection","default_value":"quiet","options":["quiet","verbose"]}
]}}
```

Up to 32 fields are supported. Keys are unique and match
`[A-Za-z][A-Za-z0-9_]{0,63}`; labels are nonempty and at most 128 characters.
Strings are limited to 1024 UTF-8 bytes. Selections require 1–32 unique nonempty
options (each at most 128 UTF-8 bytes) and a default from those options.
Boolean defaults must be JSON booleans. Options are forbidden on other types.
Invalid schemas reject package validation; absent schemas keep existing plugins
compatible and show no settings action.

Installed plugins → plugin details → **Plugin settings** → choose a field → save.
Boolean and selection fields offer declared choices; strings use a text field.
The manager validates edits and atomically persists them, separately from plugin
opaque storage. Reopening shows valid stored values over schema defaults.
Removing with data retained preserves settings; deleting plugin data removes them.
Invalid stored values after schema changes fall back to defaults.

Python reads its own settings as UTF-8 JSON bytes:

```python
import json
settings = json.loads(host_request('settings'))
```

This read-only callback requires a declared schema, takes no payload, and uses the
existing plugin-bound host bridge; it needs no extra permission declaration.
There is no automatic change notification or Python settings-write callback.
Stop and enable the plugin again to rerun `on_enable()` with edited values.
There are no settings import/export controls.

Generate a self-authored example using desktop Python 3:

```sh
python3 Swiftgram/ReqGramPythonRuntime/Examples/create_settings_plugin.py /tmp/settings-example.ixplugin
```

Import the generated file through the normal review flow, edit its three fields,
then enable and inspect logs. It uses only the implemented settings/log callbacks.
The diagnostic additionally checks exact typed callback values, persisted native
edits and defaults. Repeated process launches alternate `edited-A`/`edited-B`;
the pre-edit log must match the preceding process's saved greeting.

CPython is NOT a sandbox. Python code shares the app process and can access its
resources. Disable is cooperative, cannot terminate Python-created threads, and
does not undo side effects. Safe mode blocks new starts. Plugins do not restart
automatically. Interrupted lifecycle markers cause recovery safe mode. Only run
reviewed code; local packages are never authenticated/trusted.

The ZIP adapter rejects raw traversal/absolute/backslash/colon/NUL paths,
non-UTF-8 names, links and nonregular Unix types, encrypted entries, duplicate
case-folded names, directory entries, and files other than `.py`/`.json`. It checks
actual inflated lengths and CRC, with 512-entry, 8 MiB/file and 32 MiB/ZIP limits.
It does not use the general-purpose path-sanitizing extraction API. The manager
retains the 8 MiB archive / 64 MiB installation limits and ten-second monotonic
approval gate. Extraction is not protection against already-running hostile code.

## Reproduction

Optional per-plugin settings export/import is documented in [SETTINGS_TRANSFER.md](SETTINGS_TRANSFER.md).

From repository root:

```sh
./build-input/bazel-8.4.2-darwin-arm64 build //Telegram:Swiftgram \
  --ios_multi_cpus=sim_arm64 --//Telegram:disableExtensions \
  --//Telegram:disableProvisioningProfiles --define=buildNumber=1 \
  --features=apple.skip_codesign_simulator_bundles -c dbg
```

Extract the **IPA**, not a potentially stale `Swiftgram_archive-root` directory,
using `ditto -x -k`. Install its Payload/Swiftgram.app using `simctl install`
(no uninstall or data reset). Launch `ph.telegra.Telegraph` with
`--reqgram-plugin-diagnostic`. This debug-only hook runs in the actual main app,
uses a separate `Application Support/ReqGramPluginDiagnostic` fixture store,
waits the real approval delay, and does not use account context or bypass login.
Filter simulator unified logs for `ReqGramEmbeddedDiagnostic` and
`ReqGramPlugin local.reqgram.fixture`. Four fixtures check Python 3.13.15,
load/save/log, cooperative stop, persisted logs, early approval rejection,
intentional Python exceptions and oversized storage errors. Repeated runs retain
fixture storage and increment counts. The normal user plugin store is untouched.

Simulator delta-install caveat: with skipped bundle signing, the simulator retained
older embedded frameworks during this work. Re-ad-hoc-sign the extracted
TelegramUIFramework.framework and TelegramCoreFramework.framework, then the app
(`codesign --force --sign - PATH`) before installing. This updates simulator
signature metadata without deleting app data; do not sign source-tree credentials
or change device provisioning. Verify the diagnostic reports the new host checks.

Resource lookup must use the runtime's owning bundle: in the main app Python
resources reside in TelegramUIFramework.framework, unlike the old smoke target.
No separate app is needed for this diagnostic.

## Integration audit regressions

The archive inspector now offers a single `contents(in:)` snapshot operation.
Prepare parses once; enable parses once and validates/extracts that same immutable
dictionary. No URL-keyed cache survives a call, so replacing a file at the same
path cannot return stale content. Legacy inspector methods remain for compatibility.

Review starts after warning presentation. Resigning active disables the action
and blocks the manager ticket indefinitely; returning active with the warning
visible resets the manager-enforced monotonic gate to a fresh ten seconds. This
intentionally resets rather than accumulates partial foreground review. The timer
continues after eligibility so a later interruption also revokes approval.

Runtime module residency is decided after `boundary(false)` returns. Failure to
clear the recovery marker removes the module before reporting failure. This is
module cleanup, not cancellation of arbitrary Python threads or other references.

The debug diagnostic additionally runs 20 raw-header malformed ZIP cases, a valid
control and same-path replacement/immutable snapshot checks. Cases include path
traversal, absolute/backslash/colon/empty/dot paths, directory and native files,
NUL/non-UTF8 names, duplicates/case collisions, symlink/FIFO, encryption, CRC,
size mismatch, oversize, entry-count limit and truncation. An independent CRC
check covers minizip accepting a bad CRC on empty stored entries.

Boundary failure is injected through the real runtime callback on both start
and stop. Tests query `sys.modules`, retry the exact same module name and verify
cleanup. The in-client review test holds a ticket inactive beyond ten real seconds,
checks rejection, then resumes a fresh ten-second gate. Foundation clock tests
also cover 1000 seconds inactive, 9.9 seconds after resume, and interruption after
eligibility. These test the gate and runtime, not manual UIKit background gestures
or actual disk-full recovery failures.
