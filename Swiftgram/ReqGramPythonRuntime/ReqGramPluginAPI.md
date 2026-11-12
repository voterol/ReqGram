# ReqGram plugin API (version 1)

This is the current v1 contract exposed by the main Telegram client to an
installed `.ixplugin`. It is a plugin-bound host callback, not a server API:
Python calls `host_request(operation, optional_bytes)`. Structured arguments
and results are UTF-8 JSON bytes. The host returns `None` when an operation has
no result, or bytes when it has a result.

CPython runs in the app process and is **not a sandbox**. This API does not
grant general access to Telegram messages, credentials, keychain data, arbitrary
UIKit, or arbitrary Telegram methods. The sole selected-message exception is the
explicit, tap-gated `messages.context` capability documented below.

## Lifecycle

`main.py` must define synchronous `on_enable()` and `on_disable()` functions.
The runtime imports a fresh module for each enabled session and calls the
appropriate hook. An uncaught exception fails the plugin start/stop operation,
records a quarantine reason and lifecycle log, and closes the host session.
Caught exceptions do not stop the plugin.

Sessions, subscriptions, queued events, pending UI and account snapshots are
session-only. They are discarded when the plugin stops or fails to start.
`on_enable()` must return. Polling remains the default; automatic delivery is
explicitly opt-in (see below). Python
threads are cooperative: disabling a plugin does not terminate plugin-created
threads or undo their side effects.

The executor closes subscriptions/UI/network before `on_disable()` runs.
Account, peer, app, event, UI and network authorization requires Starting or
Running and safe mode off, so these calls fail during stopping. The manager's
legacy settings/load/save/log paths instead check module identity and safe
mode; they can still be used during the stop hook. Old callbacks are not a
capability for a newly enabled module. Removing a module is not proof that all
Python references or threads have been destroyed.

The manifest must declare `api_version: "1"`. Unsupported operations are
rejected; they are not silently emulated.

## Bounded text mutation (first mutation phase)

Declare `"message.send"` in the manifest `capabilities` array and subscribe to
`message.mutation` before calling `Client.send_text(request_id,
idempotency_key, peer_id, text, reply_to_message_id=None)`. Capability approval
is performed when the plugin session is enabled; there is no per-call prompt.

The request has exactly `request_id`, `idempotency_key`, `peer_id`, and `text`,
plus optional `reply_to_message_id`. Request IDs use 1–64 and idempotency keys
1–128 ASCII letters, digits, `.`, `_`, or `-`. `peer_id` is a canonical decimal
cloud user/group/channel ID. Text must be nonempty and at most 16 KiB UTF-8.
The optional reply ID is the canonical `peer_namespace_message` form, must use
the cloud message namespace, and must belong to the same peer.

Only one plain-text message is accepted per request. Media, entities,
scheduling, send-as, effects, raw attributes, secret chats, and protected peers
are not supported. Admission returns `{ "status": "pending" }`. Completion is
an asynchronous `message.mutation` event containing the request and
idempotency keys. Success is strictly `status=queued, consistency=local` with a
local message ID: this confirms insertion into Telegram's normal pending-message
path and **does not claim server delivery**.

The host rejects peers that Telegram's current local `canSendMessagesToPeer`
helper marks clearly unwritable, and rejects an ineligible optional reply target
using the same text-export eligibility rules as message reads. These checks use
the local cache: `queued/local` still does not establish current server send
eligibility, and the server may reject a pending message.

Idempotency is scoped to the enabled session and its bounded in-memory cache.
After cache eviction or a process/app restart, a repeated key can enqueue a
duplicate; callers must not treat the key as durable deduplication. Repeating
the same key and exact
payload replays the same cached queued result without another enqueue; changing
the payload returns `idempotency_conflict`. Pending and cached operation counts
are bounded. Closing the session disposes observations but does not claim to
cancel or roll back a message already enqueued.

### Editing

Declare `message.edit`, subscribe to `message.mutation`, and call
`Client.edit_message(request_id, idempotency_key, peer_id, message_id, text)`.
The edit capability is independent of `message.send`; send permission never
authorizes an edit. The target must be an existing, unprotected cloud text
message with no media or grouping, and replacement text is nonempty and at
most 16 KiB UTF-8. The host rechecks capability and target eligibility before
native invocation where possible.

