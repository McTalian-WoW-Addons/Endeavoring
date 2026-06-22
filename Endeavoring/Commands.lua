---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local Commands = {}
ns.Commands = Commands

-- Shortcuts
local INFO = ns.Constants.PREFIX_INFO
local ERROR = ns.Constants.PREFIX_ERROR

-- Command Handlers

--- Handle alias command - set or show player alias
--- @param args string The alias to set, or empty to show current
local function HandleAlias(args)
	if args and args ~= "" then
		-- Set alias
		if ns.DB.SetPlayerAlias(args) then
			print(INFO .. " Alias set to: " .. args)
			-- Broadcast updated manifest
			ns.Coordinator.SendManifestDebounced()
			ns.API.RequestActivityLog()
		else
			print(ERROR .. " Failed to set alias. Make sure you're logged in.")
		end
	else
		-- Show current alias
		local alias = ns.DB.GetPlayerAlias()
		if alias then
			print(INFO .. " Your current alias is: " .. alias)
		else
			print(ERROR .. " No alias set.")
		end
	end
end

--- Handle sync broadcast command - force MANIFEST broadcast
local function HandleSyncBroadcast()
	ns.Coordinator.SendManifest()
	print(INFO .. " Manually triggered MANIFEST broadcast")
end

--- Handle sync status command - show profile information
local function HandleSyncStatus()
	-- Show my profile
	local myProfile = ns.DB.GetMyProfile()
	if myProfile then
		print(INFO .. " === My Profile ===")
		print(string.format("  BattleTag: %s", myProfile.battleTag))
		print(string.format("  Alias: %s", myProfile.alias))
		print(string.format("  Alias Updated: %s", date("%Y-%m-%d %H:%M:%S", myProfile.aliasUpdatedAt)))
		print(string.format("  Chars Updated: %s", date("%Y-%m-%d %H:%M:%S", myProfile.charsUpdatedAt)))
		print(string.format("  Characters: %d", ns.DB.GetCharacterCount(myProfile)))
	else
		print(ERROR .. " No profile found")
	end

	-- Show cached profiles
	local profiles = ns.DB.GetAllProfiles()
	local count = 0
	for _ in pairs(profiles) do
		count = count + 1
	end
	print(string.format(INFO .. " === Cached Profiles: %d ===", count))
	for battleTag, profile in pairs(profiles) do
		print(string.format("  %s (%s) - %d chars", battleTag, profile.alias, ns.DB.GetCharacterCount(profile)))
	end
end

--- Handle sync purge command - clear all synced profiles
local function HandleSyncPurge()
	local count = ns.DB.PurgeSyncedProfiles()
	print(string.format(INFO .. " Purged %d synced profile(s). Your profile was preserved.", count))
end

--- Handle sync verbose command - toggle verbose debug mode
local function HandleToggleVerbose()
	local current = ns.DB.IsVerboseDebug()
	ns.DB.SetVerboseDebug(not current)
	if not current then
		print(INFO .. " Verbose debug mode enabled")
	else
		print(INFO .. " Verbose debug mode disabled")
	end
end

--- Handle sync gossip command - show gossip statistics
local function HandleSyncGossip()
	local stats = ns.Gossip.GetStats()
	print(INFO .. " === Gossip Statistics (Session) ===")
	print(string.format("  Corrections sent this session: %d", stats.totalCorrections))

	if stats.totalCorrections > 0 then
		print("  Corrections by player:")
		for battleTag, count in pairs(stats.correctionsByPlayer) do
			print(string.format("    %s: %d correction(s)", battleTag, count))
		end
	end
end

--- Handle sync stats command - show timing statistics
local function HandleSyncStats()
	local stats = ns.Coordinator.GetSyncStats()
	print(INFO .. " === Sync Timing Statistics ===")

	-- Format time durations
	local function formatDuration(seconds)
		if seconds < 60 then
			return string.format("%ds", seconds)
		end
		local minutes = math.floor(seconds / 60)
		local secs = seconds % 60
		return string.format("%dm %ds", minutes, secs)
	end

	print(string.format("  Last manifest: %s ago", formatDuration(stats.timeSinceLastManifest)))
	print(string.format("  Last roster manifest: %s ago", formatDuration(stats.timeSinceLastRosterManifest)))
	print("")
	print(string.format("  Roster min interval: %s", formatDuration(stats.rosterMinInterval)))
	print(string.format("  Next roster window: %s", formatDuration(stats.nextRosterWindowIn)))
	print("")
	print(string.format("  Heartbeat interval: %s", formatDuration(stats.heartbeatInterval)))
	print(string.format("  Next heartbeat: %s", formatDuration(stats.nextHeartbeatIn)))
end

