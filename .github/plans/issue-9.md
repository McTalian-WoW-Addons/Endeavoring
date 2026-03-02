# Feature Plan: Gossip Protocol v2 — Digest-based Exchange + Short Wire Keys

**Issue**: [#9 - Overly eager gossip protocol](https://github.com/McTalian-WoW-Addons/Endeavoring/issues/9)
**Created**: February 27, 2026

## Overview

The current gossip protocol (Phase 3.5) sends full unsolicited profile data (ALIAS_UPDATE + CHARS_UPDATE messages) to every player whose MANIFEST we receive, up to 3 profiles each time. With 5-10 addon users online in an active guild, this creates a storm of whisper messages — especially after relogs, zone changes, and heartbeat manifests — that hits WoW's addon message throttle limit.

This plan replaces the "push everything unsolicited" approach with a **digest-based handshake**: send a compact summary of what you know, let the receiver request only what they need. Combined with cross-session tracking and short wire keys, this dramatically reduces message volume while improving convergence speed.

## User Experience

**Before**: Players see `AddonMessageThrottle` errors in active guilds. Profile data gets lost due to throttled messages.

**After**: Gossip uses 1 message (digest) instead of 3-15+ messages (full profiles). Receivers request only data they're actually missing. No more throttle errors. Faster convergence because digests cover more profiles (up to 8) than old gossip (3 profiles), but with far fewer total messages.

## Wire Key Reference

All message types use short CBOR keys on the wire. The receiver's `NormalizeKeys` maps them to verbose keys for internal use.

| Short Key | Verbose Key | Used In |
|-----------|-------------|----------------------------------------------|
| `t` | `type` | All messages (envelope) |
| `b` | `battleTag` | MANIFEST, ALIAS_UPDATE, CHARS_UPDATE, GOSSIP_DIGEST entries, GOSSIP_REQUEST |
| `a` | `alias` | MANIFEST, ALIAS_UPDATE |
| `cu` | `charsUpdatedAt` | MANIFEST, CHARS_UPDATE, GOSSIP_DIGEST entries |
| `au` | `aliasUpdatedAt` | MANIFEST, ALIAS_UPDATE, GOSSIP_DIGEST entries |
| `af` | `afterTimestamp` | REQUEST_CHARS, GOSSIP_REQUEST |
| `c` | `characters` | CHARS_UPDATE |
| `n` | `name` | Character objects (nested) |
| `r` | `realm` | Character objects (nested) |
| `d` | `addedAt` | Character objects (nested) |
| `e` | `entries` | GOSSIP_DIGEST (new) |
| `cc` | `charsCount` | MANIFEST, GOSSIP_DIGEST entries (new) |

## Problem Analysis

### Current Message Count (Worst Case Per MANIFEST Received)

```
3 profiles × (1 ALIAS_UPDATE + ceil(chars/4) CHARS_UPDATE)
= 3 × (1 + 1..4) = 6-15 whisper messages
```

With 5 addon users online, each sending heartbeat MANIFESTs every 5 minutes:
```
5 manifests/cycle × 6-15 messages/manifest × 5 receivers = 150-375 messages per 5-min cycle
```

Plus the per-session-only tracking means every relog resets all gossip state, causing a full re-gossip burst.

### New Message Count (Worst Case Per MANIFEST Received)

```
1 GOSSIP_DIGEST message (always)
+ N GOSSIP_REQUESTs from receiver (only for profiles they actually need)
+ For each request: 1 ALIAS_UPDATE + ceil(chars/4) CHARS_UPDATE
```

After initial convergence, N ≈ 0 (everyone already has the same data). During convergence, N is bounded by new/updated profiles only.

## Technical Approach

### New Message Types

**GOSSIP_DIGEST** (wire type: `"G"`):
Compact summary of known third-party profiles with timestamps. Always exactly 1 message.

```lua
-- Wire format (short keys)
{
    t = "G",           -- message type
    e = {              -- entries (array of profile summaries)
        { b = "BattleTag#1234", au = 1738800000, cu = 1738801000, cc = 5 },
        { b = "BattleTag#5678", au = 1738795000, cu = 1738795000, cc = 3 },
    }
}
```

Max 8 entries per digest. Excludes own profile and recipient's profile (already conveyed via MANIFEST).

**GOSSIP_REQUEST** (wire type: `"GR"`):
Request specific profile data from a gossip peer. Sent in response to a digest entry.

```lua
-- Wire format (short keys)
{
    t = "GR",
    b = "BattleTag#1234",    -- which profile to request
    af = 0,                  -- afterTimestamp for chars (0 = full, >0 = delta)
}
```

Responder sends ALIAS_UPDATE + CHARS_UPDATE(s) for the requested profile.

### Short Wire Keys (Sender Side)

The receiver-side `NormalizeKeys` in Protocol.lua already handles both verbose and short keys. This update switches **all senders** to emit short keys, saving ~30-50 bytes per message.

**Changes needed in senders**:
- `AddonMessages.BuildMessage`: `data.t = messageType` instead of `data.type = messageType`
- `Coordinator.SendManifest`: `{b=, a=, cu=, au=}` instead of `{battleTag=, alias=, ...}`
- `Coordinator.SendCharsUpdate`: `{b=, c=, cu=}` with nested `{n=, r=, d=}`
- `Gossip` corrections: same short key treatment
- `HandleRequestChars` response: same short key treatment

**New SHORT_KEY_MAP entries**:
```lua
e  = "entries",      -- GOSSIP_DIGEST entries array
cc = "charsCount",   -- character count for integrity checks
```

### Cross-Session Gossip Tracking (Content-Aware)

**Current**: `lastGossip[senderBattleTag][profileBattleTag] = true` — per-session only, boolean-only, resets on relog.

**New**: Persisted in SavedVariables with **content-aware** tracking. Instead of tracking *when* we gossiped, we track *what data state* we communicated, using the same authoritative timestamps the data owner set.

```lua
EndeavoringDB.global.gossipTracking = {
    ["TargetBTag#1234"] = {                                                  -- who we sent data to
        ["ProfileBTag#5678"] = { au = 1738800000, cu = 1738801000, cc = 5 }, -- what we told them
        ["ProfileBTag#9012"] = { au = 1738795000, cu = 1738795000, cc = 3 },
    }
}
```

**Digest inclusion logic** — when building a digest for target X, for each cached profile:
- `gossipTracking[X][profile]` doesn't exist → **include** (never told them about this profile)
- Local `au > tracked.au` OR local `cu > tracked.cu` → **include** (our data is fresher than what we last told them)
- Local `cc ≠ tracked.cc` (character count mismatch) → **include** (chunk drop detection)
- Otherwise → **skip** (they already know what we know)

After sending the digest, update tracking with the timestamps we included.

**Corrections also update tracking**: If we send a correction (ALIAS_UPDATE or CHARS_UPDATE) back to a peer, update `gossipTracking[peer][profile]` with the corrected timestamps. This prevents redundant re-corrections.

**Inbound digest learning**: When we *receive* a GOSSIP_DIGEST from Player B, each entry tells us what B knows. For each entry where B's timestamps are >= our tracking (or no tracking exists), update `gossipTracking[B][profile]` with B's timestamps. This way, if B already knows about ProfileX at `au=5, cu=7`, we won't include ProfileX in our next digest to B unless we later learn something fresher. Digests become bidirectional state sync for free.

**Exclude target's own profile**: Never include Player A's own profile in a digest sent TO Player A. They are the authority on their own data — we can only learn from them via MANIFEST, never teach them about themselves.

**Benefits over cooldown-based approach**:
- Never sends redundant data — if nothing changed, no digest is sent
- Automatically re-gossips when data updates, with no arbitrary timer
- Persists across relogs — no "re-gossip storm" after a quick relog
- Uses the same authoritative owner-set timestamps — no separate action timestamps
- Simpler reasoning: "have I told them about this data?" vs. "has enough time passed?"

**No time-based cooldown needed**: Since digests are only sent when we have new information, rapid MANIFESTs from the same player naturally produce empty digests (skipped). No dedup timer required.

### Data Model

**Schema addition** (SavedVariables):
```lua
EndeavoringDB.global.gossipTracking = {
    ["TargetBTag#1234"] = {
        ["ProfileBTag#5678"] = { au = 1738800000, cu = 1738801000, cc = 5 },
    }
}
```

- `gossipTracking[target][profile].au` — the `aliasUpdatedAt` we last communicated about this profile to this target
- `gossipTracking[target][profile].cu` — the `charsUpdatedAt` we last communicated about this profile to this target
- `gossipTracking[target][profile].cc` — the character count we last communicated about this profile to this target

**Migration**: `DB.Init()` adds `gossipTracking = {}` if missing. No version bump needed (additive change).

**Cleanup**: Periodically prune entries for targets no longer in guild roster. Can be done lazily during gossip operations or on guild roster update events.

### API Dependencies

No new WoW APIs needed. Uses existing:
- `C_ChatInfo.SendAddonMessage` (WHISPER channel)
- `C_EncodingUtil` (CBOR/Deflate/Base64 via MessageCodec)

### Architecture Changes

| Layer | File | Change |
|-------|------|--------|
| Bootstrap | Bootstrap.lua | Add `GOSSIP_DIGEST` and `GOSSIP_REQUEST` to `MSG_TYPE` |
| Services | AddonMessages.lua | Use short key `t` in `BuildMessage` |
| Data | Database.lua | Add content-aware gossip tracking (read/update/prune) |
| Sync | Coordinator.lua | Use short wire keys in all outbound messages |
| Sync | Gossip.lua | Major rewrite — digest-based exchange |
| Sync | Protocol.lua | Add handlers for new message types, update SHORT_KEY_MAP |

### Sync Protocol Impact

- **New message types**: GOSSIP_DIGEST and GOSSIP_REQUEST added to protocol
- **Existing messages unchanged**: MANIFEST, REQUEST_CHARS, ALIAS_UPDATE, CHARS_UPDATE all work identically
- **Gossip trigger unchanged**: Still triggered by receiving MANIFEST
- **Channel unchanged**: All gossip over WHISPER

### Wire Size Budget (GOSSIP_DIGEST)

Per digest entry (CBOR with short keys):
| Component | Bytes |
|-----------|-------|
| "b" key + BattleTag value | ~20 |
| "au" key + timestamp | ~8 |
| "cu" key + timestamp | ~8 |
| "cc" key + integer | ~4 |
| **Per entry total** | **~40** |

With 8 entries: ~320 bytes raw CBOR
After Deflate (~40% savings from repeating keys): ~192 bytes
After Base64 (+33%): ~256 bytes
Plus envelope (type, entries key): ~15 bytes
**Total: ~271 bytes** — may slightly exceed 255 bytes with 8 long BattleTags.
Dynamic cap will auto-reduce to 7 entries if needed.

### Gossip Flow (New)

```
Player A logs in, broadcasts MANIFEST
          ↓
Player B receives MANIFEST
          ↓
Check tracking: Does B have profiles with newer
timestamps than what B last told A?
  - Compare each cached profile's au/cu against
    gossipTracking[A][profile].au / .cu
  - Only profiles where local > tracked (or no
    tracking entry) qualify for the digest
  - No qualifying profiles → skip gossip entirely
          ↓
Build GOSSIP_DIGEST: entries for qualifying profiles
(exclude own profile, exclude A's profile)
Dynamic entry cap: encode → check ≤ 255 bytes → drop
last entry if over limit → re-encode
          ↓
Send 1 GOSSIP_DIGEST message to Player A (WHISPER)
Update gossipTracking[A][profile] = { au, cu } for
each profile included in the digest
          ↓
Player A receives GOSSIP_DIGEST
          ↓
For each entry in digest:
  Compare against local cache:
  ┌─────────────────────────────┬──────────────────────────────┐
  │ Situation                   │ Action                       │
  ├─────────────────────────────┼──────────────────────────────┤
  │ Profile unknown to A        │ Send GOSSIP_REQUEST (af=0)   │
  │ Digest cu > local cu        │ Send GOSSIP_REQUEST (af=     │
  │                             │   local cu, for delta chars) │
  │ Digest au > local au        │ Send GOSSIP_REQUEST (af=0)   │
  │ cu match, cc > local count  │ Send GOSSIP_REQUEST (af=0)   │
  │                             │   (we're missing chars)      │
  │ cu match, cc < local count  │ Send CHARS_UPDATE correction │
  │                             │   (all chars, they're short) │
  │ Local au > digest au        │ Send ALIAS_UPDATE correction │
  │ Local cu > digest cu        │ Send CHARS_UPDATE correction │
  │                             │   (chars with addedAt >      │
  │                             │    digest cu)                │
  │ Timestamps + count match    │ No action                    │
  └─────────────────────────────┴──────────────────────────────┘
  For ALL entries (not just corrections):
  Update gossipTracking[B][profile] with digest timestamps
  if >= existing tracking. This learns what B knows so we
  don't gossip it back later.
  Corrections also update tracking with corrected values.
          ↓
Player B receives GOSSIP_REQUEST(s)
          ↓
For each request: send ALIAS_UPDATE + CHARS_UPDATE(s)
from cached profile. If af > 0, send only characters
with addedAt > af (delta). If af = 0, send all.
          ↓
Both players now have consistent data ✓
```

### Targeted Corrections (Back-Gossip)

When Player A has **fresher** data than what's in the digest, A sends corrections back:
- `ALIAS_UPDATE` if A's aliasUpdatedAt > digest's aliasUpdatedAt
- `CHARS_UPDATE` with characters added after the digest's charsUpdatedAt

Uses existing `Gossip.CorrectStaleAlias` / `Gossip.CorrectStaleChars` logic.

**Anti-loop**: Per-session tracking prevents sending the same correction twice. Once A corrects B about ProfileX, it won't correct again this session.

### Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| New client → Old client | Sends GOSSIP_DIGEST; old client ignores unknown message type (harmless) |
| Old client → New client | Sends old-style unsolicited gossip; new client processes via existing ALIAS_UPDATE/CHARS_UPDATE handlers |
| New client → New client | Full digest-based handshake |

**Key**: All existing ALIAS_UPDATE and CHARS_UPDATE handlers remain functional. Old-style gossip from v1.0.x clients is still processed correctly. The only "cost" is new clients sending one ignored digest to old clients — a single small message.

## Implementation Phases

### Phase 1: Short Wire Keys (Simple)
Switch all senders to short keys. No behavioral change — pure optimization.

- [ ] **Update `AddonMessages.BuildMessage`** (Simple) — Change `data.type = messageType` to `data.t = messageType`. Note: this mutates the caller's data table, which is intentional — callers construct a fresh table per message.
  - Files: [AddonMessages.lua](../../Endeavoring/Services/AddonMessages.lua)
- [ ] **Update `Coordinator.SendManifest`** (Simple) — Use short keys `{b=, a=, cu=, au=, cc=}`
  - Files: [Coordinator.lua](../../Endeavoring/Sync/Coordinator.lua)
- [ ] **Update `Coordinator.SendCharsUpdate`** (Simple) — Use short keys `{b=, c=, cu=}` with nested `{n=, r=, d=}`
  - Files: [Coordinator.lua](../../Endeavoring/Sync/Coordinator.lua)
- [ ] **Update gossip corrections** (Simple) — Short keys in `CorrectStaleAlias` and `CorrectStaleChars`
  - Files: [Gossip.lua](../../Endeavoring/Sync/Gossip.lua)
- [ ] **Update `HandleRequestChars` response** (Simple) — Short keys in CHARS_UPDATE response
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)
- [ ] **Validate**: All existing message flows work with short keys (receiver normalizes via `NormalizeKeys`)
  - Dependencies: None (receiver already supports short keys)

