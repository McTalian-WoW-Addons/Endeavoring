---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

---@class Character
---@field name string Character name
---@field realm string Realm name
---@field addedAt number Unix timestamp when character was registered

---@class Profile
---@field battleTag string Player's BattleTag
---@field alias string Display name (defaults to BattleTag)
---@field aliasUpdatedAt number Timestamp of last alias change
---@field characters table<string, Character> Characters keyed by character name
---@field charsUpdatedAt number Timestamp of most recent character addition (max of character.addedAt)

---@class EndeavoringDB
---@field global table Global scope data
---@field global.myProfile Profile|nil Player's authoritative data (never synced from others)
---@field global.profiles table<string, Profile> Synced profiles from other players (keyed by BattleTag)
---@field global.gossipTracking table<string, table<string, {au: number, cu: number, cc: number}>> Content-aware gossip tracking
---@field global.version number Schema version for migrations

-- See .github/docs/database-schema.md for detailed schema documentation

local DB = {}
ns.DB = DB

local ERROR = ns.Constants.PREFIX_ERROR
local INFO = ns.Constants.PREFIX_INFO

local DEFAULT_DB = {
	global = {
		myProfile = nil,
		profiles = {},
		activityLogCache = {},  -- Keyed by neighborhoodGUID
		gossipTracking = {},  -- Content-aware gossip tracking: [targetBTag][profileBTag] = {au, cu, cc}
		claimedChests = {},  -- Keyed by "initiativeID:cycleID", true when player has claimed that cycle's chest
		verboseDebug = false,
		settings = nil,  -- User preferences
		lastSelectedTab = nil,  -- Remember last tab (1=Tasks, 2=Leaderboard, 3=Activity)
		version = 1
	}
}

--- Initialize the database
function DB.Init()
	if not EndeavoringDB then
		EndeavoringDB = CopyTable(DEFAULT_DB)
	end
	
	-- Ensure global structure exists
	if not EndeavoringDB.global then
		EndeavoringDB.global = {}
	end
	
	-- Migration logic can go here in the future
	if not EndeavoringDB.global.version then
		EndeavoringDB.global.version = 1
	end
	
	if not EndeavoringDB.global.profiles then
		EndeavoringDB.global.profiles = {}
	end
	
	if EndeavoringDB.global.verboseDebug == nil then
		EndeavoringDB.global.verboseDebug = false
	end
	
	if not EndeavoringDB.global.activityLogCache then
		EndeavoringDB.global.activityLogCache = {}
	end
	
	if not EndeavoringDB.global.gossipTracking then
		EndeavoringDB.global.gossipTracking = {}
	end

	if not EndeavoringDB.global.claimedChests then
		EndeavoringDB.global.claimedChests = {}
	end

	-- myProfile will be initialized on first character login
end

--- Build the SavedVariables key for a chest claim record
--- @param initiativeID number
--- @param cycleID number
--- @return string
local function makeChestKey(initiativeID, cycleID)
	return string.format("%d:%d", initiativeID, cycleID)
end

--- Mark the chest for the given initiative cycle as claimed by the player
--- @param initiativeID number The initiative ID
--- @param cycleID number The current cycle ID
function DB.SetChestClaimed(initiativeID, cycleID)
	if not initiativeID or not cycleID then return end
	EndeavoringDB.global.claimedChests[makeChestKey(initiativeID, cycleID)] = true
end

--- Check whether the chest for the given initiative cycle has been claimed
--- @param initiativeID number The initiative ID
--- @param cycleID number The current cycle ID
--- @return boolean isClaimed true if the chest has been marked as claimed
function DB.IsChestClaimed(initiativeID, cycleID)
	if not initiativeID or not cycleID then return false end
	return EndeavoringDB.global.claimedChests[makeChestKey(initiativeID, cycleID)] == true
end