The terminal event has `status=succeeded` when native reports a change,
`status=unchanged` when native completes without a change, or a stable error
code: `restricted`, `text_too_long`, `invalid_grouping`, `edit_failed`,
`invalid_target`, or `permission_denied`. Neither success status claims
server-side delivery. Reusing the same key and exact payload replays the
terminal result without another native invocation; a changed payload returns
`idempotency_conflict`. This cache is bounded and session-scoped, so keys are
not durable across eviction or restart. Delete, forward, and media mutation
remain unsupported.

### Bounded deletion

Declare the distinct `message.delete` capability and subscribe to `message.mutation`, then call `Client.delete_message(request_id, idempotency_key, peer_id, message_id, scope="local")`. The request has exactly those five keys; the only supported scope is `local`. `everyone` is rejected as `invalid_payload` until remote-capable semantics can be exposed accurately. Only one canonical cloud message ID is accepted. Missing targets return `message_not_found`; secret, media, grouped, ephemeral, synthetic, ad, failed, sending, protected, and otherwise ineligible targets are rejected. Native invocation is exactly one message with `deleteAllInGroup=false` and `userInitiated=true`.

Success is `status=local_deleted` or `already_local_deleted`, `consistency=local`, and `remote_confirmation=not_requested`; `server_confirmed` is never emitted. Exact retries are idempotent and changed payloads conflict. Capability/account-generation checks happen immediately before native invocation, and closing disposes the request. `message.change` with `transition=deleted` is local observation only. Bulk/group deletion, forwarding, and media deletion are unsupported. There is a small non-atomic window between final admission and native invocation; callers must treat the terminal result as local observation, not server confirmation.

### Bounded forwarding

Declare the distinct `message.forward` capability, subscribe to
`message.mutation`, and call `Client.forward_message(request_id,
idempotency_key, source_peer_id, source_message_id, destination_peer_id)`.
The request has exactly those five keys and accepts one eligible cloud source
message and one cloud user/group/channel destination. Secret, protected, or
non-sendable peers and media, grouped, any threaded message, any message with
attributes, option-bearing, bulk, and raw MTProto requests are rejected.
Success is `status=queued`, `consistency=local`, and a destination local
message ID; it never claims server delivery. Exact retries replay the result
within the bounded enabled-session cache; changed payloads return
`idempotency_conflict`. Account, capability, peer, and source eligibility are
checked immediately before native enqueue, and closing disposes the request.
Terminal events include the source IDs. Provider failures use stable documented
codes; unrecognized provider failures are reported as `forward_failed`.

## Raw and SDK calls

### MTProto bridge (full_access only)

`mtproto.raw` and `mtproto.json` require only the explicit `full_access`
permission. They use the current account captured at session start and its
existing `Account.network`; accounts, credentials, and auth keys are never
exposed. Requests are synchronous, limited to 64 KiB of boxed, word-aligned
TL, and have a 1–30 second timeout. Raw input uses base64 `body`. JSON input
uses `{constructor, arguments}` and supports only typed `int`, `long`,
`double`, `string`, base64 `bytes`, `bool`, nested `constructor`, and `vector`
nodes. Unsupported schema-dependent forms return explicit errors. Successful
responses contain base64 `data` and are limited to 64 KiB; RPC failures contain
structured `code`,
`rpc_code`, and `rpc_message` fields.

The MTProto bridge does not use the older `network.request` raw-payload
contract. `mtproto.raw` and `mtproto.json` return a JSON object containing
`request_id` and either base64 `data` or a structured `error`. Validation,
timeout, session/account, and authorization failures use the same top-level
`error` string form; RPC failures use an error object as documented above. A
host error raises `RuntimeError` whose text is a JSON object with this shape:

```json
{"operation":"mtproto.raw","error":"permission_denied"}
```

The source SDK at `SDK/reqgram.py` provides a `Client` wrapper. It is not
automatically injected as an importable `reqgram` package: the example packager
`Examples/create_accounts_plugin.py` prepends the SDK source to `main.py`.
Do the same for this SDK example. The runtime injects only `host_request`.

### ExteraGram-shaped compatibility facade (small phase)

`SDK/exteragram.py` is an opt-in, documented compatibility layer for plugins
that use a small ExteraGram-shaped surface. It does not change the v1 host
contract or add an Android runtime. Import it after making the packaged `SDK/`
directory importable (the normal plugin SDK path; do not depend on the process
working directory or an unrelated global `PYTHONPATH`):

