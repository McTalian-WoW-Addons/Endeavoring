--- Tests for Services/NeighborhoodAPI.lua
---
--- Covers: GetInitiativeInfo, IsInitiativeActive, IsInitiativeCompleted,
--- GetActiveNeighborhoodGUID, FormatTimeRemaining, GetQuestRewardHouseXp,
--- GetActivityLogInfo, ViewActiveNeighborhood (fallback chain).

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- NeighborhoodAPI uses SecondsToTime and HOUSING_DASHBOARD_TIME_REMAINING
require("Endeavoring_spec._mocks.WoWGlobals.APIs")

describe("NeighborhoodAPI", function()
	local ns

	before_each(function()
		ns = nsMocks.CreateNS()

		-- Default C_NeighborhoodInitiative stub
		_G.C_NeighborhoodInitiative = {
			GetNeighborhoodInitiativeInfo = function()
				return nil
			end,
			IsInitiativeEnabled = function()
				return false
			end,
			GetActiveNeighborhood = function()
				return nil
			end,
			RequestNeighborhoodInitiativeInfo = function() end,
			GetInitiativeActivityLogInfo = function()
				return nil
			end,
			RequestInitiativeActivityLog = function() end,
			GetQuestRewardHouseXp = function()
				return nil
			end,
			SetViewingNeighborhood = function() end,
			SetActiveNeighborhood = function() end,
			IsViewingActiveNeighborhood = function()
				return false
			end,
		}

		_G.C_Housing = {
			GetPlayerOwnedHouses = function()
				return {}
			end,
			GetCurrentNeighborhoodGUID = function()
				return nil
			end,
		}

		_G.C_QuestInfoSystem = {
			GetQuestLogRewardFavor = function()
				return nil
			end,
		}

		nsMocks.LoadAddonFile("Endeavoring/Services/NeighborhoodAPI.lua", ns)
	end)

	-- ========================================
	-- GetInitiativeInfo
	-- ========================================
	describe("GetInitiativeInfo", function()
		it("returns nil when no initiative data available", function()
			assert.is_nil(ns.API.GetInitiativeInfo())
		end)

		it("returns initiative info when available", function()
			local info = { title = "Test Endeavor", currentProgress = 50, progressRequired = 100 }
			_G.C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo = function()
				return info
			end
			assert.same(info, ns.API.GetInitiativeInfo())
		end)

		it("returns nil when API namespace missing", function()
			_G.C_NeighborhoodInitiative = nil
			assert.is_nil(ns.API.GetInitiativeInfo())
		end)
	end)

	-- ========================================
	-- IsInitiativeActive
	-- ========================================
	describe("IsInitiativeActive", function()
		it("returns false when not enabled", function()
			assert.is_false(ns.API.IsInitiativeActive())
		end)

		it("returns true when enabled", function()
			_G.C_NeighborhoodInitiative.IsInitiativeEnabled = function()
				return true
			end
			assert.is_true(ns.API.IsInitiativeActive())
		end)

		it("returns false when API missing", function()
			_G.C_NeighborhoodInitiative = nil
			assert.is_false(ns.API.IsInitiativeActive())
		end)
	end)

	-- ========================================
	-- IsInitiativeCompleted
	-- ========================================
	describe("IsInitiativeCompleted", function()
		it("returns false when no initiative data", function()
			assert.is_false(ns.API.IsInitiativeCompleted())
		end)

		it("returns false when progress < required", function()
			_G.C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo = function()
				return { currentProgress = 50, progressRequired = 100 }
			end
			assert.is_false(ns.API.IsInitiativeCompleted())
		end)

		it("returns true when progress == required", function()
			_G.C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo = function()
				return { currentProgress = 100, progressRequired = 100 }
			end
			assert.is_true(ns.API.IsInitiativeCompleted())
		end)

		it("returns true when progress > required (overflow)", function()
			_G.C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo = function()
				return { currentProgress = 150, progressRequired = 100 }
			end
			assert.is_true(ns.API.IsInitiativeCompleted())
		end)
	end)

	-- ========================================
	-- GetActiveNeighborhoodGUID
	-- ========================================
	describe("GetActiveNeighborhoodGUID", function()
		it("returns nil when no active neighborhood", function()
			assert.is_nil(ns.API.GetActiveNeighborhoodGUID())
		end)

		it("returns GUID when available", function()
			_G.C_NeighborhoodInitiative.GetActiveNeighborhood = function()
				return "neighborhood-guid-123"
			end
			assert.equals("neighborhood-guid-123", ns.API.GetActiveNeighborhoodGUID())
		end)

		it("returns nil when API missing", function()
			_G.C_NeighborhoodInitiative = nil
			assert.is_nil(ns.API.GetActiveNeighborhoodGUID())
		end)
	end)

	-- ========================================
	-- FormatTimeRemaining
	-- ========================================
	describe("FormatTimeRemaining", function()
		it("returns fallback for nil duration", function()
			local result = ns.API.FormatTimeRemaining(nil)
			assert.equals("Time Remaining: --", result)
		end)

		it("returns fallback for zero duration", function()
			local result = ns.API.FormatTimeRemaining(0)
			assert.equals("Time Remaining: --", result)
		end)

		it("returns fallback for negative duration", function()
			local result = ns.API.FormatTimeRemaining(-100)
			assert.equals("Time Remaining: --", result)
		end)

		it("formats positive duration using HOUSING_DASHBOARD_TIME_REMAINING", function()
			_G.HOUSING_DASHBOARD_TIME_REMAINING = "Time Remaining: %s"
			local result = ns.API.FormatTimeRemaining(3600)
			assert.is_string(result)
			assert.truthy(result:find("Time Remaining"))
		end)

		it("falls back to simple format when localization string missing", function()
			_G.HOUSING_DASHBOARD_TIME_REMAINING = nil
			local result = ns.API.FormatTimeRemaining(3600)
			assert.is_string(result)
			assert.truthy(result:find("Time Remaining"))
		end)
	end)

	-- ========================================
	-- GetQuestRewardHouseXp
	-- ========================================
	describe("GetQuestRewardHouseXp", function()
		it("returns nil for nil questID", function()
			assert.is_nil(ns.API.GetQuestRewardHouseXp(nil))
		end)

		it("returns nil for zero questID", function()
			assert.is_nil(ns.API.GetQuestRewardHouseXp(0))
		end)

		it("returns favor value when available", function()
			_G.C_QuestInfoSystem.GetQuestLogRewardFavor = function(questID, index)
				if questID == 12345 then
					return 500
				end
				return nil
			end
			assert.equals(500, ns.API.GetQuestRewardHouseXp(12345))
		end)

		it("returns nil when API missing", function()
			_G.C_QuestInfoSystem = nil
			assert.is_nil(ns.API.GetQuestRewardHouseXp(99))
		end)

		it("handles pcall safely on error", function()
			_G.C_QuestInfoSystem.GetQuestLogRewardFavor = function()
				error("API error")
			end
			assert.is_nil(ns.API.GetQuestRewardHouseXp(12345))
		end)
	end)

	-- ========================================
	-- GetActivityLogInfo
	-- ========================================
	describe("GetActivityLogInfo", function()
		it("returns nil when no data", function()
			assert.is_nil(ns.API.GetActivityLogInfo())
		end)

		it("returns activity log when available", function()
			local log = { isLoaded = true, taskActivity = {} }
			_G.C_NeighborhoodInitiative.GetInitiativeActivityLogInfo = function()
				return log
			end
			assert.same(log, ns.API.GetActivityLogInfo())
		end)
	end)

	-- ========================================
	-- ViewActiveNeighborhood
	-- ========================================
	describe("ViewActiveNeighborhood", function()
		it("returns false when API missing", function()
			_G.C_NeighborhoodInitiative = nil
			assert.is_false(ns.API.ViewActiveNeighborhood())
		end)

		it("returns true when already viewing active neighborhood", function()
			_G.C_NeighborhoodInitiative.IsViewingActiveNeighborhood = function()
				return true
			end
			assert.is_true(ns.API.ViewActiveNeighborhood())
		end)

		it("sets viewing neighborhood when active neighborhood found", function()
			local viewedGUID
			_G.C_NeighborhoodInitiative.GetActiveNeighborhood = function()
				return "guid-123"
			end
			_G.C_NeighborhoodInitiative.SetViewingNeighborhood = function(guid)
				viewedGUID = guid
			end
			assert.is_true(ns.API.ViewActiveNeighborhood())
			assert.equals("guid-123", viewedGUID)
		end)

		it("falls back to current neighborhood GUID when active not found", function()
			local viewedGUID, activatedGUID
			_G.C_NeighborhoodInitiative.GetActiveNeighborhood = function()
				return nil
			end
			_G.C_Housing.GetCurrentNeighborhoodGUID = function()
				return "fallback-guid"
			end
			_G.C_NeighborhoodInitiative.SetActiveNeighborhood = function(guid)
				activatedGUID = guid
			end
			_G.C_NeighborhoodInitiative.SetViewingNeighborhood = function(guid)
				viewedGUID = guid
			end

			assert.is_true(ns.API.ViewActiveNeighborhood())
			assert.equals("fallback-guid", viewedGUID)
			assert.equals("fallback-guid", activatedGUID)
		end)

		it("returns false when no neighborhood found at all", function()
			_G.C_NeighborhoodInitiative.GetActiveNeighborhood = function()
				return nil
			end
			_G.C_Housing.GetCurrentNeighborhoodGUID = function()
				return nil
			end
			assert.is_false(ns.API.ViewActiveNeighborhood())
		end)
	end)
end)