### Phase 2: Database & Tracking Foundation (Simple)
Add persistence layer for content-aware gossip tracking.

- [ ] **Add gossip tracking to DB schema** (Simple) — `gossipTracking` nested table in SavedVariables
  - Files: [Database.lua](../../Endeavoring/Data/Database.lua)
  - Functions:
    - `DB.GetGossipTracking(targetBattleTag)` → returns `{ [profileBTag] = { au, cu } }` or `{}`
    - `DB.UpdateGossipTracking(targetBattleTag, profileBattleTag, au, cu, cc)` → records what we told them
    - `DB.PruneGossipTracking(validBattleTags)` → removes entries for targets not in provided set
- [ ] **Initialize gossipTracking in `DB.Init()`** (Simple) — Additive migration, no version bump
  - Files: [Database.lua](../../Endeavoring/Data/Database.lua)
- [ ] **Add new MSG_TYPE entries** (Simple) — `GOSSIP_DIGEST = "G"`, `GOSSIP_REQUEST = "GR"`
  - Files: [Bootstrap.lua](../../Endeavoring/Bootstrap.lua)
- [ ] **Update SHORT_KEY_MAP** (Simple) — Add `e = "entries"`, `cc = "charsCount"` mappings
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)
  - Dependencies: Phase 1 complete