```python
from exteragram import AppEvent, BasePlugin

class Plugin(BasePlugin):
    def on_plugin_load(self):
        self.client.subscribe(AppEvent.MESSAGE_ACTION, AppEvent.UI_ACTION)
        self.add_message_action("info", "Info")

    def on_plugin_unload(self):
        pass

plugin = Plugin(host_request)
def on_enable():
    plugin.on_enable()       # maps to on_plugin_load
def on_disable():
    plugin.on_disable()      # maps to on_plugin_unload
```

The facade exposes `AppEvent` constants for the existing event names,
`add_message_action`/`remove_message_action`, `show_alert`/`show_notice`, and
an explicit-ID `send_message` wrapper for the existing bounded `message.send`
operation. All existing permissions, subscriptions, tap gating, limits and
local-consistency semantics remain in force. `MethodHook`, `java`, and
`dynamic_proxy` deliberately raise `NotImplementedError`: Android-only hooks,
arbitrary iOS function invocation, and a broader native bridge are out of
scope.
The wrapper JSON-decodes structured results
and sends JSON for structured arguments. Its `load()` and `save()` methods
return/use raw bytes, and `log()` encodes a string as UTF-8 before calling the
raw operation. The SDK's `network_request()` base64-encodes a bytes body.

```python
# main.py, after the SDK source; manifest permission: ui.alert
client = None

def on_enable():
    global client
    client = Client(host_request)
    client.subscribe("ui.action")
    client.alert("Hello", "Choose an action")
    # Return; immediate polling need not contain the asynchronous UI action.

def on_disable():
    global client
    client = None
```

Equivalent raw main.py (no SDK; permission `ui.alert`):

```python
import json

def on_enable():
    host_request("events.subscribe", b'["ui.action"]')
    result = json.loads(host_request(
        "ui.alert",
        json.dumps({"title": "Hello", "message": "Choose an action"}).encode(),
    ))

def on_disable():
    pass
```

## Operation reference

`null` in the input tables means omitted payload or Python `None`, not JSON
`b'null'`. Empty bytes are a payload and fail no-payload validation, except
`load`, which currently ignores its payload. UI/peer keys are exact; network
decoding ignores unknown keys.

### Bounded iOS helpers

Declare `ios.safe` to use these explicit symbolic operations. They never accept
Objective-C class names, selectors, handles, or arbitrary native arguments, and
`full_access` does not authorize them.

| Operation | Permission | Input | Result |
| --- | --- | --- | --- |
| `ios.safe.app_info` | `ios.safe` | `null` | Bounded iOS/app metadata DTO |
| `ios.safe.alert` / `ios.safe.notice` | `ios.safe` | exactly `{"title": string, "message": string}` | UI request ID; requires `ui.action` subscription |
| `ios.safe.output_volume` | `ios.safe` | `null` | `{"value": number}` in `[0, 1]` |
| `ios.safe.set_output_volume` | `ios.safe` | exactly `{"value": number}` in `[0, 1]` | `{"requested_value": number}` |
| `ios.safe.account_context` | `ios.safe` plus `accounts.read` | `null` | Same snapshot as `account.context` |
| `ios.safe.peer_lookup` | `ios.safe` plus `peer.read` | exactly `{"peer_id": integer}` | Same bounded DTO as `peer.lookup` |
| `ios.safe.message_get` | `ios.safe` plus `message.get` | exactly `{"peer_id": string, "message_id": string}` | Same bounded DTO as `message.get` |

Existing UI limits, rate limits, foreground checks, and `volume_unavailable`
handling remain in force. The ExteraGram facade exposes `app_info`,
`output_volume`, and `set_output_volume`; `BasePlugin.client` remains the
documented bounded ReqGram client, not a full Android/Telegram client.

### Storage and diagnostics

| Operation | Permission | Input | Result |
| --- | --- | --- | --- |
| `settings` | none | `null` | JSON bytes for declared settings values |
| `load` | `storage` | `null` | Stored opaque bytes, or `None` if absent |
| `save` | `storage` | raw bytes, at most 64 KiB | `None` |
| `log` | `log` | UTF-8 raw bytes, at most 4 KiB | `None` |

Storage is namespaced per plugin by the manager, not isolated from hostile
in-process Python. It is atomically persisted, without an fsync durability
promise. A saved empty value loads as `b''`, distinct from absent `None`.
`settings` returns a JSON object mapping declared field keys to booleans or
strings, using valid stored values or defaults. It requires `settings_schema`;
without one it fails with a legacy localized error. Each read sees current
manager values; re-enable is needed only to rerun initialization using them.
The legacy manifest `settings` dictionary is metadata only, not a UI schema.

