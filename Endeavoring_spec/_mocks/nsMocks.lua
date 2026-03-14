--- Addon namespace mock builder for Endeavoring specs.
---
--- Constructs a minimal `ns` table that mirrors what Bootstrap.lua provides,
--- with stubs for service modules that Protocol.lua (and others) depend on.
--- Specs can override individual fields/methods as needed.
---
--- Usage in a spec:
---   local nsMocks = require("Endeavoring_spec._mocks.nsMocks")
---   local ns = nsMocks.CreateNS()
---   -- Override specific stubs as needed for your test
---   ns.MessageCodec.Decode = function(encoded) return { ... } end

local busted = require("busted")
local stub = busted.stub
local spy = busted.spy

local nsMocks = {}

--- Create a fresh addon namespace with all required fields stubbed.
--- @return table ns A namespace table suitable for loading addon source files
function nsMocks.CreateNS()
	local ns = {}

	-- Constants (mirrors Bootstrap.lua)
	ns.Constants = {
		FRAME_WIDTH = 640,
		FRAME_HEIGHT = 540,
		SCROLLBAR_WIDTH = 20,
		HEADER_HEIGHT = 120,
		HEADER_PROGRESS_HEIGHT = 18,
		HEADER_PROGRESS_WIDTH = 320,
		TASK_HEADER_HEIGHT = 16,
		TASK_ROW_HEIGHT = 60,
		TASK_TASK_WIDTH = 280,
		TASK_CONTRIBUTION_WIDTH = 100,
		TASK_XP_WIDTH = 100,
		TASK_COUPONS_WIDTH = 100,
		TASKS_SORT_NAME = "name",
		TASKS_SORT_POINTS = "points",
		TASKS_SORT_XP = "xp",
		TASKS_SORT_COUPONS = "coupons",
		LEADERBOARD_SORT_RANK = "rank",
		LEADERBOARD_SORT_NAME = "name",
		LEADERBOARD_SORT_TOTAL = "total",
		LEADERBOARD_SORT_ENTRIES = "entries",
		LEADERBOARD_FILTER_HEIGHT = 30,
		LEADERBOARD_FILTER_BUTTON_HEIGHT = 22,
		LEADERBOARD_FILTER_BUTTON_WIDTH = 120,
		LEADERBOARD_HEADER_HEIGHT = 22,
		LEADERBOARD_ROW_HEIGHT = 24,
		LEADERBOARD_RANK_WIDTH = 50,
		LEADERBOARD_NAME_WIDTH = 240,
		LEADERBOARD_TOTAL_WIDTH = 160,
		LEADERBOARD_ENTRIES_WIDTH = 120,
		ACTIVITY_SORT_TIME = "time",
		ACTIVITY_SORT_TASK = "task",
		ACTIVITY_SORT_CHAR = "char",
		ACTIVITY_SORT_CONTRIB = "contrib",
		ACTIVITY_FILTER_HEIGHT = 30,
		ACTIVITY_FILTER_BUTTON_HEIGHT = 22,
		ACTIVITY_HEADER_HEIGHT = 22,
		ACTIVITY_ROW_HEIGHT = 44,
		ACTIVITY_TIME_WIDTH = 80,
		ACTIVITY_TASK_WIDTH = 280,
		ACTIVITY_CHAR_WIDTH = 120,
		ACTIVITY_CONTRIB_WIDTH = 80,
		NO_ACTIVE_ENDEAVOR = "No active endeavor",
		NO_TASK_DATA = "No task data, try opening the housing dashboard",
		TIME_REMAINING_FALLBACK = "Time Remaining: --",
		NO_TASKS_AVAILABLE = "No tasks available",
		NO_LEADERBOARD_DATA = "No activity recorded",
		PREFIX_INFO = "|cff00ff00Endeavoring:|r",
		PREFIX_ERROR = "|cffff0000Endeavoring:|r",
		PREFIX_WARN = "|cffff8800Endeavoring:|r",
	}

	-- Message types (mirrors Bootstrap.lua)
	ns.MSG_TYPE = {
		MANIFEST = "M",
		REQUEST_CHARS = "R",
		ALIAS_UPDATE = "A",
		CHARS_UPDATE = "C",
		GOSSIP_DIGEST = "G",
		GOSSIP_REQUEST = "GR",
	}

	-- Short wire keys (mirrors Bootstrap.lua)
	ns.SK = {
		type = "t",
		battleTag = "b",
		alias = "a",
		charsUpdatedAt = "cu",
		aliasUpdatedAt = "au",
		afterTimestamp = "af",
		characters = "c",
		charsCount = "cc",
		name = "n",
		realm = "r",
		addedAt = "d",
		entries = "e",
	}

	-- Locale table (mirrors locale/init.lua — key falls back to key itself)
	ns.L = setmetatable({}, {
		__index = function(_, k) return k end,
	})

	-- State
	ns.state = {
		tasksSortKey = ns.Constants.TASKS_SORT_POINTS,
		tasksSortAsc = false,
	}

	ns.ui = {}

	-- DebugPrint (no-op by default; specs can spy on it)
	ns.DebugPrint = function() end

	-- MessageCodec stub
	ns.MessageCodec = {
		Encode = function() return "encoded", nil end,
		Decode = function() return nil, "not stubbed" end,
		EstimateSize = function() return 0 end,
	}

	-- AddonMessages stub
	ns.AddonMessages = {
		ChatType = {
			Party = "PARTY",
			Raid = "RAID",
			Instance = "INSTANCE_CHAT",
			Guild = "GUILD",
			Office = "OFFICER",
			Whisper = "WHISPER",
			Channel = "CHANNEL",
		},
		Init = function() end,
		BuildMessage = function() return "encoded_message" end,
		SendMessage = function() return true end,
		RegisterListener = function() end,
	}

	-- DB stub
	ns.DB = {
		IsVerboseDebug = function() return false end,
		GetMyBattleTag = function() return "TestPlayer#1234" end,
		GetMyProfile = function()
			return {
				battleTag = "TestPlayer#1234",
				alias = "TestAlias",
				charsUpdatedAt = 1700000000,
				aliasUpdatedAt = 1700000000,
				characters = {},
			}
		end,
		GetProfile = function() return nil end,
		GetAllProfiles = function() return {} end,
		GetCharacterCount = function() return 0 end,
		UpdateProfileAlias = function() return true end,
		AddCharactersToProfile = function() return true end,
		GetCharactersAddedAfter = function() return {} end,
		GetProfileCharactersAddedAfter = function() return {} end,
		GetGossipTracking = function() return {} end,
		UpdateGossipTracking = function() end,
	}

	-- PlayerInfo stub
	ns.PlayerInfo = {
		IsInGuild = function() return true end,
		IsInHomeGroup = function() return false end,
		IsInInstanceGroup = function() return false end,
		IsGuildOfficer = function() return false end,
	}

	-- CharacterCache stub
	ns.CharacterCache = {
		FindBattleTag = function() return nil end,
		Invalidate = function() end,
	}

	-- Coordinator stub
	ns.Coordinator = {
		Init = function() end,
		SendCharsUpdate = function() return true end,
		SendManifest = function() end,
		SendManifestDebounced = function() end,
		OnGuildRosterUpdate = function() end,
	}

	-- Gossip stub
	ns.Gossip = {
		SendDigest = function() end,
		SendProfile = function() end,
		MarkCorrectionSent = function() end,
		HasSentCorrection = function() return false end,
		CorrectStaleAlias = function() end,
		CorrectStaleChars = function() end,
	}

	-- API stub (NeighborhoodAPI)
	ns.API = {
		RequestActivityLog = function() end,
	}

	return ns
end

--- Load an addon source file with the given namespace.
--- Simulates WoW's addon file loading: `local addonName, ns = ...`
--- @param filePath string Path to the Lua source file (relative to project root)
--- @param ns table The addon namespace table
--- @param addonName string|nil The addon name (default: "Endeavoring")
function nsMocks.LoadAddonFile(filePath, ns, addonName)
	addonName = addonName or "Endeavoring"

	-- WoW passes (addonName, ns) via the varargs `...` when loading TOC files.
	-- We simulate this using package.preload + custom arg passing.
	-- The simplest approach: temporarily override the `...` mechanism via loadfile.
	local chunk, err = loadfile(filePath)
	if not chunk then
		error(string.format("Failed to load addon file '%s': %s", filePath, err or "unknown error"))
	end

	-- Call the chunk with (addonName, ns) as the varargs
	chunk(addonName, ns)
end

return nsMocks