### Phase 3: Digest Protocol (Complex)
Core gossip protocol rewrite.

- [ ] **Implement `Gossip.BuildDigest`** (Medium) — Build compact digest from cached profiles
  - Files: [Gossip.lua](../../Endeavoring/Sync/Gossip.lua)
  - Logic: For each cached profile (skip own + target), compare local `au`/`cu`/`cc` against `DB.GetGossipTracking(target)[profile]`. Include only profiles where local data is fresher, count differs, or no tracking entry exists. Each entry includes `{b, au, cu, cc}`. Dynamic entry cap: encode, check ≤ 255 bytes, drop last entry if over limit. Log entry count + encoded size via DebugPrint for observability.
  - Dependencies: Phase 2 (MSG_TYPE, SHORT_KEY_MAP, DB tracking)
- [ ] **Implement `Gossip.SendDigest`** (Medium) — Replace `SendProfilesToPlayer` with digest send
  - Files: [Gossip.lua](../../Endeavoring/Sync/Gossip.lua)
  - Logic: Call `BuildDigest`, skip if empty (no new info for target), send via WHISPER, update `DB.UpdateGossipTracking` for each included entry
  - Dependencies: `BuildDigest`, DB tracking functions
- [ ] **Implement `HandleGossipDigest`** (Complex) — Process received digest, compare timestamps, learn sender's state
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)
  - Logic: For each entry:
    - Request if we need data (unknown profile, digest has newer timestamps, or digest `cc > local count` with matching `cu`)
    - Send correction if we have fresher data OR our `count > digest cc` with matching `cu` (they dropped chunks)
    - **Update `gossipTracking[sender][profile]`** with the digest's `au`/`cu`/`cc` (if >= our tracking). This learns what the sender knows, so we don't gossip the same info back to them later.
  - Dependencies: `Gossip.SendProfile`, `Gossip.CorrectStaleAlias/Chars`, DB tracking functions