The optional schema is `{"version":1,"fields":[...]}`. Each field has `key`,
`label`, `type` and `default_value`; optional `transferable` is a boolean.
There are at most 32 unique keys matching `[A-Za-z][A-Za-z0-9_]{0,63}`.
Labels are nonempty, at most 128 characters. Types are `boolean` (boolean
default), `string` (at most 1024 UTF-8 bytes), or `selection` (string default
in `options`). Selection options are 1-32 unique nonempty strings, each at
most 128 UTF-8 bytes; other types must not supply options. Python cannot write
settings. Native transfer controls are described in
[SETTINGS_TRANSFER.md](SETTINGS_TRANSFER.md); they are not host operations.

### Read-only account and peer metadata

`accounts.list` and `account.context` take no payload and require
`accounts.read`. They use a fixed session snapshot acquired when the module
starts. The list is:

```json
{"accounts":[{"handle":"account_<local record id>","is_primary":true}],"consistency":"session_snapshot"}
```

The context is:

```json
{"current_account":"account_<local record id>","consistency":"session_snapshot"}
```

`current_account` may be null. Handles are local account-manager identifiers,
not Telegram user IDs, peer IDs, credentials, phone numbers, tokens or session
keys. With `accounts.profile`, each user row may additionally contain
`profile: {"first_name":"...","last_name":"...","username":"..."}`.
Missing profile strings are empty. `accounts.profile` alone does not authorize
account reads. The native provider uses one active-accounts emission; context
means the account that supplied the settings controller, not a selectable
account. Missing provider or a five-second acquisition timeout gives
`account_context_unavailable`. Stop/re-enable refreshes this snapshot.

`peer.lookup` requires `peer.read` and takes exactly:

```json
{"peer_id":123456789}
```

`peer_id` is the internal packed `EnginePeer.Id`/`PeerId.toInt64()` representation
(signed Int64), not a Bot API chat ID, raw namespace-local Telegram ID, username
or account handle. The native provider constructs `EnginePeer.Id(id)` and reads
local engine data in the originating account, without username resolution or
remote fetching. The plugin must supply the ID; the API does
not enumerate peers. A successful result contains only `id`, `type` (`user`,
`group`, or `channel`), `title`, and `username` (possibly null). Secret chats
and unavailable peers are not exposed. There is no peer, message, account,
credential, token or session mutation operation.

The result `id` is a JSON integer; `type` and `title` are strings. Username is
the first active username, falling back to the first available username, or
null. Legacy groups and communities map to `group`. Lookup is per-call, not
the frozen account snapshot. Missing/secret peers or a five-second wait expiry
give `peer_not_found`; a missing provider currently gives `invalid_payload`.
Validation checks NSNumber's nonzero Int64/string representation, not an
explicit JSON boolean discriminator: send integer tokens, not booleans or
fractional values. No peer-ID conversion or discovery helper is provided.

`message.search` requires `message.search` and takes exactly:

```json
{"peer_id":"<signed Int64>","query":"text","limit":20}
```

The peer must be a cloud user, group, or channel. The query is non-empty, has
no NUL characters, and is at most 512 UTF-8 bytes. `limit` is an integer from 1
through 50; booleans, fractions, and numeric strings are rejected. Search uses
the active account's local Postbox text index only and never invokes Telegram
network search. It returns `{messages, consistency: "local", network_fetched: false}`.
The same conservative message eligibility rules as `message.get` and
`message.history` apply; ineligible messages are omitted. An empty result is
valid. Stable failures include `invalid_payload`, `invalid_peer`,
`peer_not_found`, `secret_chat`, and `protected_content`.

### App and events

| Operation | Input | Result |
| --- | --- | --- |
| `app.info` | `null` | `platform`, `client`, `bundle_id`, `version`, `build`, `os_version`, `api_version` |
| `events.subscribe` | JSON array of at most three names | `None` |
| `events.unsubscribe` | JSON array of at most three names | `None` |
| `events.poll` | `null` | JSON array; drains the queue |
| `events.callback` | `null` | `None`; one-way opt-in for this session |
| `events.status` | `null` | `mode`, `failed`, `queued`, `dropped`, `delivered` |

Allowed event names are `app.active`, `app.inactive`, `ui.action`,
`network.response`, `message.action`, `message.change`, and `message.mutation`. The queue holds at most 64 events; when full, the oldest is
dropped. Events are delivered only while their subscription exists.

