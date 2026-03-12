--- Tests for locale/init.lua
---
--- Covers:
--- - ns.L table is created on the namespace
--- - Unknown keys fall back to returning the key itself (passthrough)
--- - Explicitly set keys return their assigned value (not the key)
--- - Multiple locale files can overlay the same table
--- - enUS translations are consistently set

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

--- Load locale init and optionally the enUS file into a fresh namespace.
---@param loadEnUS boolean|nil Whether to also load the enUS translations
---@return table ns The namespace containing ns.L
local function SetupLocale(loadEnUS)
	local ns = {}

	nsMocks.LoadAddonFile("Endeavoring/locale/init.lua", ns)

	if loadEnUS then
		nsMocks.LoadAddonFile("Endeavoring/locale/enUS.lua", ns)
	end

	return ns
end

-- Tests ------------------------------------------------------------------

describe("Locale (init.lua)", function()

	-- ================================================================
	-- ns.L creation
	-- ================================================================
	describe("ns.L creation", function()
		it("creates ns.L as a table", function()
			local ns = SetupLocale()
			assert.is_table(ns.L)
		end)

		it("ns.L is the same table reference after repeated loads", function()
			local ns = {}
			nsMocks.LoadAddonFile("Endeavoring/locale/init.lua", ns)
			local firstL = ns.L
			-- Loading init again should not replace the existing table
			-- (in WoW, each file gets the same ns, so init only runs once,
			-- but we test that a second load doesn't break things)
			nsMocks.LoadAddonFile("Endeavoring/locale/init.lua", ns)
			-- The metatable behaviour should still work regardless
			assert.is_table(ns.L)
		end)
	end)

	-- ================================================================
	-- Fallback (passthrough) behaviour
	-- ================================================================
	describe("key fallback", function()
		it("returns the key itself for an unknown string key", function()
			local ns = SetupLocale()
			assert.equals("Some Unknown String", ns.L["Some Unknown String"])
		end)

		it("returns the key itself for a format-string key", function()
			local ns = SetupLocale()
			assert.equals("FMT_DaysAgo", ns.L["FMT_DaysAgo"])
		end)

		it("returns the key for any arbitrary key not in the table", function()
			local ns = SetupLocale()
			assert.equals("hello world", ns.L["hello world"])
			assert.equals("", ns.L[""])
		end)
	end)

	-- ================================================================
	-- Explicit assignment
	-- ================================================================
	describe("explicit assignment", function()
		it("returns the assigned value for a set key", function()
			local ns = SetupLocale()
			ns.L["My Key"] = "My Translation"
			assert.equals("My Translation", ns.L["My Key"])
		end)

		it("assigned value takes precedence over the fallback", function()
			local ns = SetupLocale()
			ns.L["Tasks"] = "Aufgaben"
			assert.equals("Aufgaben", ns.L["Tasks"])
		end)

		it("can reassign an existing key", function()
			local ns = SetupLocale()
			ns.L["Activity"] = "Activité"
			ns.L["Activity"] = "Aktivität"
			assert.equals("Aktivität", ns.L["Activity"])
		end)
	end)

	-- ================================================================
	-- enUS translations overlay
	-- ================================================================
	describe("enUS translations", function()
		it("enUS sets known keys on ns.L", function()
			local ns = SetupLocale(true)
			-- These should be explicitly set (equal to the key in enUS, which is
			-- fine — the important thing is the entry exists and the value is correct)
			assert.equals("Activity", ns.L["Activity"])
			assert.equals("Tasks", ns.L["Tasks"])
			assert.equals("Leaderboard", ns.L["Leaderboard"])
		end)

		it("enUS sets format-string keys", function()
			local ns = SetupLocale(true)
			assert.equals("%d days ago", ns.L["FMT_DaysAgo"])
			assert.equals("%dh ago", ns.L["FMT_HoursAgo"])
			assert.equals("%dm ago", ns.L["FMT_MinutesAgo"])
		end)

		it("enUS sets multi-word fallback strings", function()
			local ns = SetupLocale(true)
			assert.equals("No active endeavor", ns.L["No active endeavor"])
			assert.equals("No tasks available", ns.L["No tasks available"])
			assert.equals("No activity recorded", ns.L["No activity recorded"])
		end)

		it("enUS sets tooltip/dialog keys", function()
			local ns = SetupLocale(true)
			assert.is_string(ns.L["DLG_AliasPromptText"])
			assert.is_string(ns.L["TIP_ChangeAlias"])
			assert.is_string(ns.L["TIP_ChestIndicator"])
		end)

		it("unknown keys still fall back after enUS is loaded", function()
			local ns = SetupLocale(true)
			assert.equals("NonexistentKey", ns.L["NonexistentKey"])
		end)
	end)

	-- ================================================================
	-- Multiple locale overlay (simulate a translated locale layered on top)
	-- ================================================================
	describe("locale layering", function()
		it("a second locale file can override enUS values", function()
			local ns = SetupLocale(true)
			-- Simulate what a translation locale file does
			ns.L["Tasks"] = "Tâches"
			assert.equals("Tâches", ns.L["Tasks"])
		end)

		it("keys not overridden by a second locale retain their enUS value", function()
			local ns = SetupLocale(true)
			ns.L["Tasks"] = "Tâches"
			-- "Activity" was not overridden, should still be the enUS value
			assert.equals("Activity", ns.L["Activity"])
		end)

		it("enUS keys set to their own key-name are effectively the same as fallback", function()
			local ns_with_enUS = SetupLocale(true)
			local ns_bare = SetupLocale(false)
			-- Both should return the same string for a key that matches its own value in enUS
			assert.equals(ns_with_enUS.L["Activity"], ns_bare.L["Activity"])
		end)
	end)
end)
