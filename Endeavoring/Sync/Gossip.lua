---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local Gossip = {}
ns.Gossip = Gossip

-- Shortcuts
local DebugPrint = ns.DebugPrint
local ChatType = ns.AddonMessages.ChatType
local SK = ns.SK

--[[
Gossip Protocol v2 - Digest-Based Exchange

PURPOSE:
Implements gossip-based profile propagation using compact digest messages.
Instead of pushing full profile data unsolicited, we send a summary of what
we know (a "digest") and let the receiver request only what they need.

BENEFITS:
- Dramatically reduces message volume (1 digest vs 3-15+ unsolicited messages)
- Content-aware tracking persists across sessions (no re-gossip storm on relog)
- Receivers request only data they're actually missing
- Bidirectional state sync: digests tell us what the sender knows too
- Self-healing via targeted corrections (stale data triggers back-gossip)

DIGEST FLOW:
1. Receive MANIFEST from Player A
2. Build digest: compact summary of profiles we know about (with timestamps)
3. Send 1 GOSSIP_DIGEST message to Player A
4. Player A compares digest entries against local cache
5. Player A sends GOSSIP_REQUESTs for profiles they need
6. We respond with ALIAS_UPDATE + CHARS_UPDATE for each request

TRACKING:
Content-aware tracking in SavedVariables via DB.gossipTracking:
  gossipTracking[targetBTag][profileBTag] = { au, cu, cc }
Records what data state we last communicated to each target.
Only re-includes profiles in digests when our data is fresher.

CORRECTION ANTI-LOOP:
Per-session MarkCorrectionSent/HasSentCorrection prevents repeated
corrections within a session. Corrections also update gossipTracking.
--]]

-- Configuration
local MAX_DIGEST_ENTRIES = 7 -- Starting cap, dynamically reduced if encoding exceeds 255 bytes
local MESSAGE_SIZE_LIMIT = 255 -- WoW API hard limit
local MSG_TYPE = ns.MSG_TYPE -- Shared message type enum

-- State
-- Per-session correction tracking to prevent correction ping-pong
-- correctionsSent[targetBattleTag][profileBattleTag] = true
local correctionsSent = {}

--- Initialize correction tracking for a player
--- @param battleTag string The BattleTag to initialize tracking for
local function InitializeCorrectionTracking(battleTag)
	if not correctionsSent[battleTag] then
		correctionsSent[battleTag] = {}
	end
end

--- Mark that we've sent a correction about a profile to a player (anti-loop)
--- @param targetBattleTag string The BattleTag of the player we corrected
--- @param profileBattleTag string The BattleTag of the profile we corrected
function Gossip.MarkCorrectionSent(targetBattleTag, profileBattleTag)
	InitializeCorrectionTracking(targetBattleTag)
	correctionsSent[targetBattleTag][profileBattleTag] = true
end

--- Check if we've already sent a correction about a profile to a player this session
--- @param targetBattleTag string The BattleTag we might correct
--- @param profileBattleTag string The profile BattleTag we might correct
--- @return boolean hasSent Whether we've already sent this correction
function Gossip.HasSentCorrection(targetBattleTag, profileBattleTag)
	return correctionsSent[targetBattleTag] and correctionsSent[targetBattleTag][profileBattleTag] or false
end