These operations require no manifest permission except subscribing/unsubscribing
`message.action`, which requires `messages.context` authorization; `message.change`, which
requires the `message.events` capability and `message.events.watch` authorization; and
`message.mutation`, which requires the `message.send` capability. Subscribe/unsubscribe are
idempotent; empty arrays and duplicates are accepted, but the three-entry cap
counts duplicates. All names can be subscribed/unsubscribed in separate calls
(with authorization for `message.action`); this is not a session-wide cap.
Unsubscribe also removes already queued events of those names. Poll returns
`[]` when empty. There is no replay, initial app-state event, delivery guarantee
or persistent queue. App notifications produce exactly `{"event":"app.active"}`
or `{"event":"app.inactive"}`. UI completion is
`{"event":"ui.action","request_id":"<UUID>","action":"ok"}` (or the other
actions below). All event values are strings.

#### Message change watches

`message.events.watch` and `message.events.unwatch` require exactly
`{"peer_id":"<signed Int64>","message_ids":["<peer>_<namespace>_<id>", ...]}`.
IDs are complete canonical cloud message IDs for the same peer. A watch contains at most eight
distinct IDs and a session holds at most sixteen distinct keyed watches. Duplicate watches are
idempotent. Setup returns `{"status":"pending"}` and provider validation failures are emitted as
a `message.change` event containing `error`; they are not reported as unconditional success.
Created/edited events have exactly `event`, `transition`, `peer_id`, `message_id`, `namespace`,
`text`, `text_truncated`, and `has_media`; deleted events have exactly the first five keys.
Protection is rechecked at every emission. Unwatch removes only the matching keyed watch. Revocation,
account changes, unsubscribe, close, and disable dispose every watch; there is no peer-wide stream.

#### Optional automatic callbacks

Define a synchronous `on_event(event)` in `main.py`, subscribe normally, and call
`host_request("events.callback")` (SDK `client.enable_callbacks()`). The argument
is one decoded Python dictionary with exactly the same fields as a polled event.
The return value is ignored. Async functions/coroutines are not supported.
Opt-in is idempotent and one-way until a fresh enable; it transfers any queued
events to callback delivery. There is no extra copy/second queue. `events.poll`
then raises `callback_mode` rather than competing for events. Merely defining
`on_event` does not opt in. No new permission or manifest version is needed.

Delivery is armed only after successful `on_enable` and recovery-marker cleanup;
there is no Python reentry from a host request. All callbacks share the existing
off-main serial interpreter queue with lifecycle hooks. At most one delivery
turn per session is outstanding, with one event per turn and at most 64 queued
events (oldest dropped on overflow). This bounds queued work, not Python run
time. Slow callbacks delay other plugins. Network events retain their existing
body limit; 64 large responses can still consume substantial memory. There is
no retry, replay, timer, background-execution entitlement or delivery guarantee.

Disable invalidates the session before scheduling teardown. Each queued turn
rechecks host authorization and session liveness at final admission; closed
sessions cannot take events, and old closures cannot drain a replacement queue.
A callback already admitted is in flight and may finish; disable cannot
interrupt arbitrary Python. Unsubscribe removes pending events, not an in-flight
callback. `on_disable` waits behind running Python on the serial queue.

A missing/noncallable hook or uncaught Python exception (including SystemExit)
clears the Python error and suspends further delivery for that session, dropping
pending events. A fixed native diagnostic is logged without payload/exception
contents. The module stays resident/Running for explicit disable; this is not a
manager quarantine transition. Execution-boundary failure also suspends delivery.
Re-enable is required to recover. `client.event_status()` returns session-only
`mode` (`poll`/`callback`), `failed` (boolean), `queued`, `dropped` (overflow only),
and `delivered` (successful delivery turns). Status is not persisted. Each turn
uses the manager's existing persisted execution/recovery marker; callbacks may
use normal permission-gated storage, but events themselves are not persisted.

If clearing an execution marker fails, subsequent plugin execution boundaries
fail closed while that marker remains, including other plugins and stop hooks.
The original attribution is never replaced by a new entry or cleared by a
non-admitted/duplicate exit. Native stop cleanup still closes capabilities and
removes module residency, but skips `on_disable` if its entry is refused. Restart
uses the existing recovery path to quarantine the attributed plugin and enter
safe mode. A successful later storage write or safe-mode toggle does not itself
clear the retained marker. Module removal is not a sandbox or a guarantee that
Python finalizers/previously created threads cannot execute.

Generate an account/network-free example with
`python3 Examples/create_events_plugin.py /path/to/new.ixplugin`. It subscribes
to app lifecycle events, saves a counter through plugin storage and logs it.
Packaging does not install or execute the plugin. Existing polling packages need
no changes. This adds no Telegram messages, mutations, sandbox or interruption.