--- Register the current character to the player's BattleTag
--- @return boolean success Whether the registration was successful
function DB.RegisterCurrentCharacter()
	local battleTag = ns.PlayerInfo.GetBattleTag()
	if not battleTag then
		print(ERROR .. " Unable to register character: BattleTag not found. Make sure you're logged in to Battle.net.")
		return false
	end
	
	local characterInfo = ns.PlayerInfo.GetCharacterInfo()
	local timestamp = time()
	
	-- Initialize myProfile if it doesn't exist
	if not EndeavoringDB.global.myProfile then
		EndeavoringDB.global.myProfile = {
			battleTag = battleTag,
			alias = battleTag, -- Default to BattleTag
			aliasUpdatedAt = timestamp,
			characters = {},
			charsUpdatedAt = timestamp
		}
	end
	
	local myProfile = EndeavoringDB.global.myProfile
	
	-- Check if character already exists
	local isNewCharacter = not myProfile.characters[characterInfo.name]
	
	-- Register character with addedAt timestamp
	if isNewCharacter then
		myProfile.characters[characterInfo.name] = {
			name = characterInfo.name,
			realm = characterInfo.realm,
			addedAt = timestamp,
		}
		-- Update profileʼs characters timestamp
		myProfile.charsUpdatedAt = timestamp
		print(INFO .. " New Character registered: " .. characterInfo.name .. " (" .. characterInfo.realm .. ")")
	end
	
	return true
end

--- Set an alias for the current player's BattleTag
--- @param alias string The alias to set
--- @return boolean success Whether the alias was set successfully
function DB.SetPlayerAlias(alias)
	local battleTag = ns.PlayerInfo.GetBattleTag()
	if not battleTag then
		print(ERROR .. " Unable to set alias: BattleTag not found. Make sure you're logged in to Battle.net.")
		return false
	end
	
	if not EndeavoringDB.global.myProfile then
		-- Initialize profile if it doesn't exist
		DB.RegisterCurrentCharacter()
	end
	
	local myProfile = EndeavoringDB.global.myProfile
	local timestamp = time()
	
	myProfile.alias = alias
	myProfile.aliasUpdatedAt = timestamp

	return true
end

--- Get the alias for a given BattleTag
--- @param battleTag string The BattleTag to look up
--- @return string|nil alias The alias or nil if not found
function DB.GetAlias(battleTag)
	if not battleTag then
		print(ERROR .. " Unable to get alias: BattleTag not provided.")
		return nil
	end
	
	-- Check if it's the player's own BattleTag
	if EndeavoringDB.global.myProfile and EndeavoringDB.global.myProfile.battleTag == battleTag then
		return EndeavoringDB.global.myProfile.alias
	end
	
	-- Check synced profiles
	local profile = EndeavoringDB.global.profiles[battleTag]
	if profile then
		return profile.alias
	end
	
	return nil
end

--- Get the current player's alias
--- @return string|nil alias The current player's alias or nil if not found
function DB.GetPlayerAlias()
	if EndeavoringDB.global.myProfile then
		return EndeavoringDB.global.myProfile.alias
	end
	return nil
end

--- Get all characters for a given BattleTag
--- @param battleTag string The BattleTag to look up
--- @return table|nil characters Table of characters or nil if not found
function DB.GetCharacters(battleTag)
	if not battleTag then
		print(ERROR .. " Unable to get characters: BattleTag not provided.")
		return nil
	end
	
	-- Check if it's the player's own BattleTag
	if EndeavoringDB.global.myProfile and EndeavoringDB.global.myProfile.battleTag == battleTag then
		return EndeavoringDB.global.myProfile.characters
	end
	
	-- Check synced profiles
	local profile = EndeavoringDB.global.profiles[battleTag]
	if profile then
		return profile.characters
	end
	
	return nil
end

--- Get the current player's profile
--- @return Profile|nil profile The current player's profile or nil if not found
function DB.GetPlayerProfile()
	return EndeavoringDB.global.myProfile
end

--- Alias for GetPlayerProfile (for consistency with Sync service naming)
--- @return Profile|nil profile The current player's profile or nil if not found
function DB.GetMyProfile()
	return EndeavoringDB.global.myProfile
end

--- Get the current player's BattleTag
--- @return string|nil battleTag The current player's BattleTag or nil if not found
function DB.GetMyBattleTag()
	if EndeavoringDB.global.myProfile then
		return EndeavoringDB.global.myProfile.battleTag
	end
	return nil
end

--- Count the number of characters in a profile
--- @param profile Profile The profile to count characters for
--- @return number count The number of characters
function DB.GetCharacterCount(profile)
	if not profile or not profile.characters then
		return 0
	end
	
	local count = 0
	for _ in pairs(profile.characters) do
		count = count + 1
	end
	return count
end

--- Get all profiles (synced profiles only, excludes myProfile)
--- @return table<string, Profile> profiles All synced profiles in the database
function DB.GetAllProfiles()
	return EndeavoringDB.global.profiles or {}
end

