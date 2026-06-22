---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

--- Protocol Module
--- Handles incoming addon messages and routes them to appropriate handlers.
---
--- Responsibilities:
--- - Parse and validate incoming messages
--- - Route messages to type-specific handlers
--- - Process MANIFEST, REQUEST_CHARS, ALIAS_UPDATE, CHARS_UPDATE messages
--- - Implement bidirectional gossip correction (detect and fix stale data)
--- - Update database and character cache based on received data
---
--- Public API:
--- - Protocol.OnAddonMessage(prefix, message, channel, sender) - Entry point for incoming messages
---
--- Dependencies:
--- - ns.MessageCodec - Message encoding/decoding
--- - ns.AddonMessages - Low-level message building and sending (BuildMessage, SendMessage)
--- - ns.DB - Database access for profiles and characters
--- - ns.CharacterCache - Character name → BattleTag lookups
--- - ns.Coordinator - Character list chunking (SendCharsUpdate)
--- - ns.Gossip - Opportunistic profile propagation
---
--- Usage:
---   -- In AddonMessages.RegisterListener():
---   frame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
---     if event == "CHAT_MSG_ADDON" then
---       ns.Protocol.OnAddonMessage(prefix, message, channel, sender)
---     end
---   end)

local Protocol = {}
ns.Protocol = Protocol

-- Shortcuts
local DebugPrint = ns.DebugPrint
local ChatType = ns.AddonMessages.ChatType
local ERROR = ns.Constants.PREFIX_ERROR
local SK = ns.SK

-- Constants
local ADDON_PREFIX = "Ndvrng"
local MSG_TYPE = ns.MSG_TYPE -- Shared message type enum

--[[
Short Wire Keys

All outbound messages use short CBOR keys (e.g. "b" instead of "battleTag")
to save wire bytes. The canonical mapping is defined in Bootstrap.lua as ns.SK
(verbose → short). This table inverts it (short → verbose) so the receiver
can normalize incoming messages back to verbose keys for internal use.

Both short and verbose keys are accepted, ensuring backward compatibility
with older clients that may still send verbose keys.
--]]
local SHORT_KEY_MAP = {}
for verbose, short in pairs(ns.SK) do
	SHORT_KEY_MAP[short] = verbose
end

--- Normalize message keys from short format to verbose format.
--- Recursively walks tables so nested character objects are also normalized.
--- Verbose keys pass through unchanged, so both formats are accepted.
--- @param data any The decoded message data (or nested value)
--- @return any normalized The data with verbose keys
local function NormalizeKeys(data)
	if type(data) ~= "table" then
		return data
	end

	local normalized = {}
	for key, value in pairs(data) do
		local normalizedKey = (type(key) == "string" and SHORT_KEY_MAP[key]) or key
		normalized[normalizedKey] = NormalizeKeys(value)
	end
	return normalized
end

--- Parse an encoded message and extract message type
--- Message type is embedded in the CBOR payload
--- @param encoded string The encoded message
--- @return MessageType|nil messageType The message type
--- @return table|nil data The decoded message data (including type field)
local function ParseMessage(encoded)
	---@diagnostic disable-next-line: param-type-mismatch
	if issecretvalue(encoded) or not encoded or encoded == "" then
		return nil, nil
	end

	-- Decode the CBOR payload
	local data, err = ns.MessageCodec.Decode(encoded)
	if not data then
		DebugPrint(string.format("Failed to decode message: %s", err or "unknown error"), "ff0000")
		return nil, nil
	end

	-- Normalize short keys to verbose keys (forward compatibility)
	data = NormalizeKeys(data)

	-- Extract message type from decoded data
	local messageType = data.type
	if not messageType or messageType == "" then
		DebugPrint("Message missing type field", "ff0000")
		return nil, nil
	end

	return messageType, data
end

--- Validate a BattleTag format
--- @param battleTag string The BattleTag to validate
--- @return boolean valid Whether the BattleTag is valid
local function ValidateBattleTag(battleTag)
	if not battleTag or battleTag == "" then
		return false
	end

	-- BattleTag format: Name#1234 (name can have spaces in some regions)
	return string.match(battleTag, ".+#%d+") ~= nil
end