`app.info` returns strings: `platform` is `ios`, `client` is `ReqGram`,
`api_version` is `1`; bundle/version/build can be empty if metadata is absent.
`os_version` is the system version description, not a promised numeric format.

### UI actions

Both operations require a `ui.action` subscription and their matching
permission. The payload must be exactly:

```json
{"title":"...","message":"..."}
```

The title is non-empty and at most 128 UTF-8 bytes; the message is at most
2048 UTF-8 bytes. A successful call returns `{"request_id":"<UUID>"}` when
queued, not when displayed.

| Operation | Permission | Completion event |
| --- | --- | --- |
| `ui.alert` | `ui.alert` | Fixed OK/Cancel; action is `ok`, `cancel`, or `unavailable` |
| `ui.notice` | `ui.notice` | OK only; action is `ok` or `unavailable` |

The visible title is prefixed with `Plugin:`. Only one request may be pending
per plugin, and UI requests are limited to one every five seconds. Inactive or
unavailable presentation produces `unavailable`. These operations do not send
network traffic or change account state.

## Permission-gated network

Subscribe to `network.response` before calling `network.request`. HTTPS
requires `network`. **Current implementation:** HTTP checks `network.insecure`
instead of `network`, not both permissions. Declare both for a plugin using
both schemes; no network permission is granted by default. Input is:

```json
{"url":"https://example.invalid/api","method":"POST","headers":{},"body":"aGVsbG8=","timeout":15}
```

Required `url` and `method` are strings; method is uppercased before validation.
`headers` is an optional string-to-string object (default `{}`), `body` an
optional base64 string, `timeout` an optional number (default 15). Null optional
fields use their defaults. URLs must parse with a host and are at
most 2048 UTF-8 bytes. Methods are GET, POST, PUT, PATCH, DELETE or HEAD. At
most 32 headers are allowed; names are at most 128 UTF-8 bytes and values at
most 4096 bytes. Bodies are at most 64 KiB and timeouts are 1 through 30
seconds. A queued request returns `{"request_id":1}`.

The bridge's 65,536-byte limit applies to the entire encoded JSON payload,
including headers and base64 overhead. Thus a full 64 KiB binary body cannot
actually pass this bridge; the usable body size is smaller. No explicit
request-concurrency or network rate cap is implemented. Request IDs increase
from 1 within each session and are numbers in the return, strings in events.

The response is an event, not a direct return value:

```json
{"event":"network.response","request_id":"1","status":"200","size":"11","body":"aGVsbG8gd29ybGQ=","error":""}
```

Response bodies are capped at 1 MiB. On timeout, transport failure, or an
oversize response, `body` is empty and `error` is `timeout` or
`network_error` as applicable. A missing HTTP response has status `0`.
`size` is the buffered byte count, which may be nonzero even when an error
suppresses the body. HTTP error statuses are not themselves transport errors;
they can have `error: ""` and a body. No response headers are exposed. Oversize
cancellation has no dedicated error code. A pending request can be cancelled
with `network.cancel` and `{"request_id":1}` using the `network` permission;
the separate `network.insecure` permission is not sufficient. `request_id`
must be a positive JSON integer; booleans, fractions, zero, negative values,
and out-of-range values are rejected. It returns `{}` when it wins; unknown, completed, or already
cancelled IDs return stable `request_not_found`. The winning cancellation
produces exactly one terminal `network.response` with empty body/size and
`error: "cancelled"`; if completion wins, its normal response is delivered.
Cancellation stops further result delivery to the plugin, but is best-effort
at the transport boundary: it does not guarantee that a request already
accepted by the remote server is rolled back or never completes server-side.
Redirects are followed only when the destination is HTTPS; unsafe schemes are
rejected. The session is ephemeral and cookie-free and supplies no app
authentication, Telegram session, keychain data or credentials. Host logs
contain only host/path, method, status and size, not query strings, headers or
bodies.

HTTP permission does not override platform transport policy or guarantee a
connection. HTTP redirect destinations are refused even with that permission;
refusing a redirect need not produce a bridge error (the redirect response may
be returned). HTTPS redirects are not restricted to the original host. Caller-
supplied headers/body are sent; cookie-free configuration is not a ban on an
explicit Cookie or Authorization header. Host/path logs can contain sensitive
path components, and plugin `log` contents are not automatically redacted.

