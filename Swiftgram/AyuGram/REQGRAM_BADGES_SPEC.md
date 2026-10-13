# ReqGram badges and support UI specification

Status: agreed product behavior; implementation in progress.

This file records the intended behavior so that the badge system is not
reduced back to the current single-source, single-slot implementation.

## Product ownership

- ReqGram is the first-party project and first-party badge authority.
- AyuGram and exteraGram are compatible external badge authorities.
- A peer can receive badges from any number of authorities at the same time.
- Sources are additive. A successful response from one source must never
  replace, suppress, or delete another source's cached result.
- ReqGram branding, support contacts, links, donation details, and explanatory
  copy replace the current exteraGram placeholders in ReqGram-owned UI.
- Physical-device IPA work stays paused until explicitly requested. Development
  and acceptance testing currently target the existing Simulator installation.

## AyuGram / exteraGram compatibility semantics

- AyuGram and exteraGram remain independent transport/cache sources so one
  endpoint failing cannot wipe the other endpoint's last-known-good data.
- They are one compatible user-facing badge family. The endpoint that delivered
  a grant must not produce `A`/`E` monograms or an "Issued by exteraGram" label.
- Equivalent fixed-role grants from both compatible sources are displayed once;
  transport provenance remains internal for diagnostics and cache ownership.
- Supporter/donation roles use Telegram custom emoji document ID
  `5391059537102927631`.
- Official-resource roles use Telegram custom emoji document ID
  `5390820689676633124`.
- A custom badge always uses its own server-provided `documentId` and sanitized
  server-provided description. Fixed role mappings must never overwrite it.
- Badge explanation copy includes the displayed peer name and the role meaning,
  e.g. that the peer supported development or is an official resource.
- Automatic source refresh uses the built-in one-hour Ayu interval. There is no
  manual "Refresh now" settings action or refresh-result toast.

## Required visible behavior

Given one Telegram peer that is listed by ReqGram and AyuGram, the application
must render both authorities' applicable badges. If the same peer also has a
Telegram emoji status, Premium status, verification, scam/fake marker, or bot
verification icon, those Telegram-owned indicators remain intact.

Project badges must use an independent badge strip. Remote project data must
never be converted into Telegram's authoritative verified state. In particular,
a remote `developer` or `official` assignment must not make an account look
Telegram-verified.

All resolved project badges remain available even on narrow surfaces:

- profile: show as many as fit, followed by `+N` overflow;
- chat title: show a compact fitting prefix and `+N` overflow;
- chat list: show a compact fitting prefix and `+N` overflow;
- overflow opens a list/card containing every hidden badge;
- each visible or overflow badge has its own explanation and source.

Badge ordering is deterministic:

1. ReqGram;
2. AyuGram;
3. exteraGram;
4. within a source: owner, official, team/developer, sponsor/supporter, custom.

Exact duplicate assignments may be deduplicated only by stable source-level
identity. A ReqGram badge and an AyuGram badge must not be deduplicated merely
because they use the same Telegram custom-emoji document ID.

## Mandatory sources

Built-in badge authorities are application policy, not an end-user appearance
toggle. They are fetched and merged automatically and cannot be disabled from
settings. A source failure retains only that source's bounded last-known-good
cache and does not prevent other sources from refreshing.

The previous global `ayuRCEnabled` switch must not gate the aggregate resolver.
If retained for migration/UI compatibility, it must not disable mandatory
sources or erase their independent caches.

## Source and cache model

Each source has independent configuration and cache state:

```text
source id
endpoint URL
mandatory flag
display name
last successful fetch timestamp
last-known-good validated payload
optional payload revision / expiry
```

Fetches are independent, not primary/fallback. A malformed, empty, truncated,
timed-out, or unavailable source cannot wipe another source. Empty payloads are
valid only when the contract provides explicit revision/revocation semantics;
otherwise they are treated as a soft failure.

Cache authority is bounded by a maximum age. Production ReqGram payloads should
eventually be signed and monotonic so a compromised or rolled-back response
cannot grant badges indefinitely.

## Peer identity

Badge lookup uses Telegram's full peer identity, including namespace. A bare
numeric ID must not grant a user badge to an unrelated channel or group with
the same numeric component.

Legacy compatible fields are interpreted by namespace:

- `developers` and `supporters`: cloud users only;
- `officialChannels` and `supporterChannels`: cloud channels only;
- legacy `customBadges`: accepted only with an explicit peer type in the new
  ReqGram format; compatibility sources may use their documented legacy scope.

## ReqGram API contract

The endpoint and exact custom-emoji document IDs are centralized in one ReqGram
configuration file. Until production values are supplied, absent values disable
only the unavailable ReqGram network request/glyph and never fabricate data.

Preferred additive response shape:

```json
{
  "schemaVersion": 1,
  "revision": 42,
  "generatedAt": 1787529600,
  "expiresAt": 1788134400,
  "badges": [
    {
      "id": "reqgram-owner",
      "peer": { "type": "user", "id": "123456789" },
      "kind": "owner",
      "documentId": "5294384345870515594",
      "title": "ReqGram owner",
      "text": "ReqGram project owner."
    },
    {
      "id": "reqgram-sponsor-2026",
      "peer": { "type": "channel", "id": "987654321" },
      "kind": "sponsor",
      "documentId": "5294384345870515595",
      "title": "ReqGram sponsor",
      "text": "Supported ReqGram development."
    }
  ]
}
```

Allowed peer types are `user`, `group`, and `channel`. Allowed kinds are
`owner`, `official`, `team`, `developer`, `sponsor`, `supporter`, and `custom`.
Unknown kinds and malformed entries are ignored. Numeric identifiers may be
encoded as decimal strings to avoid JSON precision loss.

For compatibility, AyuGram/exteraGram's existing compact shape remains accepted:

```json
{
  "developers": [123],
  "officialChannels": [456],
  "supporters": [789],
  "supporterChannels": [101112],
  "customBadges": [
    {
      "id": 123,
      "badge": {
        "documentId": 5294384345870515594,
        "text": "Optional explanation"
      }
    }
  ]
}
```

Compatibility payloads are stored separately with source provenance. They are
never collapsed into a single anonymous payload.

## Validation and safety

Remote responses and cached payloads are untrusted data.

- HTTPS only in production.
- Reject oversized `Content-Length` and stop streaming after the byte limit.
- Bound badge count per source and per peer.
- Validate positive peer IDs and custom-emoji document IDs.
- Bound title and text before expensive Unicode transformations.
- Remove controls, format characters, and unexpected line breaks.
- Do not accept remote colors, dimensions, selectors, code, or arbitrary UI.
- Deep-link/action schemes use an explicit allowlist.
- Scam/fake markers remain authoritative and are never hidden by project badges.
- A missing or inaccessible custom emoji degrades to a source-specific local
  glyph/label, not to a different emoji that changes the badge meaning.

## Badge information UI

The current one-button `textAlertController` and notification-like toast are
replaced by Telegram-native rich cards (`AlertScreen` for short content and an
adaptive sheet for long/overflow content).

A badge card contains:

- the exact custom emoji or source-specific glyph as a centered hero;
- localized title;
- source/issuer name;
- explanatory text;
- optional validated actions such as Learn More or open official resource;
- a Close/OK action.

Profile, chat-title, and chat-list badge interactions use the same card factory.
Buttons must execute directly from the presented controller rather than relying
on a transient notification overlay.

## ReqGram support UI and deep links

ReqGram support is a rich native modal/sheet matching AyuGram's structure, not a
plain system alert. It can contain:

- ReqGram hero artwork;
- support-development explanation;
- donation/payment instructions;
- proof-of-payment contact action;
- badge entitlement explanation;
- Learn More / official resource action;
- Close action.

All exteraGram names, contacts, and placeholder payment copy in ReqGram-owned UI
are replaced by centralized ReqGram branding values.

The product requirement currently assigns `tg://support` to this ReqGram support
window. Routing must present the actual interactive controller so its buttons
work. ReqGram-specific aliases may also be supported, but parsing must not allow
arbitrary URL execution. Any collision with Telegram's native support route must
remain explicit and covered by a routing test.

## Custom emoji/status fidelity

Do not approximate screenshot glyphs with Unicode characters or Telegram's
Premium/verified icons. Render the exact Telegram custom-emoji document IDs
published by the corresponding source. ReqGram's built-in role glyph IDs live
in centralized configuration and can be updated without changing render code.

One peer may show, simultaneously:

- its Telegram emoji status;
- ReqGram owner/team/sponsor/custom badges;
- AyuGram developer/supporter/custom badges;
- exteraGram developer/supporter/custom badges.

## Acceptance checklist

- A peer listed by two sources shows both sources' badges.
- Multiple roles from one source are not collapsed to one winner.
- Telegram status/verified/premium indicators are unchanged.
- No remote assignment renders as Telegram verification.
- Built-in source fetching cannot be disabled in settings.
- One failed source does not affect another source's displayed cache.
- Namespace collisions do not grant badges to unrelated peer types.
- Badge cards open from profile, chat title, chat list, and overflow.
- `tg://support` opens the ReqGram rich support controller and its configured
  actions work.
- Exact configured custom emojis render; missing IDs fail gracefully.
- Long names, narrow screens, RTL, VoiceOver, and Reduce Motion remain usable.
- Simulator is updated non-destructively and existing account/app data survives.

## Values still to supply

Implementation must keep these in centralized configuration until real values
are available:

- ReqGram production badge endpoint;
- ReqGram role custom-emoji document IDs;
- donation/payment URL or TON details;
- proof-of-payment username/link;
- Learn More URL;
- official ReqGram resource/channel.

Missing production values are not blockers for implementing aggregation,
validation, caching, layout, cards, routing, and fallback behavior. They must not
be replaced with invented public endpoints, contacts, or document IDs.
