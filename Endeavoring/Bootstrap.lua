---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

ns.Constants = ns.Constants or {
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

	NO_ACTIVE_ENDEAVOR = ns.L["No active endeavor"],
	NO_TASK_DATA = ns.L["No task data, try opening the housing dashboard"],
	TIME_REMAINING_FALLBACK = ns.L["Time Remaining: --"],
	NO_TASKS_AVAILABLE = ns.L["No tasks available"],
	NO_LEADERBOARD_DATA = ns.L["No activity recorded"],
	-- Message prefixes
	PREFIX_INFO = "|cff00ff00" .. addonName .. ":|r",
	PREFIX_ERROR = "|cffff0000" .. addonName .. ":|r",
	PREFIX_WARN = "|cffff8800" .. addonName .. ":|r",
	-- Spell cast by the player when opening the Endeavor Coffer (chest).
	-- Sourced from Midnight (12.0.1) by inspecting etrace
	-- UNIT_SPELLCAST_SUCCEEDED for the player when interacting with the Endeavor Coffer.
	-- To re-verify after patches: enable /etrace, open an Endeavor Coffer,
	-- and confirm the spellID in the UNIT_SPELLCAST_SUCCEEDED event for your character still matches this value.
	ENDEAVOR_COFFER_SPELL_ID = 1283568,
}

--- Message types for sync protocol (CBOR + compression)
--- Values are intentionally short to minimize wire overhead
---@enum MessageType
ns.MSG_TYPE = {
	MANIFEST = "M",
	REQUEST_CHARS = "R",
	ALIAS_UPDATE = "A",
	CHARS_UPDATE = "C",
	GOSSIP_DIGEST = "G",
	GOSSIP_REQUEST = "GR",
}

--- Short wire keys for CBOR messages.
--- Use verbose names in code for readability; values are the short strings sent on the wire.
--- Protocol.lua derives its SHORT_KEY_MAP (short→verbose) by inverting this table.
---@enum ShortKey
ns.SK = {
	-- Message envelope
	type = "t",
	-- Profile identifiers
	battleTag = "b",
	alias = "a",
	-- Timestamps
	charsUpdatedAt = "cu",
	aliasUpdatedAt = "au",
	afterTimestamp = "af",
	-- Character list
	characters = "c",
	charsCount = "cc",
	-- Character object fields
	name = "n",
	realm = "r",
	addedAt = "d",
	-- Gossip digest
	entries = "e",
}

ns.state = ns.state or {
	tasksSortKey = ns.Constants.TASKS_SORT_POINTS,
	tasksSortAsc = false,
}

ns.ui = ns.ui or {}

--- Print debug message if verbose debug mode is enabled
--- @param message string The message to print
--- @param color string|nil Optional color code (default: green)
function ns.DebugPrint(message, color)
	if not ns.DB.IsVerboseDebug() then
		return
	end
	
	color = color or "00ff00" -- Green by default
	print(string.format("|cff%s%s:|r %s", color, addonName, message))
end