Stopping the plugin cancels pending URL tasks and closes the network session.
Cancellation is not delivered as a `network.response` event: the closed
session suppresses completion delivery. A request that times out before close
produces the normal error event.

## Errors and unsupported surface

The 46 public `Client` methods are implemented for the bounded v1 contracts in
this document. That means the SDK wrappers and native operation handlers exist;
it does not turn ReqGram into a general Telegram API or make every operation an
unconditional success. Reads may be local-cache-only, mutations may report only
local enqueue/change status, UI depends on a presentable foreground scene, and
network completion remains asynchronous. The safe all-API fixture verifies every
method without sending real messages or making external requests, so its PASS is
admission/lifecycle evidence rather than live-service or physical-device proof.

Stable bridge errors are `invalid_payload`, `permission_denied`,
`session_inactive`, `subscription_required`, `ui_busy`, `rate_limited`,
`peer_not_found`, `peer_not_sendable`, and `unsupported_operation`. Message
reply validation can also return `reply_not_found` or `ineligible_message`.
Account snapshot acquisition
can return `account_context_unavailable`. Storage/settings/log failures may
retain a localized host error description rather than a stable code.

`network_insecure_url` rejects a parsed URL whose scheme is not allowed, after
input validation and authorization. Invalid types, lengths or required fields
give `invalid_payload` in structured handlers; missing subscriptions give
`subscription_required`. Error precedence follows authorization first in the
executor, not a universal validation ordering. Missing storage/log permission,
missing settings schema, or malformed legacy inputs instead use the localized
`Invalid or unsupported .ixplugin package.` description; persistence failures
can supply other localized text. Do not parse those descriptions as codes.
Bridge argument errors are earlier `TypeError` (e.g. non-bytes payload) or
`ValueError` (payload over 64 KiB), not JSON RuntimeErrors. SDK JSON/encoding
errors are Python errors and are not normalized into host errors.

The following remain explicitly **not implemented and not promised** in v1:

- General chat/message APIs remain unsupported. The supported chat/message
  reads are the bounded local operations `chat.context`, `message.get`,
  `message.history`, and `message.search` documented above; update streams and
  mutation types not explicitly listed remain unsupported.
- Arbitrary Telegram method calls or an MTProto/Telegram API facade.
- Peer enumeration, server/network-backed history, remote
  deletion, media mutation, or account mutation. Bounded local deletion and
  single-message forwarding are supported only as documented above.
- Settings write callbacks, arbitrary native UI,
  authenticated plugin distribution, or a Python sandbox.

## Simulator and known limitations

The DEBUG fake-provider seam supplies deterministic account and explicitly
requested peer snapshots for diagnostics only. It does not enumerate peers and
is not evidence of additional API behavior. The DEBUG URL protocol simulates
network responses, a redirect-shaped response, oversize bodies, timeouts and
shutdown scheduling without live traffic. Its redirect fixture emits a 302
response directly; it does not prove URLSession's redirect delegate behavior.
Its cancellation check is scheduled, not proof of event delivery. The fake
account provider returns `account_fixture` and peer ID `4242` only, not real
account/peer lookup coverage. Simulator diagnostics are not evidence for real
accounts, live HTTP/TLS/redirect policy, physical devices, or all UI actions.

## Source evidence

This reference follows `SDK/reqgram.py`, `Sources/RGPythonRuntime.m`,
`../SGSettingsUI/Sources/ReqGramEmbeddedExecutor.swift`,
`../SGSettingsUI/Sources/ReqGramNetwork.swift`,
`../SGSettingsUI/Sources/ReqGramAccountProvider.swift`, and
`../SGSimpleSettings/Sources/ReqGramPluginManager.swift`. Manager `authorize.*`
operations are internal plumbing, not additional supported plugin APIs. The
separate native `reqgram_host` smoke module is not plugin-bound storage or an
alternative to this contract. Unimplemented chat/message/update/mutation APIs
have no schemas or delivery dates in v1.

The runtime is in-process and unsandboxed. Disable is cooperative, safe mode
blocks new starts, plugins do not restart automatically, and interrupted
execution can enter recovery safe mode. These are implementation limitations,
not security guarantees.
# Selected-message actions (bounded API v1)

`messages.context` is a new explicit manifest permission. It grants neither history
access nor message listening. Default is no message access. Permission **and a user
tap on a plugin-branded native message-menu action** are required. Subscribe to
`message.action`, then call `Client.register_message_action(id, label)`;
`Client.unregister_message_action(id)` removes it (idempotent).