- [ ] **Implement `Gossip.SendProfile`** (Medium) — Send single profile data on request
  - Files: [Gossip.lua](../../Endeavoring/Sync/Gossip.lua)
  - Logic: Extract from `SendProfilesToPlayer` inner loop — send ALIAS_UPDATE + CHARS_UPDATE for one profile
  - Dependencies: Existing `Coordinator.SendCharsUpdate`
- [ ] **Implement `HandleGossipRequest`** (Medium) — Respond to GOSSIP_REQUEST with profile data
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)
  - Logic: Look up requested profile in DB, call `Gossip.SendProfile`, support delta via afterTimestamp
  - Dependencies: `Gossip.SendProfile`
- [ ] **Update `HandleManifest`** (Simple) — Call `Gossip.SendDigest` instead of `Gossip.SendProfilesToPlayer`. Also compare MANIFEST `cc` against local character count — if `cu` matches but counts differ, request full resync (`af=0`).
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)
  - Dependencies: `Gossip.SendDigest`
- [ ] **Update `RouteMessage`** (Simple) — Add routing for GOSSIP_DIGEST and GOSSIP_REQUEST
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)

### Phase 4: Polish & Cleanup (Simple-Medium)
Production-readiness, backward compat validation, docs.

- [ ] **Keep old ALIAS_UPDATE/CHARS_UPDATE gossip handlers** (Simple) — Backward compat with v1.0.x
  - Files: [Protocol.lua](../../Endeavoring/Sync/Protocol.lua)
  - Verify: Old-style gossip messages still processed correctly by existing handlers
