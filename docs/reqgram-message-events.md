# ReqGram explicit message events (phase 1)

> **Readiness:** This is an implemented local Postbox watch for explicitly
> supplied message IDs. It is not a peer-wide or server-backed stream and does
> not establish production coverage for every message type, account, or device.

The normative contract is the [ReqGram plugin API reference](../Swiftgram/ReqGramPythonRuntime/ReqGramPluginAPI.md).

Declare `"capabilities":["message.events"]`, subscribe to `message.change`, then
call `client.watch_messages(peer_id, message_ids)`. `message_ids` is a non-empty
list of at most eight `peer_namespace_id` strings. Every ID must belong to the
explicit peer and use the cloud message namespace.

This watches only those IDs in local Postbox using `messageView`; it is not a
peer-wide stream or discovery API and performs no network request or mutation.
Allowed cloud user/group/channel peers only. Secret, copy-protected, ephemeral,
synthetic, advertisement, grouped, service/media, pending, and failed content is
not exported. Events use string fields only: `event=message.change`,
`transition=created|edited|deleted`, `peer_id`, `message_id`, `namespace`, and,
when eligible, `text`, `text_truncated`, `has_media=false`. Text follows the
existing 16 KiB UTF-8 DTO truncation policy.

Delivery uses the existing session queue (64, drop oldest), polling or callback
mode. Closing/revoking a session disposes native subscriptions. The first
eligible local value is `created`; later values are `edited`; disappearance
after an eligible value is `deleted`. No event is emitted for an initially
absent/ineligible value.