--- Validate a timestamp is reasonable
--- @param timestamp number The timestamp to validate
--- @return boolean valid Whether the timestamp is valid
local function ValidateTimestamp(timestamp)
	if not timestamp or type(timestamp) ~= "number" then
		print(ERROR .. " Invalid timestamp")
		return false
	end

	-- Reasonable range: 2020-01-01 to 2040-01-01
	local MIN_TIMESTAMP = 1577836800 -- 2020-01-01
	local MAX_TIMESTAMP = 2209032000 -- 2040-01-01

	return timestamp >= MIN_TIMESTAMP and timestamp <= MAX_TIMESTAMP
end

--- Handle incoming MANIFEST message (CBOR format)
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function HandleManifest(sender, data)
	if not data then
		return
	end

	local battleTag = data.battleTag
	local alias = data.alias
	local charsUpdatedAt = data.charsUpdatedAt
	local aliasUpdatedAt = data.aliasUpdatedAt
	local charsCount = data.charsCount -- May be nil from old clients

	-- Validate message data
	if not ValidateBattleTag(battleTag) then
		return
	end

	if
		not charsUpdatedAt
		or not aliasUpdatedAt
		or not ValidateTimestamp(charsUpdatedAt)
		or not ValidateTimestamp(aliasUpdatedAt)
	then
		return
	end

	-- Ignore our own manifests
	local myBattleTag = ns.DB.GetMyBattleTag()
	if battleTag == myBattleTag then
		return
	end

	-- Get cached profile to compare timestamps
	local cachedProfile = ns.DB.GetProfile(battleTag)
	local needsChars = false
	local afterTimestamp = 0

	if not cachedProfile then
		-- New player, request characters and update alias
		needsChars = true
		afterTimestamp = 0
		ns.DB.UpdateProfileAlias(battleTag, alias, aliasUpdatedAt)
	else
		-- Check if alias is newer
		if aliasUpdatedAt > (cachedProfile.aliasUpdatedAt or 0) then
			ns.DB.UpdateProfileAlias(battleTag, alias, aliasUpdatedAt)
		end

		-- Check if characters are newer
		if charsUpdatedAt > (cachedProfile.charsUpdatedAt or 0) then
			needsChars = true
			afterTimestamp = cachedProfile.charsUpdatedAt or 0
		elseif charsCount and charsUpdatedAt == (cachedProfile.charsUpdatedAt or 0) then
			-- Same timestamp but check character count for chunk drop detection
			local localCount = ns.DB.GetCharacterCount(cachedProfile)
			if charsCount > localCount then
				-- They have more characters — we lost chunks, request full resync
				DebugPrint(
					string.format(
						"MANIFEST cc mismatch for %s: manifest=%d, local=%d — requesting full resync",
						battleTag,
						charsCount,
						localCount
					)
				)
				needsChars = true
				afterTimestamp = 0
			end
		end
	end

	-- Request characters if needed
	if needsChars then
		local requestData = {
			[SK.battleTag] = battleTag,
			[SK.afterTimestamp] = afterTimestamp,
		}
		local message = ns.AddonMessages.BuildMessage(MSG_TYPE.REQUEST_CHARS, requestData)
		if message then
			DebugPrint(string.format("Sending REQUEST_CHARS to %s (after: %d)", battleTag, afterTimestamp))
			ns.AddonMessages.SendMessage(message, ChatType.Whisper, sender)
		end
	end

	-- Gossip Protocol: send digest instead of unsolicited profiles
	ns.Gossip.SendDigest(battleTag, sender)
end