- [ ] **Replace old per-session tracking** (Simple) — Remove `lastGossip` table; rename `MarkKnownProfile` → `MarkCorrectionSent`, `HasGossipedProfile` → `HasSentCorrection` (anti-loop for corrections)
  - Files: [Gossip.lua](../../Endeavoring/Sync/Gossip.lua)
- [ ] **Add gossip tracking pruning** (Simple) — Prune `gossipTracking` entries for targets no longer in guild roster. Call `DB.PruneGossipTracking(currentGuildBattleTags)` on guild roster update events.
  - Files: [Database.lua](../../Endeavoring/Data/Database.lua), [Core.lua](../../Endeavoring/Core.lua)
- [ ] **Update debug commands** (Simple) — `/endeavoring sync gossip` shows digest stats
  - Files: [Commands.lua](../../Endeavoring/Commands.lua), [Gossip.lua](../../Endeavoring/Sync/Gossip.lua)
- [ ] **Update unit tests** (Medium) — Protocol_spec.lua for new message types
  - Files: [Protocol_spec.lua](../../Endeavoring_spec/Sync/Protocol_spec.lua)
- [ ] **Update documentation** (Simple) — sync-protocol.md, message-codec.md, architecture.md
  - Files: `.github/docs/sync-protocol.md`, `.github/docs/message-codec.md`, `.github/docs/development-status.md`

