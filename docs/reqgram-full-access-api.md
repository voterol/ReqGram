# ReqGram bounded read API (phase 1)

## Native iOS bridge

Plugins declaring `full_access` can use the session-owned Objective-C bridge
and system-volume operations documented in the canonical API reference. The
executor checks `authorize.native` on every `native.*` request. Opaque handles
are scoped to one enable session and are invalidated on release or close. This
surface intentionally permits Objective-C runtime access and is not designed
for App Store policy compatibility; it still rejects raw pointers, C functions,
blocks, and unsupported structs, validates method signatures, bounds JSON, and
maps Objective-C exceptions to stable errors.

> **Readiness:** These are implemented bounded local reads, not general Telegram
> or MTProto access. This summary does not promise server-backed history or search,
> arbitrary message access, or successful reads for every account/device.

Plugins may declare `chat.context`, `message.get`, `message.history`, and/or
`message.search` in
`manifest.json` permissions to receive the corresponding bounded read access
without a prompt for each call. Each operation is checked against its own
declared permission by the plugin manager for every request and still stops in
safe mode or when the account/session generation is invalidated. See the
canonical [ReqGram plugin API reference](../Swiftgram/ReqGramPythonRuntime/ReqGramPluginAPI.md)
for exact schemas and errors.

The SDK methods are `client.chat_context(peer_id)`,
`client.message(peer_id, "peer_id_namespace_message_id")`, and
`client.history(peer_id, limit=20, anchor_id=None)`, and
`client.search(peer_id, query, limit=20)`. IDs are strings at the
SDK boundary. History is local Postbox data only in this phase: responses
include `consistency: "local"`, `network_fetched: false`, and `hole_before` /
`hole_after`. A hole means the local cache is incomplete; callers must not
interpret a result as complete server history. Search is local Postbox text-index
search only: it never fetches from Telegram and returns
`consistency: "local", network_fetched: false`.

DTOs are allowlisted and exclude MTProto/TLObject values, media bytes,
credentials, and mutations. Requests are limited to 4 KiB, history to 50
messages, each text field to 16 KiB of UTF-8 (with `text_truncated`), and
serialized responses to 256 KiB. Only cloud users/groups/channels are
supported; secret/unknown peers and messages carrying copy-protection,
ephemeral/autoremove/autoclear, synthetic, advertisement, media, service, or
grouped-message state are rejected or omitted by this local Postbox read
boundary. This is not a claim that the Telegram service filters those messages
for other clients or APIs.

Example manifest declaration:

```json
{"api_version":"1","permissions":["chat.context","message.get","message.history","message.search"]}
```