--- Get a specific profile by BattleTag (synced profiles only, excludes myProfile)
--- @param battleTag string The BattleTag to look up
--- @return Profile|nil profile The profile if found, nil otherwise
function DB.GetProfile(battleTag)
	if not battleTag then
		return nil
	end

	if battleTag == DB.GetMyBattleTag() then
		return EndeavoringDB.global.myProfile
	end
	
	return EndeavoringDB.global.profiles[battleTag]
end

--- Get the player's profile for broadcasting (authoritative data)
--- @return Profile|nil myProfile The player's profile to broadcast, or nil if not initialized
function DB.GetMyProfileForBroadcast()
	return EndeavoringDB.global.myProfile
end

--- Update a profile with new data (for sync purposes)
--- WARNING: This should NEVER update myProfile, only synced profiles from other players
--- @param battleTag string The BattleTag of the profile
--- @param profileData table The profile data to merge
--- @return boolean success Whether the update was successful
function DB.UpdateProfile(battleTag, profileData)
	if not battleTag or not profileData then
		return false
	end
	
	-- NEVER update myProfile via sync - it's always authoritative
	if EndeavoringDB.global.myProfile and EndeavoringDB.global.myProfile.battleTag == battleTag then
		return false
	end
	
	-- If we don't have this profile, or if the incoming data is newer, update it
	local existingProfile = EndeavoringDB.global.profiles[battleTag]
	
	if not existingProfile or (profileData.charsUpdatedAt and profileData.charsUpdatedAt > (existingProfile.charsUpdatedAt or 0)) then
		EndeavoringDB.global.profiles[battleTag] = profileData
		return true
	end
	
	return false
end

--- Check if incoming data is newer than existing data (only checks synced profiles)
--- @param battleTag string The BattleTag to check
--- @param incomingTimestamp number The timestamp of incoming data
--- @return boolean isNewer Whether the incoming data is newer
function DB.IsDataNewer(battleTag, incomingTimestamp)
	if not battleTag or not incomingTimestamp then
		return false
	end
	
	-- Don't check myProfile - it's never synced
	if EndeavoringDB.global.myProfile and EndeavoringDB.global.myProfile.battleTag == battleTag then
		return false
	end
	
	local existingProfile = EndeavoringDB.global.profiles[battleTag]
	if not existingProfile then
		return true -- No existing data, so incoming is "newer"
	end
	
	return incomingTimestamp > (existingProfile.charsUpdatedAt or 0)
end

--- Get manifest data for broadcasting (BattleTag, alias, timestamps)
--- @return { battleTag: string, alias: string, charsUpdatedAt: number, aliasUpdatedAt: number }|nil manifest The manifest data or nil if not initialized
function DB.GetManifest()
	if not EndeavoringDB.global.myProfile then
		return nil
	end
	
	local myProfile = EndeavoringDB.global.myProfile
	return {
		battleTag = myProfile.battleTag,
		alias = myProfile.alias,
		charsUpdatedAt = myProfile.charsUpdatedAt,
		aliasUpdatedAt = myProfile.aliasUpdatedAt,
	}
end

--- Get characters added after a specific timestamp
--- @param afterTimestamp number Only return characters with addedAt > this timestamp
--- @return Character[] characters Array of character data with addedAt timestamps
function DB.GetCharactersAddedAfter(afterTimestamp)
	if not EndeavoringDB.global.myProfile then
		return {}
	end
	
	local result = {}
	local myProfile = EndeavoringDB.global.myProfile
	
	for _, character in pairs(myProfile.characters) do
		if character.addedAt and character.addedAt > afterTimestamp then
			table.insert(result, {
				name = character.name,
				realm = character.realm,
				addedAt = character.addedAt,
			})
		end
	end
	
	return result
end

--- Get characters from any profile added after a specific timestamp
--- @param battleTag string The BattleTag of the profile
--- @param afterTimestamp number The timestamp to compare against
--- @return Character[] Array of characters added after the timestamp
function DB.GetProfileCharactersAddedAfter(battleTag, afterTimestamp)
	local profile = DB.GetProfile(battleTag)
	if not profile or not profile.characters then
		return {}
	end
	
	local result = {}
	for _, character in pairs(profile.characters) do
		if character.addedAt and character.addedAt > afterTimestamp then
			table.insert(result, {
				name = character.name,
				realm = character.realm,
				addedAt = character.addedAt,
			})
		end
	end
	
	return result
end

