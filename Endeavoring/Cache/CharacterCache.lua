---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local CharacterCache = {}
ns.CharacterCache = CharacterCache

--[[
Character-to-BattleTag Reverse Lookup Cache

PURPOSE:
Efficient O(1) character name → BattleTag lookups, avoiding expensive
O(profiles * characters) nested loops.

USAGE:
- Identify senders in gossip protocol (map character name to BattleTag)
- Leaderboard BattleTag resolution (map activity log character to BattleTag)
- Any feature that needs to resolve character → player mapping

INVALIDATION:
Cache is marked stale when profile data changes, and rebuilt lazily on next lookup.

FUTURE OPTIMIZATION:
Currently invalidates entire cache on any character update. Could be improved
with per-profile timestamp tracking for selective invalidation at scale (50+ profiles).
--]]

-- State
local cache = {}
---@type boolean|string[] isStale Whether the cache is stale and needs rebuilding, or an array of specific profile ids (battletags) that are stale
local isStale = true

local StaleType = {
	FULL = "full",
	SELECTIVE = "selective",
	FRESH = "fresh",
}

local function CheckStaleness()
	if isStale == true then
		return StaleType.FULL
	elseif type(isStale) == "table" and #isStale > 0 then
		return StaleType.SELECTIVE
	else
		return StaleType.FRESH
	end
end

--- Rebuild the character-to-BattleTag cache from all profiles
--- Called automatically when cache is stale
local function Rebuild()
	local staleness = CheckStaleness()
	if staleness == StaleType.FRESH then
		return
	elseif staleness == StaleType.FULL then
		-- Full rebuild
		cache = {}

		local allProfiles = ns.DB.GetAllProfiles()

		for battleTag, profile in pairs(allProfiles) do
			if profile.characters then
				for _, char in pairs(profile.characters) do
					cache[char.name] = battleTag
				end
			end
		end

		local myProfile = ns.DB.GetMyProfile()
		if myProfile and myProfile.characters then
			for _, char in pairs(myProfile.characters) do
				cache[char.name] = myProfile.battleTag
			end
		end

		isStale = false
	elseif staleness == StaleType.SELECTIVE then
		-- Selective rebuild for specific profiles
		for _, battleTag in pairs(isStale) do
			local profile = ns.DB.GetProfile(battleTag)
			if profile and profile.characters then
				for _, char in pairs(profile.characters) do
					cache[char.name] = battleTag
				end
			end
		end

		isStale = false
	end
end

--- Look up a player's BattleTag by character name
--- Handles "Name-Realm" format from CHAT_MSG_ADDON by trying the full name
--- first, then falling back to just the name portion (without realm suffix).
--- @param characterName string The character name to search for (may include "-Realm")
--- @return string|nil battleTag The BattleTag if found, nil otherwise
function CharacterCache.FindBattleTag(characterName)
	if CheckStaleness() ~= StaleType.FRESH then
		Rebuild()
	end

	-- Try exact match first (handles same-realm or name-only lookups)
	local result = cache[characterName]
	if result then
		return result
	end

	-- Strip realm suffix and retry (CHAT_MSG_ADDON sends "Name-Realm")
	local nameOnly = characterName and characterName:match("^([^-]+)")
	if nameOnly and nameOnly ~= characterName then
		return cache[nameOnly]
	end

	return nil
end

--- Mark cache as stale (call when profile data changes)
--- Cache will be rebuilt on next lookup
--- @param battletag string|nil Optional specific BattleTag to invalidate, or nil to invalidate entire cache
function CharacterCache.Invalidate(battletag)
	if not battletag then
		-- Invalidate entire cache
		isStale = true
		return
	end
	local staleness = CheckStaleness()
	if staleness == StaleType.FULL then
		-- Already fully stale, no action needed
		return
	elseif staleness == StaleType.SELECTIVE then
		-- Already in selective mode, add to list if not present
		if not tContains(isStale, battletag) then
			table.insert(isStale, battletag)
		end
	elseif staleness == StaleType.FRESH then
		-- Switch to selective stale mode with this battletag
		isStale = {}
		table.insert(isStale, battletag)
	end
end

--- Get cache statistics for debugging
--- @return table stats Cache statistics
function CharacterCache.GetStats()
	local characterCount = 0
	for _ in pairs(cache) do
		characterCount = characterCount + 1
	end

	return {
		characterCount = characterCount,
		isStale = isStale,
	}
end
