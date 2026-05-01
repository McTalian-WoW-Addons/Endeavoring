--- Extended WoW API stubs for the test environment.
---
--- Stubs for WoW C_* namespaces and global functions that addon modules
--- reference at load time or within function bodies. These go beyond the
--- minimal stubs in WoWGlobals.lua (which covers core primitives like
--- issecretvalue, time, UnitName, C_ChatInfo, C_Timer, CopyTable, tContains).
---
--- Loaded by the load-order test and any spec that loads modules which
--- call into WoW APIs at initialization time.

-- ============================================================
-- Player identity and social
-- ============================================================
_G.BNGetInfo = _G.BNGetInfo or function()
	return nil, "TestPlayer#1234"
end

_G.UnitNameUnmodified = _G.UnitNameUnmodified or function(unit)
	return "TestPlayer", "TestRealm"
end

_G.GetNormalizedRealmName = _G.GetNormalizedRealmName or function()
	return "TestRealm"
end

_G.IsInGuild = _G.IsInGuild or function() return true end
_G.IsInGroup = _G.IsInGroup or function() return false end
_G.IsInInstance = _G.IsInInstance or function() return false, "none" end
_G.IsGuildLeader = _G.IsGuildLeader or function() return false end

_G.C_GuildInfo = _G.C_GuildInfo or {
	IsGuildOfficer = function() return false end,
}

-- Party category constants
_G.LE_PARTY_CATEGORY_HOME = _G.LE_PARTY_CATEGORY_HOME or 1
_G.LE_PARTY_CATEGORY_INSTANCE = _G.LE_PARTY_CATEGORY_INSTANCE or 2

-- ============================================================
-- Encoding utilities (MessageCodec)
-- ============================================================
_G.C_EncodingUtil = _G.C_EncodingUtil or {
	SerializeCBOR = function(data) return "cbor_stub" end,
	DeserializeCBOR = function(data) return {} end,
	CompressString = function(s) return s end,
	DecompressString = function(s) return s end,
	EncodeBase64 = function(s) return s end,
	DecodeBase64 = function(s) return s end,
}

-- ============================================================
-- Neighborhood / Initiative APIs (NeighborhoodAPI)
-- ============================================================
_G.C_NeighborhoodInitiative = _G.C_NeighborhoodInitiative or {
	GetNeighborhoodInitiativeInfo = function() return nil end,
	IsInitiativeEnabled = function() return false end,
	GetActiveNeighborhood = function() return nil end,
	RequestNeighborhoodInitiativeInfo = function() end,
	GetInitiativeActivityLogInfo = function() return nil end,
	RequestInitiativeActivityLog = function() end,
	GetQuestRewardHouseXp = function() return nil end,
	SetViewingNeighborhood = function() end,
	SetActiveNeighborhood = function() end,
	IsViewingActiveNeighborhood = function() return false end,
}

-- ============================================================
-- Housing APIs (NeighborhoodAPI)
-- ============================================================
_G.C_Housing = _G.C_Housing or {
	GetPlayerOwnedHouses = function() return {} end,
	GetCurrentNeighborhoodGUID = function() return nil end,
}

-- ============================================================
-- Quest log (QuestRewards)
-- ============================================================
_G.C_QuestLog = _G.C_QuestLog or {
	GetQuestRewardCurrencyInfo = function() return nil end,
}

-- ============================================================
-- Quest info system (NeighborhoodAPI - House XP)
-- ============================================================
_G.C_QuestInfoSystem = _G.C_QuestInfoSystem or {
	GetQuestLogRewardFavor = function() return nil end,
}

-- ============================================================
-- AddOn management (HousingDashboard integration)
-- ============================================================
_G.C_AddOns = _G.C_AddOns or {
	LoadAddOn = function() end,
}

-- ============================================================
-- Settings API (captured by Settings.lua before shadowing)
-- ============================================================
-- Note: Settings.lua does `local WoWSettings = Settings` at load time,
-- so this global must exist before Settings.lua loads.
if not _G.Settings then
	_G.Settings = {
		RegisterVerticalLayoutCategory = function(name)
			local category = {
				GetID = function() return name end,
			}
			local layout = {
				AddInitializer = function() end,
			}
			return category, layout
		end,
		RegisterAddOnCategory = function() end,
		OpenToCategory = function() end,
		RegisterProxySetting = function() return {} end,
		CreateCheckbox = function() return {} end,
		CreateDropdown = function() return {} end,
		CreateControlTextContainer = function()
			return {
				Add = function() end,
				GetData = function() return {} end,
			}
		end,
		VarType = {
			Boolean = 1,
			Number = 2,
			String = 3,
		},
	}
end

-- Settings initializer factories
_G.CreateSettingsListSectionHeaderInitializer = _G.CreateSettingsListSectionHeaderInitializer or function()
	return {}
end
_G.CreateSettingsButtonInitializer = _G.CreateSettingsButtonInitializer or function()
	return {}
end

-- ============================================================
-- Event utilities (Settings.lua registration)
-- ============================================================
_G.EventUtil = _G.EventUtil or {
	ContinueOnAddOnLoaded = function(addon, callback) end,
}

-- ============================================================
-- Misc globals referenced by various modules
-- ============================================================

-- RunNextFrame (Core.lua)
_G.RunNextFrame = _G.RunNextFrame or function(fn) end

-- Slash command tables (Commands.lua)
_G.SlashCmdList = _G.SlashCmdList or {}
_G.hash_SlashCmdList = _G.hash_SlashCmdList or {}

-- C_Timer.After (HousingDashboard.lua uses this alongside NewTimer/NewTicker)
_G.C_Timer = _G.C_Timer or {}
_G.C_Timer.After = _G.C_Timer.After or function(delay, callback) end
_G.C_Timer.NewTicker = _G.C_Timer.NewTicker or function(interval, callback)
	return { Cancel = function() end }
end

-- tinsert global alias (Core.lua)
_G.tinsert = _G.tinsert or table.insert

-- date global (Activity.lua, Commands.lua)
_G.date = _G.date or os.date

-- SecondsToTime (NeighborhoodAPI.FormatTimeRemaining)
_G.SecondsToTime = _G.SecondsToTime or function(seconds)
	return string.format("%d seconds", seconds or 0)
end

-- Housing dashboard localization string
_G.HOUSING_DASHBOARD_TIME_REMAINING = _G.HOUSING_DASHBOARD_TIME_REMAINING or "Time Remaining: %s"