--- Add or update characters in a synced profile
--- @param battleTag string The BattleTag of the profile
--- @param characters Character[] Array of character data with addedAt timestamps
--- @return boolean success Whether the update was successful
function DB.AddCharactersToProfile(battleTag, characters)
	if not battleTag or not characters then
		return false
	end
	
	-- NEVER update myProfile via sync
	if EndeavoringDB.global.myProfile and EndeavoringDB.global.myProfile.battleTag == battleTag then
		return false
	end
	
	-- Initialize profile if it doesn't exist
	if not EndeavoringDB.global.profiles[battleTag] then
		EndeavoringDB.global.profiles[battleTag] = {
			battleTag = battleTag,
			alias = battleTag,
			aliasUpdatedAt = 0,
			characters = {},
			charsUpdatedAt = 0,
		}
	end
	
	local profile = EndeavoringDB.global.profiles[battleTag]
	local maxTimestamp = profile.charsUpdatedAt or 0
	
	for _, character in ipairs(characters) do
		if character.name then
			-- Only update if this is newer data
			local existing = profile.characters[character.name]
			if not existing or (character.addedAt and character.addedAt > (existing.addedAt or 0)) then
				profile.characters[character.name] = {
					name = character.name,
					realm = character.realm,
					addedAt = character.addedAt,
				}
				if character.addedAt and character.addedAt > maxTimestamp then
					maxTimestamp = character.addedAt
				end
			end
		end
	end
	
	-- Update profile's characters timestamp if we added newer characters
	if maxTimestamp > profile.charsUpdatedAt then
		profile.charsUpdatedAt = maxTimestamp
	end
	
	return true
end

--- Update alias for a synced profile
--- @param battleTag string The BattleTag of the profile
--- @param alias string The new alias
--- @param aliasUpdatedAt number The timestamp of when the alias was updated
--- @return boolean success Whether the update was successful
function DB.UpdateProfileAlias(battleTag, alias, aliasUpdatedAt)
	if not battleTag or not alias or not aliasUpdatedAt then
		return false
	end
	
	-- NEVER update myProfile via sync
	if EndeavoringDB.global.myProfile and EndeavoringDB.global.myProfile.battleTag == battleTag then
		return false
	end
	
	-- Initialize profile if it doesn't exist
	if not EndeavoringDB.global.profiles[battleTag] then
		EndeavoringDB.global.profiles[battleTag] = {
			battleTag = battleTag,
			alias = alias,
			aliasUpdatedAt = aliasUpdatedAt,
			characters = {},
			charsUpdatedAt = 0,
		}
		return true
	end
	
	local profile = EndeavoringDB.global.profiles[battleTag]
	
	-- Only update if this is newer
	if aliasUpdatedAt > (profile.aliasUpdatedAt or 0) then
		profile.alias = alias
		profile.aliasUpdatedAt = aliasUpdatedAt
		-- Don't update charsUpdatedAt - that's only for character changes
		
		return true
	end
	
	return false
end

--- Purge all synced profiles (keeps myProfile)
--- @return number count The number of profiles purged
function DB.PurgeSyncedProfiles()
	local count = 0
	for _ in pairs(EndeavoringDB.global.profiles) do
		count = count + 1
	end
	
	EndeavoringDB.global.profiles = {}
	
	return count
end

--- Get verbose debug mode status
--- @return boolean enabled Whether verbose debug mode is enabled
function DB.IsVerboseDebug()
	return EndeavoringDB and EndeavoringDB.global and EndeavoringDB.global.verboseDebug or false
end

--- Set verbose debug mode
--- @param enabled boolean Whether to enable verbose debug mode
function DB.SetVerboseDebug(enabled)
	if not EndeavoringDB or not EndeavoringDB.global then
		return
	end
	
	EndeavoringDB.global.verboseDebug = enabled
end

--------------------------------------------------------------
-- Activity Log Cache
--------------------------------------------------------------

--- Get cached activity log for a neighborhood
--- @param neighborhoodGUID string The neighborhood GUID
--- @return table|nil cachedData The cached activity log info, or nil if not cached
--- @return boolean isStale Whether the cache is stale (based on nextUpdateTime)
function DB.GetActivityLogCache(neighborhoodGUID)
	if not EndeavoringDB or not EndeavoringDB.global or not EndeavoringDB.global.activityLogCache then
		return nil, false
	end
	
	local cache = EndeavoringDB.global.activityLogCache[neighborhoodGUID]
	if not cache then
		return nil, false
	end
	
	-- Check if cache is stale based on nextUpdateTime
	local now = time()
	if cache.nextUpdateTime and now >= cache.nextUpdateTime then
		return cache, true  -- Cache is stale
	end
	
	return cache, false
end