## Risks & Mitigations

### Technical Risks

- **Digest message size exceeding 255 bytes** — With 8 entries, estimated at ~245 bytes. Close to limit.
  → Mitigation: Dynamic entry cap — encode the digest, check `#encoded ≤ 255`, drop last entry and re-encode if over. DebugPrint logs entry count + size for ongoing observability. If we consistently see low counts, lower the starting cap.

- **Old clients silently lose gossip from new clients** — New clients send digests that old clients ignore.
  → Mitigation: Acceptable trade-off. Old clients still get direct sync (MANIFEST/REQUEST_CHARS) and still receive gossip from other old clients. Upgrade path is natural.

- **Correction ping-pong** — A corrects B, B corrects A back, infinite loop.
  → Mitigation: Two layers. (1) `MarkCorrectionSent(B, X)` per-session flag prevents re-correction. (2) Corrections update `gossipTracking[B][X]` with the corrected timestamps, so the next digest build won't re-include that entry unless data changes again.

- **gossipTracking growth** — Nested table could grow with many guild members.
  → Mitigation: Bounded by (guild size × guild size) which is small. Pruning on guild roster updates removes stale entries for departed members.

### UX Risks

- **None visible to users** — This is entirely a behind-the-scenes protocol optimization. No UI changes.

### Scope Risks

- **Digest pagination for very large guilds** — If >8 addon users exist, some profiles won't be included in a single digest.
  → Mitigation: Round-robin or prioritize recently updated profiles. 8 profiles per digest × multiple MANIFESTs over time = full coverage. Can add multi-message digests later if needed.

## Testing Approach

### Manual Testing

1. **Verify short wire keys** — Enable debug mode, check that outbound messages use short keys. Verify other addon users still receive and process messages correctly.
2. **Verify digest sending** — With 2+ addon users online, check debug output for GOSSIP_DIGEST with entry count and encoded size. Confirm digest only sent when sender has new information for the target.
3. **Verify content-aware dedup** — Trigger multiple MANIFESTs from same player rapidly. Confirm only the first digest is sent; subsequent ones are skipped (no new data since tracking was updated).
4. **Verify cross-session tracking** — Relog and confirm digest is NOT re-sent to same player (tracking persists in SavedVariables). Then update a profile and confirm digest IS re-sent with only the changed entry.
5. **Verify digest receiving** — Confirm GOSSIP_REQUESTs are sent only for profiles the receiver actually needs. Verify delta requests (`af > 0`) return only characters with `addedAt` after that timestamp.
6. **Verify targeted corrections** — Have two clients with intentionally different profile timestamps. Confirm the client with fresher data sends corrections back. Confirm corrections update `gossipTracking` to prevent re-corrections.
7. **Verify backward compat** — Test with one v1.0.x client and one updated client. Confirm old-style gossip is still processed. Confirm the updated client's digest is harmlessly ignored by old client.
8. **Throttle test** — With 5+ addon users, monitor for `AddonMessageThrottle` errors. Should be dramatically reduced or eliminated.

### Edge Cases

- Player with 0 cached profiles (fresh install) — skip digest entirely (nothing to communicate)
- Player whose only cached profile is the MANIFEST sender — skip digest (nothing relevant)
- All cached profiles already communicated to target — skip digest (tracking timestamps match)
- Digest entry for a profile the sender has since purged — request comes back empty, handle gracefully
- Multiple rapid MANIFESTs from same player — content-aware tracking deduplicates naturally

## Open Questions

- [ ] **Digest entry cap**: 8 entries fits within 255 bytes in theory — validate with real CBOR/Deflate/Base64 encoding in-game (sizes can vary with actual BattleTag lengths). Dynamic cap will self-correct, but monitor debug output to see if starting cap should be lowered.
- [ ] **Correction anti-loop sufficiency**: Corrections use per-session `MarkCorrectionSent` + persisted `gossipTracking` updates. Verify this two-layer approach prevents all ping-pong scenarios.
- [ ] **Should digest include profile entry count?** A "total known profiles" field could help the receiver assess coverage. Low priority — can add later.

## Next Steps

1. **Phase 1**: Switch all senders to short wire keys (can be done as a standalone PR)
2. **Phase 2**: Add DB tracking + new MSG_TYPE entries
3. **Phase 3**: Implement digest protocol (core PR)
4. **Phase 4**: Polish, tests, documentation