--- Handle incoming REQUEST_CHARS message (CBOR format)
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function HandleRequestChars(sender, data)
	if not data then
		return
	end

	local battleTag = data.battleTag
	local afterTimestamp = data.afterTimestamp

	DebugPrint(string.format("Received REQUEST_CHARS from %s for %s (after: %d)", sender, battleTag, afterTimestamp))

	-- Only respond if they're asking about us
	local myBattleTag = ns.DB.GetMyBattleTag()
	if battleTag ~= myBattleTag then
		DebugPrint(
			string.format("REQUEST_CHARS not for us (ours: %s, requested: %s)", myBattleTag or "nil", battleTag),
			"ff8800"
		)
		return
	end

	if not afterTimestamp or (not ValidateTimestamp(afterTimestamp) and afterTimestamp ~= 0) then
		print(ERROR .. " Invalid timestamp")
		return
	end

	-- Get characters to send
	local characters = ns.DB.GetCharactersAddedAfter(afterTimestamp)
	if #characters == 0 then
		DebugPrint("No characters to send", "ff0000")
		return
	end

	-- Build characters array
	local chars = {}
	for _, char in ipairs(characters) do
		table.insert(chars, {
			[SK.name] = char.name,
			[SK.realm] = char.realm or "",
			[SK.addedAt] = char.addedAt,
		})
	end

	-- Send CHARS_UPDATE (with chunking if needed)
	local myProfile = ns.DB.GetMyProfile()
	if not myProfile then
		return
	end

	DebugPrint(string.format("Sending CHARS_UPDATE (%d chars total) to %s", #chars, sender))
	ns.Coordinator.SendCharsUpdate(myProfile.battleTag, chars, myProfile.charsUpdatedAt, ChatType.Whisper, sender)
end

--- Handle incoming ALIAS_UPDATE message (CBOR format)
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function HandleAliasUpdate(sender, data)
	if not data then
		return
	end

	local battleTag = data.battleTag
	local alias = data.alias
	local aliasUpdatedAt = data.aliasUpdatedAt

	if not ValidateBattleTag(battleTag) or not alias or not aliasUpdatedAt or not ValidateTimestamp(aliasUpdatedAt) then
		return
	end

	-- Don't allow updates to our own profile
	local myBattleTag = ns.DB.GetMyBattleTag()
	if battleTag == myBattleTag then
		return
	end

	-- Try to identify sender's BattleTag for gossip tracking
	local senderBattleTag = ns.CharacterCache.FindBattleTag(sender)

	-- Check if we have this profile and if it's stale
	local existingProfile = ns.DB.GetProfile(battleTag)
	if existingProfile then
		-- Bidirectional correction: if sender has stale data, gossip back the correct version
		if existingProfile.aliasUpdatedAt and existingProfile.aliasUpdatedAt > aliasUpdatedAt then
			DebugPrint(
				string.format(
					"Sender has stale alias for %s (theirs: %d, ours: %d), gossiping back",
					battleTag,
					aliasUpdatedAt,
					existingProfile.aliasUpdatedAt
				)
			)

			if senderBattleTag then
				ns.Gossip.CorrectStaleAlias(sender, battleTag, existingProfile.alias, existingProfile.aliasUpdatedAt)
			end
			return -- Don't update with stale data
		end
	end

	-- Update alias in database
	local success = ns.DB.UpdateProfileAlias(battleTag, alias, aliasUpdatedAt)
	if success then
		DebugPrint(string.format("Updated alias for %s to '%s'", battleTag, alias))
		ns.API.RequestActivityLog() -- Refresh activity log to show updated alias
	end
end

--- Handle incoming CHARS_UPDATE message (CBOR format)
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function HandleCharsUpdate(sender, data)
	if not data then
		return
	end

	local battleTag = data.battleTag
	local characters = data.characters or {}
	local senderCharsUpdatedAt = data.charsUpdatedAt or 0

	if not ValidateBattleTag(battleTag) then
		return
	end

	-- Don't allow updates to our own profile
	local myBattleTag = ns.DB.GetMyBattleTag()
	if battleTag == myBattleTag then
		return
	end

	-- Try to identify sender's BattleTag for gossip tracking
	local senderBattleTag = ns.CharacterCache.FindBattleTag(sender)

	-- Check if we have this profile
	local existingProfile = ns.DB.GetProfile(battleTag)
	if existingProfile then
		-- Bidirectional correction: if sender has stale data, gossip back the correct version
		if existingProfile.charsUpdatedAt and existingProfile.charsUpdatedAt > senderCharsUpdatedAt then
			DebugPrint(
				string.format(
					"Sender has stale characters for %s (theirs: %d, ours: %d), gossiping back",
					battleTag,
					senderCharsUpdatedAt,
					existingProfile.charsUpdatedAt
				)
			)

			if senderBattleTag then
				ns.Gossip.CorrectStaleChars(sender, battleTag, existingProfile.charsUpdatedAt, senderCharsUpdatedAt)
			end
		end
	end

	-- Validate and add characters
	local validChars = {}
	for _, char in ipairs(characters) do
		if char.name and char.name ~= "" and char.addedAt and ValidateTimestamp(char.addedAt) then
			table.insert(validChars, {
				name = char.name,
				realm = char.realm or "",
				addedAt = char.addedAt,
			})
		end
	end

	if #validChars > 0 then
		local success = ns.DB.AddCharactersToProfile(battleTag, validChars)
		if success then
			DebugPrint(string.format("Updated %d character(s) for %s", #validChars, battleTag))
			-- Invalidate cache since we added characters
			ns.CharacterCache.Invalidate(battleTag)
			ns.API.RequestActivityLog() -- Refresh activity log to show updated characters
		end
	end
end

--- Handle incoming GOSSIP_DIGEST message
--- Compares each entry against local cache and either requests missing data,
--- sends corrections for stale data, or does nothing if timestamps match.
--- Also learns the sender's knowledge state to avoid redundant future digests.
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function HandleGossipDigest(sender, data)
	if not data then
		return
	end

	local entries = data.entries
	if not entries or type(entries) ~= "table" or #entries == 0 then
		return
	end

	-- Identify sender's BattleTag — prefer the BattleTag included in the message,
	-- fall back to CharacterCache lookup for older clients that don't include it
	local senderBattleTag = data.battleTag or ns.CharacterCache.FindBattleTag(sender)
	if not senderBattleTag then
		DebugPrint(string.format("GOSSIP_DIGEST from %s: cannot identify sender BattleTag, ignoring", sender), "ff8800")
		return
	end

	local myBattleTag = ns.DB.GetMyBattleTag()

	DebugPrint(
		string.format("Processing GOSSIP_DIGEST from %s (%s) with %d entries", sender, senderBattleTag, #entries)
	)

	for _, entry in ipairs(entries) do
		local profileBTag = entry.battleTag
		local digestAu = entry.aliasUpdatedAt or 0
		local digestCu = entry.charsUpdatedAt or 0
		local digestCc = entry.charsCount or 0

		if not profileBTag or not ValidateBattleTag(profileBTag) then
			DebugPrint("GOSSIP_DIGEST entry missing or invalid battleTag, skipping", "ff8800")
		elseif profileBTag == myBattleTag then
			-- Skip entries about us — we're the authority on our own data
			DebugPrint(string.format("  Skipping entry about ourselves (%s)", profileBTag))
		else
			local localProfile = ns.DB.GetProfile(profileBTag)

			if not localProfile then
				-- Profile unknown to us — request full data
				DebugPrint(string.format("  %s: unknown profile, requesting full data", profileBTag))
				local requestData = {
					[SK.battleTag] = profileBTag,
					[SK.afterTimestamp] = 0,
				}
				local message = ns.AddonMessages.BuildMessage(MSG_TYPE.GOSSIP_REQUEST, requestData)
				if message then
					ns.AddonMessages.SendMessage(message, ChatType.Whisper, sender)
				end
			else
				local localAu = localProfile.aliasUpdatedAt or 0
				local localCu = localProfile.charsUpdatedAt or 0
				local localCc = ns.DB.GetCharacterCount(localProfile)

				-- Case 1: Digest has newer data — request it
				if digestCu > localCu then
					-- Request delta characters (only those added after our timestamp)
					DebugPrint(
						string.format(
							"  %s: digest cu=%d > local cu=%d, requesting delta",
							profileBTag,
							digestCu,
							localCu
						)
					)
					local requestData = {
						[SK.battleTag] = profileBTag,
						[SK.afterTimestamp] = localCu,
					}
					local message = ns.AddonMessages.BuildMessage(MSG_TYPE.GOSSIP_REQUEST, requestData)
					if message then
						ns.AddonMessages.SendMessage(message, ChatType.Whisper, sender)
					end
				elseif digestAu > localAu then
					-- They have a newer alias — request full profile to get it
					DebugPrint(
						string.format(
							"  %s: digest au=%d > local au=%d, requesting full",
							profileBTag,
							digestAu,
							localAu
						)
					)
					local requestData = {
						[SK.battleTag] = profileBTag,
						[SK.afterTimestamp] = 0,
					}
					local message = ns.AddonMessages.BuildMessage(MSG_TYPE.GOSSIP_REQUEST, requestData)
					if message then
						ns.AddonMessages.SendMessage(message, ChatType.Whisper, sender)
					end
				elseif digestCu == localCu and digestCc > localCc then
					-- Same timestamp but they have more chars — we lost chunks
					DebugPrint(
						string.format(
							"  %s: same cu but digest cc=%d > local cc=%d, requesting full",
							profileBTag,
							digestCc,
							localCc
						)
					)
					local requestData = {
						[SK.battleTag] = profileBTag,
						[SK.afterTimestamp] = 0,
					}
					local message = ns.AddonMessages.BuildMessage(MSG_TYPE.GOSSIP_REQUEST, requestData)
					if message then
						ns.AddonMessages.SendMessage(message, ChatType.Whisper, sender)
					end

				-- Case 2: We have fresher data — send corrections
				elseif localAu > digestAu and not ns.Gossip.HasSentCorrection(senderBattleTag, profileBTag) then
					DebugPrint(
						string.format(
							"  %s: local au=%d > digest au=%d, sending alias correction",
							profileBTag,
							localAu,
							digestAu
						)
					)
					ns.Gossip.CorrectStaleAlias(sender, profileBTag, localProfile.alias, localAu)
					ns.Gossip.MarkCorrectionSent(senderBattleTag, profileBTag)
					-- Update tracking with corrected values
					ns.DB.UpdateGossipTracking(
						senderBattleTag,
						profileBTag,
						localAu,
						math.max(localCu, digestCu),
						math.max(localCc, digestCc)
					)
				elseif localCu > digestCu and not ns.Gossip.HasSentCorrection(senderBattleTag, profileBTag) then
					DebugPrint(
						string.format(
							"  %s: local cu=%d > digest cu=%d, sending chars correction",
							profileBTag,
							localCu,
							digestCu
						)
					)
					ns.Gossip.CorrectStaleChars(sender, profileBTag, localCu, digestCu)
					ns.Gossip.MarkCorrectionSent(senderBattleTag, profileBTag)
					-- Update tracking with corrected values
					ns.DB.UpdateGossipTracking(
						senderBattleTag,
						profileBTag,
						math.max(localAu, digestAu),
						localCu,
						localCc
					)
				elseif
					localCu == digestCu
					and localCc > digestCc
					and not ns.Gossip.HasSentCorrection(senderBattleTag, profileBTag)
				then
					-- Same timestamp but we have more chars — they lost chunks, send all
					DebugPrint(
						string.format(
							"  %s: same cu but local cc=%d > digest cc=%d, sending full chars",
							profileBTag,
							localCc,
							digestCc
						)
					)
					ns.Gossip.CorrectStaleChars(sender, profileBTag, localCu, 0)
					ns.Gossip.MarkCorrectionSent(senderBattleTag, profileBTag)
					ns.DB.UpdateGossipTracking(
						senderBattleTag,
						profileBTag,
						math.max(localAu, digestAu),
						localCu,
						localCc
					)
				else
					DebugPrint(string.format("  %s: timestamps match, no action needed", profileBTag))
				end
			end

			-- Learn what the sender knows: update our tracking of their knowledge state
			-- This prevents us from including this profile in future digests to them
			-- (unless our data gets updated later)
			local currentTracking = ns.DB.GetGossipTracking(senderBattleTag)
			local tracked = currentTracking[profileBTag]
			if not tracked or digestAu >= (tracked.au or 0) or digestCu >= (tracked.cu or 0) then
				-- Only update if the digest shows same or newer knowledge
				local bestAu = math.max(digestAu, tracked and tracked.au or 0)
				local bestCu = math.max(digestCu, tracked and tracked.cu or 0)
				local bestCc = digestCc -- Use digest cc as their known count
				ns.DB.UpdateGossipTracking(senderBattleTag, profileBTag, bestAu, bestCu, bestCc)
			end
		end
	end
end

--- Handle incoming GOSSIP_REQUEST message
--- Responds with the requested profile's data (ALIAS_UPDATE + CHARS_UPDATE).
--- Supports delta requests via afterTimestamp.
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function HandleGossipRequest(sender, data)
	if not data then
		return
	end

	local profileBTag = data.battleTag
	local afterTimestamp = data.afterTimestamp or 0

	if not ValidateBattleTag(profileBTag) then
		DebugPrint("GOSSIP_REQUEST missing or invalid battleTag", "ff8800")
		return
	end

	if afterTimestamp ~= 0 and not ValidateTimestamp(afterTimestamp) then
		DebugPrint("GOSSIP_REQUEST invalid afterTimestamp", "ff8800")
		return
	end

	DebugPrint(string.format("Received GOSSIP_REQUEST from %s for %s (after=%d)", sender, profileBTag, afterTimestamp))

	-- Check if the requested profile is our own — if so, send from myProfile
	local myBattleTag = ns.DB.GetMyBattleTag()
	if profileBTag == myBattleTag then
		-- Send our own profile data
		local myProfile = ns.DB.GetMyProfile()
		if not myProfile then
			return
		end

		local aliasData = {
			[SK.battleTag] = myBattleTag,
			[SK.alias] = myProfile.alias,
			[SK.aliasUpdatedAt] = myProfile.aliasUpdatedAt,
		}
		local aliasMessage = ns.AddonMessages.BuildMessage(MSG_TYPE.ALIAS_UPDATE, aliasData)
		if aliasMessage then
			ns.AddonMessages.SendMessage(aliasMessage, ChatType.Whisper, sender)
		end

		local characters = ns.DB.GetCharactersAddedAfter(afterTimestamp)
		if #characters > 0 then
			local chars = {}
			for _, char in ipairs(characters) do
				table.insert(chars, {
					[SK.name] = char.name,
					[SK.realm] = char.realm or "",
					[SK.addedAt] = char.addedAt,
				})
			end
			ns.Coordinator.SendCharsUpdate(myBattleTag, chars, myProfile.charsUpdatedAt, ChatType.Whisper, sender)
		end
	else
		-- Send cached third-party profile data
		ns.Gossip.SendProfile(sender, profileBTag, afterTimestamp)
	end

	-- Update gossip tracking: the requester will now have this data
	local senderBattleTag = ns.CharacterCache.FindBattleTag(sender)
	if senderBattleTag then
		local profile = ns.DB.GetProfile(profileBTag)
		if profile then
			ns.DB.UpdateGossipTracking(
				senderBattleTag,
				profileBTag,
				profile.aliasUpdatedAt or 0,
				profile.charsUpdatedAt or 0,
				ns.DB.GetCharacterCount(profile)
			)
		end
	end
end

--- Route message to appropriate handler
--- @param messageType MessageType The message type
--- @param sender string The sender's character name
--- @param data table The decoded message data
local function RouteMessage(messageType, sender, data)
	DebugPrint(string.format("Received message of type %s from %s", messageType, sender))

	-- Route to appropriate handler
	if messageType == MSG_TYPE.MANIFEST then
		HandleManifest(sender, data)
	elseif messageType == MSG_TYPE.REQUEST_CHARS then
		HandleRequestChars(sender, data)
	elseif messageType == MSG_TYPE.ALIAS_UPDATE then
		HandleAliasUpdate(sender, data)
	elseif messageType == MSG_TYPE.CHARS_UPDATE then
		HandleCharsUpdate(sender, data)
	elseif messageType == MSG_TYPE.GOSSIP_DIGEST then
		HandleGossipDigest(sender, data)
	elseif messageType == MSG_TYPE.GOSSIP_REQUEST then
		HandleGossipRequest(sender, data)
	end
end

--- Handle incoming addon message (public API)
--- Entry point for all incoming addon messages. Parses, validates, and routes
--- messages to appropriate handlers.
--- @param prefix string The addon prefix
--- @param message string The encoded message content
--- @param channel string The channel the message was sent on
--- @param sender string The sender's character name
function Protocol.OnAddonMessage(prefix, message, channel, sender)
	if prefix ~= ADDON_PREFIX then
		return
	end

	--[===[@non-alpha@
	-- Ignore our own messages in release builds (helpful for testing in alpha)
	local playerName = UnitName("player")
	if sender == playerName then
		return
	end
	--@end-non-alpha@]===]

	local messageType, data = ParseMessage(message)
	if not messageType or not data then
		return
	end

	RouteMessage(messageType, sender, data)
end