--- Set cached activity log for a neighborhood
--- @param neighborhoodGUID string The neighborhood GUID
--- @param activityLogInfo table The activity log info from the API
function DB.SetActivityLogCache(neighborhoodGUID, activityLogInfo)
	if not EndeavoringDB or not EndeavoringDB.global then
		return
	end
	
	if not EndeavoringDB.global.activityLogCache then
		EndeavoringDB.global.activityLogCache = {}
	end
	
	-- Store a deep copy to avoid reference issues
	EndeavoringDB.global.activityLogCache[neighborhoodGUID] = {
		isLoaded = activityLogInfo.isLoaded,
		neighborhoodGUID = activityLogInfo.neighborhoodGUID,
		nextUpdateTime = activityLogInfo.nextUpdateTime,
		taskActivity = CopyTable(activityLogInfo.taskActivity),
		cachedAt = time()
	}
end

--- Clear activity log cache for a neighborhood (or all if no GUID provided)
--- @param neighborhoodGUID string|nil The neighborhood GUID to clear, or nil to clear all
function DB.ClearActivityLogCache(neighborhoodGUID)
	if not EndeavoringDB or not EndeavoringDB.global or not EndeavoringDB.global.activityLogCache then
		return
	end
	
	if neighborhoodGUID then
		EndeavoringDB.global.activityLogCache[neighborhoodGUID] = nil
	else
		EndeavoringDB.global.activityLogCache = {}
	end
end

-- =============================================================================
-- Gossip Tracking
-- =============================================================================

--- Get gossip tracking data for a specific target (what we've told them about)
--- @param targetBattleTag string The BattleTag of the player we gossiped to
--- @return table<string, {au: number, cu: number, cc: number}> tracking Profile tracking data, or empty table
function DB.GetGossipTracking(targetBattleTag)
	if not targetBattleTag then
		return {}
	end

	local tracking = EndeavoringDB.global.gossipTracking
	return tracking[targetBattleTag] or {}
end

--- Update gossip tracking for a target+profile pair (record what we told them)
--- @param targetBattleTag string The BattleTag of the player we gossiped to
--- @param profileBattleTag string The BattleTag of the profile we communicated
--- @param au number The aliasUpdatedAt timestamp we communicated
--- @param cu number The charsUpdatedAt timestamp we communicated
--- @param cc number The character count we communicated
function DB.UpdateGossipTracking(targetBattleTag, profileBattleTag, au, cu, cc)
	if not targetBattleTag or not profileBattleTag then
		return
	end

	local tracking = EndeavoringDB.global.gossipTracking
	if not tracking[targetBattleTag] then
		tracking[targetBattleTag] = {}
	end

	tracking[targetBattleTag][profileBattleTag] = {
		au = au or 0,
		cu = cu or 0,
		cc = cc or 0,
	}
end

--- Prune gossip tracking entries for targets not in the provided set
--- Removes tracking data for players who are no longer in the guild roster
--- @param validBattleTags table<string, boolean> Set of BattleTags to keep (value is truthy)
--- @return number removed The number of target entries pruned
function DB.PruneGossipTracking(validBattleTags)
	if not validBattleTags then
		return 0
	end

	local tracking = EndeavoringDB.global.gossipTracking
	local removed = 0

	for targetBTag in pairs(tracking) do
		if not validBattleTags[targetBTag] then
			tracking[targetBTag] = nil
			removed = removed + 1
		end
	end

	return removed
end

-- =============================================================================
-- Settings
-- =============================================================================

--- Get user settings
--- @return table|nil Settings table
function DB.GetSettings()
	if not EndeavoringDB or not EndeavoringDB.global then
		return nil
	end
	
	return EndeavoringDB.global.settings
end

--- Set user settings
--- @param settings table Settings table
function DB.SetSettings(settings)
	if not EndeavoringDB or not EndeavoringDB.global then
		return
	end
	
	EndeavoringDB.global.settings = settings
end

--- Get last selected tab
--- @return number|nil Tab ID (1=Tasks, 2=Leaderboard, 3=Activity)
function DB.GetLastSelectedTab()
	if not EndeavoringDB or not EndeavoringDB.global then
		return nil
	end
	
	return EndeavoringDB.global.lastSelectedTab
end

--- Set last selected tab
--- @param tabID number|nil Tab ID to remember
function DB.SetLastSelectedTab(tabID)
	if not EndeavoringDB or not EndeavoringDB.global then
		return
	end
	
	EndeavoringDB.global.lastSelectedTab = tabID
end