--- Display leaderboard results
--- @param timeRange number The time range filter
local function DisplayLeaderboard(timeRange)
	-- Get activity log
	local activityLog = ns.API.GetActivityLogInfo()
	if not activityLog or not activityLog.isLoaded then
		print(ERROR .. " Activity log not available. Make sure you're in a neighborhood with an active Endeavor.")
		return
	end

	-- Build leaderboard
	local leaderboard = ns.Leaderboard.BuildEnriched(activityLog, timeRange)

	if #leaderboard == 0 then
		print(INFO .. " No activity found for the selected time range.")
		return
	end

	-- Display leaderboard
	local rangeName = ns.Leaderboard.GetTimeRangeName(timeRange)
	print(string.format(INFO .. " === Contribution Leaderboard (%s) ===", rangeName))

	local maxDisplay = 10
	for rank, entry in ipairs(leaderboard) do
		if rank > maxDisplay then
			break
		end

		local marker = entry.isLocalPlayer and " (You)" or ""
		print(
			string.format(
				"  %d. %s%s: %d points (%d tasks%s)",
				rank,
				entry.displayName,
				marker,
				entry.total,
				entry.entries,
				(#entry.charNames > 0) and (" with " .. #entry.charNames .. " characters") or ""
			)
		)
	end

	if #leaderboard > maxDisplay then
		print(string.format("  ... and %d more", #leaderboard - maxDisplay))
	end

	print(INFO .. " Use: /endeavoring leaderboard [all||today||week]")
end

--- Handle leaderboard command - show contribution rankings
--- @param args string Time range filter: "all", "today", "week"
local function HandleLeaderboard(args)
	-- Parse time range argument
	local timeRange = ns.Leaderboard.TIME_RANGE.ALL_TIME
	if args == "today" then
		timeRange = ns.Leaderboard.TIME_RANGE.TODAY
	elseif args == "week" then
		timeRange = ns.Leaderboard.TIME_RANGE.THIS_WEEK
	end

	-- Always request fresh data - set up one-shot event handler
	print(INFO .. " Requesting activity log data...")

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("INITIATIVE_ACTIVITY_LOG_UPDATED")
	frame:SetScript("OnEvent", function(self, event)
		if event == "INITIATIVE_ACTIVITY_LOG_UPDATED" then
			frame:UnregisterEvent("INITIATIVE_ACTIVITY_LOG_UPDATED")
			DisplayLeaderboard(timeRange)
		end
	end)

	-- Request activity log data
	ns.API.RequestActivityLog()
end

--- Handle sync help - show available sync commands
local function HandleSyncHelp()
	print(INFO .. " Sync commands:")
	print("  /endeavoring sync broadcast - Force MANIFEST broadcast")
	print("  /endeavoring sync status - Show profile status")
	print("  /endeavoring sync stats - Show timing statistics")
	print("  /endeavoring sync gossip - Show gossip statistics")
	print("  /endeavoring sync purge - Clear all synced profiles")
end

--- Handle sync command routing
--- @param args string The sync subcommand and arguments
local function HandleSync(args)
	if args == "broadcast" then
		HandleSyncBroadcast()
	elseif args == "status" then
		HandleSyncStatus()
	elseif args == "stats" then
		HandleSyncStats()
	elseif args == "purge" then
		HandleSyncPurge()
	elseif args == "gossip" then
		HandleSyncGossip()
	else
		HandleSyncHelp()
	end
end

--- Handle default command - toggle main frame
local function HandleDefault()
	ns.ToggleMainFrame()
end

--- Handle settings command - open settings panel
local function HandleSettings()
	if ns.Settings then
		ns.Settings.Open()
	else
		print(ERROR .. " Settings module not loaded yet. Please try again in a moment.")
	end
end

-- Command Router

--- Route slash command to appropriate handler
--- @param msg string The full command message
local function RouteCommand(msg)
	-- Parse command and arguments
	local command, args = msg:match("^(%S*)%s*(.-)$")
	command = command:lower()

	if command == "alias" then
		HandleAlias(args)
	elseif command == "sync" then
		HandleSync(args)
	elseif command == "leaderboard" or command == "lb" then
		HandleLeaderboard(args)
	elseif command == "verbose" then
		HandleToggleVerbose()
	elseif command == "settings" or command == "config" or command == "options" then
		HandleSettings()
	elseif command == "help" then
		print(INFO .. " Endeavoring commands:")
		print("  /endeavoring alias [name] - Set or show your player alias")
		print("  /endeavoring sync [subcommand] - Sync-related commands (type '/endeavoring sync help' for details)")
		print("  /endeavoring leaderboard [all|today|week] - Show contribution leaderboard")
		print("  /endeavoring settings - Open the settings panel")
		print("  /endeavoring verbose - Toggle verbose debug mode")
	else
		HandleDefault()
	end
end

-- Public API

--- Register slash commands
function Commands.Register()
	SLASH_ENDEAVORING1 = "/endeavoring"
	SLASH_ENDEAVORING2 = "/ndvr"
	SlashCmdList.ENDEAVORING = RouteCommand
end