--- Build a compact digest of known third-party profiles for a target player.
--- Each entry contains timestamps and character count so the receiver can
--- determine what they need to request or correct.
--- @param targetBattleTag string The BattleTag of the player we're building the digest for
--- @return table entries Array of digest entries (may be empty)
function Gossip.BuildDigest(targetBattleTag)
	local myBattleTag = ns.DB.GetMyBattleTag()
	local allProfiles = ns.DB.GetAllProfiles()
	local tracking = ns.DB.GetGossipTracking(targetBattleTag)

	-- Collect candidates: profiles where our data is fresher than what we last told the target
	local candidates = {}
	for battleTag, profile in pairs(allProfiles) do
		-- Skip our own profile and the target's profile
		if battleTag ~= myBattleTag and battleTag ~= targetBattleTag then
			local localAu = profile.aliasUpdatedAt or 0
			local localCu = profile.charsUpdatedAt or 0
			local localCc = ns.DB.GetCharacterCount(profile)
			local tracked = tracking[battleTag]

			local shouldInclude = false
			if not tracked then
				-- Never told them about this profile
				shouldInclude = true
			elseif localAu > (tracked.au or 0) then
				-- Our alias data is fresher
				shouldInclude = true
			elseif localCu > (tracked.cu or 0) then
				-- Our character data is fresher
				shouldInclude = true
			elseif localCc ~= (tracked.cc or 0) then
				-- Character count mismatch (chunk drop detection)
				shouldInclude = true
			end

			if shouldInclude then
				table.insert(candidates, {
					battleTag = battleTag,
					au = localAu,
					cu = localCu,
					cc = localCc,
					-- Sort key: most recently updated first
					lastUpdate = math.max(localAu, localCu),
				})
			end
		end
	end

	-- Sort by most recently updated first
	table.sort(candidates, function(a, b)
		return a.lastUpdate > b.lastUpdate
	end)

	-- Build entries array (up to MAX_DIGEST_ENTRIES)
	local entries = {}
	for i = 1, math.min(MAX_DIGEST_ENTRIES, #candidates) do
		local c = candidates[i]
		table.insert(entries, {
			[SK.battleTag] = c.battleTag,
			[SK.aliasUpdatedAt] = c.au,
			[SK.charsUpdatedAt] = c.cu,
			[SK.charsCount] = c.cc,
		})
	end

	-- Dynamic size cap: encode and trim if over 255 bytes
	-- Include our BattleTag so the receiver can identify us without CharacterCache
	while #entries > 0 do
		local digestData = {
			[SK.battleTag] = myBattleTag,
			[SK.entries] = entries,
		}
		local encoded = ns.AddonMessages.BuildMessage(MSG_TYPE.GOSSIP_DIGEST, digestData)
		if encoded and #encoded <= MESSAGE_SIZE_LIMIT then
			DebugPrint(
				string.format("BuildDigest: %d entries, %d bytes (of %d candidates)", #entries, #encoded, #candidates)
			)
			return entries
		end
		-- Over limit — drop last entry and retry
		table.remove(entries)
		DebugPrint(
			string.format("BuildDigest: trimmed to %d entries (over %d byte limit)", #entries, MESSAGE_SIZE_LIMIT),
			"ff8800"
		)
	end

	return entries
end

--- Send a gossip digest to a target player.
--- Replaces the old SendProfilesToPlayer approach with a single compact message.
--- @param targetBattleTag string The BattleTag to send the digest to
--- @param targetCharacter string The character name to send the whisper to
function Gossip.SendDigest(targetBattleTag, targetCharacter)
	local entries = Gossip.BuildDigest(targetBattleTag)

	if #entries == 0 then
		DebugPrint(string.format("No new gossip for %s, skipping digest", targetBattleTag))
		return
	end

	local myBattleTag = ns.DB.GetMyBattleTag()
	local digestData = {
		[SK.battleTag] = myBattleTag,
		[SK.entries] = entries,
	}
	local message = ns.AddonMessages.BuildMessage(MSG_TYPE.GOSSIP_DIGEST, digestData)
	if not message then
		DebugPrint("Failed to build GOSSIP_DIGEST message", "ff0000")
		return
	end

	ns.AddonMessages.SendMessage(message, ChatType.Whisper, targetCharacter)
	DebugPrint(
		string.format("Sent GOSSIP_DIGEST with %d entries to %s (%s)", #entries, targetBattleTag, targetCharacter)
	)

	-- Update content-aware tracking for each entry we included
	for _, entry in ipairs(entries) do
		local profileBTag = entry[SK.battleTag]
		local au = entry[SK.aliasUpdatedAt]
		local cu = entry[SK.charsUpdatedAt]
		local cc = entry[SK.charsCount]
		ns.DB.UpdateGossipTracking(targetBattleTag, profileBTag, au, cu, cc)
	end
end

--- Send a single profile's data (alias + characters) to a target player.
--- Used when responding to GOSSIP_REQUEST messages.
--- @param targetCharacter string The character name to send to
--- @param profileBattleTag string The BattleTag of the profile to send
--- @param afterTimestamp number Only send characters with addedAt > this (0 for all)
function Gossip.SendProfile(targetCharacter, profileBattleTag, afterTimestamp)
	local profile = ns.DB.GetProfile(profileBattleTag)
	if not profile then
		DebugPrint(string.format("SendProfile: profile %s not found", profileBattleTag), "ff8800")
		return
	end

	-- Send alias update
	local aliasData = {
		[SK.battleTag] = profileBattleTag,
		[SK.alias] = profile.alias,
		[SK.aliasUpdatedAt] = profile.aliasUpdatedAt,
	}
	local aliasMessage = ns.AddonMessages.BuildMessage(MSG_TYPE.ALIAS_UPDATE, aliasData)
	if aliasMessage then
		ns.AddonMessages.SendMessage(aliasMessage, ChatType.Whisper, targetCharacter)
	end

	-- Build characters list (with optional delta filtering)
	local characters = {}
	if profile.characters then
		for _, char in pairs(profile.characters) do
			if afterTimestamp == 0 or (char.addedAt and char.addedAt > afterTimestamp) then
				table.insert(characters, {
					[SK.name] = char.name,
					[SK.realm] = char.realm or "",
					[SK.addedAt] = char.addedAt,
				})
			end
		end
	end

	if #characters > 0 then
		ns.Coordinator.SendCharsUpdate(
			profileBattleTag,
			characters,
			profile.charsUpdatedAt or 0,
			ChatType.Whisper,
			targetCharacter
		)
	end

	DebugPrint(
		string.format(
			"SendProfile: sent %s (%s) with %d chars (after=%d) to %s",
			profileBattleTag,
			profile.alias,
			#characters,
			afterTimestamp,
			targetCharacter
		)
	)
end

--- Send alias correction when we detect sender has stale data
--- Part of bidirectional gossip correction protocol
--- @param sender string Character name of the sender
--- @param battleTag string BattleTag of the profile being corrected
--- @param correctAlias string The correct/newer alias
--- @param correctTimestamp number The correct aliasUpdatedAt timestamp
function Gossip.CorrectStaleAlias(sender, battleTag, correctAlias, correctTimestamp)
	local aliasData = {
		[SK.battleTag] = battleTag,
		[SK.alias] = correctAlias,
		[SK.aliasUpdatedAt] = correctTimestamp,
	}
	local message = ns.AddonMessages.BuildMessage(MSG_TYPE.ALIAS_UPDATE, aliasData)
	if message then
		ns.AddonMessages.SendMessage(message, ChatType.Whisper, sender)
		DebugPrint(string.format("Sent updated alias for %s back to %s", battleTag, sender))
	end
end

--- Send character correction when we detect sender has stale data
--- Part of bidirectional gossip correction protocol
--- @param sender string Character name of the sender
--- @param battleTag string BattleTag of the profile being corrected
--- @param correctTimestamp number The correct charsUpdatedAt timestamp
--- @param senderTimestamp number The sender's (stale) timestamp
function Gossip.CorrectStaleChars(sender, battleTag, correctTimestamp, senderTimestamp)
	-- Send all characters added after their timestamp
	local newerChars = ns.DB.GetProfileCharactersAddedAfter(battleTag, senderTimestamp)

	if #newerChars > 0 then
		ns.Coordinator.SendCharsUpdate(battleTag, newerChars, correctTimestamp, ChatType.Whisper, sender)
		DebugPrint(string.format("Sent %d updated character(s) for %s back to %s", #newerChars, battleTag, sender))
	end
end

--- Get gossip statistics for debugging
--- @return table stats Gossip statistics including digest tracking info
function Gossip.GetStats()
	local totalCorrections = 0
	local correctionsByPlayer = {}

	for playerBattleTag, profiles in pairs(correctionsSent) do
		local profileCount = 0
		for _ in pairs(profiles) do
			profileCount = profileCount + 1
			totalCorrections = totalCorrections + 1
		end
		if profileCount > 0 then
			correctionsByPlayer[playerBattleTag] = profileCount
		end
	end

	return {
		totalCorrections = totalCorrections,
		correctionsByPlayer = correctionsByPlayer,
	}
end