Host operations: `messages.register` takes exactly `{"id": string, "label": string}`
(512 bytes max); `messages.unregister` takes exactly `{"id": string}` (128 bytes).
IDs match `[A-Za-z][A-Za-z0-9_]{0,31}`. Labels are nonempty, trimmed, at most 64 UTF-8
bytes, without controls or bidi overrides/isolates. Unknown keys/types are rejected.
Two actions per session, eight globally; duplicates fail rather than replace.
Errors include `invalid_payload`, `permission_denied`, `subscription_required`,
`duplicate_action`, `action_limit`, and `account_context_unavailable`.
Native labels are `Plugin [manifest-id]: label`, not Telegram actions.

The existing callback/poll bridge delivers a string-valued event:
`event=message.action`, `action_id`, `account_id=account_<AccountRecordId.int64>`,
`peer_id=String(EnginePeer.Id.toInt64())`, `message_namespace`, `message_id`, `text`,
`text_truncated` (`"true"`/`"false"`). IDs are strings, not JavaScript numbers or
Bot API IDs. Message identity is the account/peer/namespace/message tuple.
Text is a Unicode-scalar prefix capped at 4096 UTF-8 bytes; serialized event cap is
32768 bytes. Existing queue cap is 64 events (oldest dropped). No sender profile,
credentials, attachments, media blobs, entities, replies, or surrounding messages.
Text itself may contain user secrets: never log it by default.

Only one ordinary cloud text message in the normal chat menu is eligible. Excluded:
secret chats, copy-protected messages/chats (including own copy protection), all
auto-remove/auto-clear/self-destruct/view-once content, all media (including link
previews and service media), ads, synthetic preserved/deleted messages, grouped
messages, actual multi-selection, and non-cloud namespaces. Native grouped-bubble
`selectAll` is not actual multi-selection; grouped messages remain excluded. Eligibility is
rechecked against the currently visible message at tap, with no database/history
fetch or network call. Other menus (search/recent actions/audio/etc.) are not wired.

Registrations and queued data are session-only, never persisted. Native teardown
removes registrations before `on_disable`; no unregister call is needed there.
Unregister also discards queued events for that action; a new registration with the
same ID cannot receive an old menu tap. Unsubscribing from `message.action` removes
all session actions and queued message events; subscribe and register again to
restore them. Callback failure removes actions rather than leaving inert menu items.
Account switches invalidate registrations and queued message events, including a
switch away and back; disable/re-enable creates fresh unforgeable menu tokens.
Re-enable on the active account to register again. The permission grants no send,
edit, networking or account enumeration. Other independently granted capabilities
are unchanged; embedded Python is not an OS security sandbox.

Generate locally (does not install):
`python3 Examples/create_message_info_plugin.py /tmp/05-message-info.ixplugin`.
The example requests only `messages.context` and `ui.notice`, and shows the received
text length and message ID via notice without logging message content.
# Native iOS bridge (`full_access` only)

The first native bridge slice exposes `native.class_call`,
`native.instance_call`, `native.get`, `native.set`, and `native.release`.
Objects that are not JSON scalar values are returned as opaque handles owned by
the enabled plugin session. Handles cannot cross sessions and are invalid after
release, disable, failure, or session close. Requests and responses are limited
to 64 KiB and a session may retain at most 256 handles.

Arguments and return values support Objective-C objects and numeric/boolean
scalars. An argument can reference an object as `{"handle": "..."}`. Raw
pointers, C functions, blocks, selectors/classes as typed values, arrays,
dictionaries, and unsupported struct/union return or argument encodings are
rejected with `unsupported_type`. JSON arrays and dictionaries remain valid as
request envelopes and handle references, but are not passed through as arbitrary
Objective-C object arguments. Runtime signature/arity validation happens
before invocation. Stable errors include `permission_denied`,
`session_inactive`, `invalid_payload`, `invalid_handle`, `class_not_found`,
`selector_not_found`, `signature_mismatch`, `unsupported_type`, `handle_limit`,
`result_too_large`, `native_result_invalid`, and `native_exception`.

`native.audio.output_volume` reads `AVAudioSession.outputVolume`.
`native.audio.set_output_volume` accepts `{"value": 0.0...1.0}` and writes the
system output volume through an `MPVolumeView` slider. Its response contains
`requested_value`; read `output_volume()` separately for the system-observed
value because route updates may be asynchronous. Both operations run on the main
thread; the hidden volume view is removed at session close. The SDK wrappers are
`output_volume()` and `set_output_volume(value)`.
