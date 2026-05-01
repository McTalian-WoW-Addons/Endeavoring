--- Tests for Features/Settings.lua — privacy opt-out getter/setter
---
--- Covers:
--- - DB.IsPositionOptOut defaults to false
--- - DB.SetPositionOptOut / DB.IsPositionOptOut round-trip
--- - DB handles missing global gracefully
--- - Settings.GetPositionOptOut delegates to DB
--- - Settings.SetPositionOptOut delegates to DB
--- - Round-trip: set via Settings, verify via Settings

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- ---------------------------------------------------------------------------
-- WoW globals needed by Settings.lua at load time
-- Settings.lua captures WoW's global `Settings` as `WoWSettings` on line 7,
-- then calls Settings.Register() at the bottom of the file (line 329).
-- Register() uses EventUtil, WoW's Settings API, StaticPopupDialogs, and
-- CreateSettingsListSectionHeaderInitializer — all of which must be stubbed.
-- ---------------------------------------------------------------------------
local function InstallWoWSettingsStubs()
	local layoutStub = {
		AddInitializer = function() end,
	}
	local categoryStub = {}

	_G.Settings = _G.Settings or {}
	_G.Settings.RegisterVerticalLayoutCategory = function() return categoryStub, layoutStub end
	_G.Settings.RegisterProxySetting          = function() return {} end
	_G.Settings.CreateCheckbox                = function() end
	_G.Settings.CreateDropdown                = function() end
	_G.Settings.RegisterAddOnCategory         = function() end
	_G.Settings.OpenToCategory                = function() end
	_G.Settings.VarType                       = { Boolean = "boolean", Number = "number" }

	_G.EventUtil = _G.EventUtil or {}
	_G.EventUtil.ContinueOnAddOnLoaded = function() end

	_G.StaticPopupDialogs = _G.StaticPopupDialogs or {}

	_G.CreateSettingsListSectionHeaderInitializer = function() return {} end
	_G.CreateSettingsListDropDownInitializer      = function() return {} end
	_G.CreateSettingsListElementInitializer      = function() return {} end

	-- EditBox stub used inside StaticPopupDialogs definition
	_G.StaticPopupDialogs["ENDEAVORING_SET_ALIAS"]  = _G.StaticPopupDialogs["ENDEAVORING_SET_ALIAS"]  or {}
	_G.StaticPopupDialogs["ENDEAVORING_ABOUT"]      = _G.StaticPopupDialogs["ENDEAVORING_ABOUT"]      or {}
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Load Database into a fresh ns and call Init().
local function SetupDatabase(existingDB)
	_G.EndeavoringDB = existingDB or nil
	local ns = nsMocks.CreateNS()
	ns.PlayerInfo.GetBattleTag   = function() return "TestPlayer#1234" end
	ns.PlayerInfo.GetCharacterInfo = function()
		return { name = "Thrall", realm = "Stormrage" }
	end
	nsMocks.LoadAddonFile("Endeavoring/Data/Database.lua", ns)
	ns.DB.Init()
	return ns, ns.DB
end

--- Load Database + Settings into a fresh ns.
local function SetupSettings()
	InstallWoWSettingsStubs()

	local ns, DB = SetupDatabase(nil)
	-- Settings.lua reads ns.L (locale strings) and ns.DB
	ns.L = setmetatable({}, {
		__index = function(_, k) return k end,
	})
	nsMocks.LoadAddonFile("Endeavoring/Features/Settings.lua", ns)
	return ns, ns.Settings, DB
end

-- ---------------------------------------------------------------------------
-- DB-level tests
-- ---------------------------------------------------------------------------

describe("Database.positionOptOut", function()

	it("defaults to false after Init()", function()
		local _, DB = SetupDatabase(nil)
		assert.is_false(DB.IsPositionOptOut())
	end)

	it("round-trip: SetPositionOptOut(true) → IsPositionOptOut() returns true", function()
		local _, DB = SetupDatabase(nil)
		DB.SetPositionOptOut(true)
		assert.is_true(DB.IsPositionOptOut())
	end)

	it("round-trip: SetPositionOptOut(false) → IsPositionOptOut() returns false", function()
		local _, DB = SetupDatabase(nil)
		DB.SetPositionOptOut(true)
		DB.SetPositionOptOut(false)
		assert.is_false(DB.IsPositionOptOut())
	end)

	it("IsPositionOptOut returns false when EndeavoringDB is nil (safe before Init)", function()
		local _, DB = SetupDatabase(nil)
		-- Blow away the global to simulate pre-Init state
		_G.EndeavoringDB = nil
		assert.is_false(DB.IsPositionOptOut())
	end)

	it("SetPositionOptOut does not error when EndeavoringDB is nil", function()
		local _, DB = SetupDatabase(nil)
		_G.EndeavoringDB = nil
		assert.has_no_errors(function()
			DB.SetPositionOptOut(true)
		end)
	end)

end)

-- ---------------------------------------------------------------------------
-- Settings-level tests (thin pass-through wrappers over DB)
-- ---------------------------------------------------------------------------

describe("Settings.positionOptOut", function()

	it("GetPositionOptOut returns false by default", function()
		local _, Settings = SetupSettings()
		assert.is_false(Settings.GetPositionOptOut())
	end)

	it("GetPositionOptOut returns true after DB opt-out is set", function()
		local _, Settings, DB = SetupSettings()
		DB.SetPositionOptOut(true)
		assert.is_true(Settings.GetPositionOptOut())
	end)

	it("SetPositionOptOut(true) persisted via GetPositionOptOut()", function()
		local _, Settings = SetupSettings()
		Settings.SetPositionOptOut(true)
		assert.is_true(Settings.GetPositionOptOut())
	end)

	it("SetPositionOptOut(false) persisted via GetPositionOptOut()", function()
		local _, Settings = SetupSettings()
		Settings.SetPositionOptOut(true)
		Settings.SetPositionOptOut(false)
		assert.is_false(Settings.GetPositionOptOut())
	end)

	it("round-trip: toggle opt-out on and off and verify state each time", function()
		local _, Settings = SetupSettings()
		assert.is_false(Settings.GetPositionOptOut())

		Settings.SetPositionOptOut(true)
		assert.is_true(Settings.GetPositionOptOut())

		Settings.SetPositionOptOut(false)
		assert.is_false(Settings.GetPositionOptOut())

		Settings.SetPositionOptOut(true)
		assert.is_true(Settings.GetPositionOptOut())
	end)

end)
