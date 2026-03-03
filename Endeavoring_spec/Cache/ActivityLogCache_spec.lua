--- Tests for Cache/ActivityLogCache.lua
---
--- Covers:
--- - Get() priority: live data → cached data → stale cached data
--- - Get() caching behavior (writes live data to DB cache)
--- - RefreshVisibleTabs (no-op when frame hidden, dispatches to correct tab)
--- - OnActivityLogUpdated (caches data, refreshes tabs)

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

local function SetupActivityLogCache()
	local ns = nsMocks.CreateNS()

	-- Default stubs
	ns.API.GetActivityLogInfo = function() return nil end
	ns.API.GetActiveNeighborhoodGUID = function() return nil end
	ns.API.RequestInitiativeInfo = function() end
	ns.DB.GetActivityLogCache = function() return nil, false end
	ns.DB.SetActivityLogCache = function() end

	nsMocks.LoadAddonFile("Endeavoring/Cache/ActivityLogCache.lua", ns)
	return ns, ns.ActivityLogCache
end

-- Tests ------------------------------------------------------------------

describe("ActivityLogCache", function()

	-- ================================================================
	-- Get
	-- ================================================================

	describe("Get", function()
		it("should return live data when loaded with taskActivity", function()
			local ns, Cache = SetupActivityLogCache()

			local liveData = {
				isLoaded = true,
				neighborhoodGUID = "GUID-1",
				taskActivity = { { taskID = 1 } },
			}
			ns.API.GetActivityLogInfo = function() return liveData end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local setCalled = false
			ns.DB.SetActivityLogCache = function() setCalled = true end

			local result = Cache.Get()
			assert.are.equal(liveData, result)
			assert.is_true(setCalled) -- Should update cache
		end)

		it("should return cached data when live data is not loaded", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return { isLoaded = false, taskActivity = {} } end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local cachedData = {
				isLoaded = true,
				neighborhoodGUID = "GUID-1",
				taskActivity = { { taskID = 42 } },
			}
			ns.DB.GetActivityLogCache = function() return cachedData, false end

			local result = Cache.Get()
			assert.are.equal(cachedData, result)
		end)

		it("should request update when cached data is stale", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return nil end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local cachedData = { isLoaded = true, taskActivity = { { taskID = 1 } } }
			ns.DB.GetActivityLogCache = function() return cachedData, true end

			local requestCalled = false
			ns.API.RequestInitiativeInfo = function() requestCalled = true end

			-- Make C_Timer.After execute callback immediately for testing
			_G.C_Timer.After = function(_, callback) callback() end

			local result = Cache.Get()
			assert.are.equal(cachedData, result)
			assert.is_true(requestCalled) -- Should trigger background update
		end)

		it("should not re-request when stale refresh is already pending", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return nil end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local cachedData = { isLoaded = true, taskActivity = { { taskID = 1 } } }
			ns.DB.GetActivityLogCache = function() return cachedData, true end

			local requestCount = 0
			ns.API.RequestInitiativeInfo = function() requestCount = requestCount + 1 end

			-- Don't execute callback so the guard stays pending
			_G.C_Timer.After = function(_, _) end

			Cache.Get() -- First call sets staleRefreshPending
			Cache.Get() -- Second call should skip request

			assert.are.equal(0, requestCount) -- Deferred, not called yet
		end)

		it("should allow re-request after live data clears the guard", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local cachedData = { isLoaded = true, taskActivity = { { taskID = 1 } } }
			ns.DB.GetActivityLogCache = function() return cachedData, true end

			local requestCount = 0
			ns.API.RequestInitiativeInfo = function() requestCount = requestCount + 1 end

			-- Don't execute callback so the guard stays pending
			_G.C_Timer.After = function(_, _) end
			ns.API.GetActivityLogInfo = function() return nil end

			Cache.Get() -- Sets staleRefreshPending

			-- Now simulate live data arriving (clears the guard)
			local liveData = { isLoaded = true, taskActivity = { { taskID = 2 } } }
			ns.API.GetActivityLogInfo = function() return liveData end
			ns.DB.SetActivityLogCache = function() end
			Cache.Get() -- Should clear guard via live data path

			-- Back to stale state
			ns.API.GetActivityLogInfo = function() return nil end
			_G.C_Timer.After = function(_, callback) callback() end
			Cache.Get() -- Should request again since guard was cleared

			assert.are.equal(1, requestCount)
		end)

		it("should return live data when no neighborhood GUID available", function()
			local ns, Cache = SetupActivityLogCache()

			local liveData = { isLoaded = false, taskActivity = {} }
			ns.API.GetActivityLogInfo = function() return liveData end
			ns.API.GetActiveNeighborhoodGUID = function() return nil end

			local result = Cache.Get()
			assert.are.equal(liveData, result)
		end)

		it("should fall back to live data when no cache exists", function()
			local ns, Cache = SetupActivityLogCache()

			local liveData = { isLoaded = false, taskActivity = {} }
			ns.API.GetActivityLogInfo = function() return liveData end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end
			ns.DB.GetActivityLogCache = function() return nil, false end

			local result = Cache.Get()
			assert.are.equal(liveData, result)
		end)

		it("should return nil when both live and cache are nil and no GUID", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return nil end
			ns.API.GetActiveNeighborhoodGUID = function() return nil end

			local result = Cache.Get()
			assert.is_nil(result)
		end)

		it("should not cache live data with empty taskActivity", function()
			local ns, Cache = SetupActivityLogCache()

			local liveData = { isLoaded = true, taskActivity = {} }
			ns.API.GetActivityLogInfo = function() return liveData end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local setCalled = false
			ns.DB.SetActivityLogCache = function() setCalled = true end
			ns.DB.GetActivityLogCache = function() return nil, false end

			Cache.Get()
			assert.is_false(setCalled)
		end)
	end)

	-- ================================================================
	-- RefreshVisibleTabs
	-- ================================================================

	describe("RefreshVisibleTabs", function()
		it("should do nothing when mainFrame is nil", function()
			local ns, Cache = SetupActivityLogCache()

			ns.ui.mainFrame = nil

			-- Should not error
			Cache.RefreshVisibleTabs()
		end)

		it("should do nothing when mainFrame is not shown", function()
			local ns, Cache = SetupActivityLogCache()

			ns.ui.mainFrame = {
				IsShown = function() return false end,
			}

			Cache.RefreshVisibleTabs()
		end)

		it("should refresh Activity tab when selected", function()
			local ns, Cache = SetupActivityLogCache()

			local refreshed = false
			ns.Activity = { Refresh = function() refreshed = true end }
			ns.ui.mainFrame = {
				IsShown = function() return true end,
				GetTab = function() return 3 end,
				activityTabID = 3,
				leaderboardTabID = 2,
			}

			Cache.RefreshVisibleTabs()
			assert.is_true(refreshed)
		end)

		it("should refresh Leaderboard tab when selected", function()
			local ns, Cache = SetupActivityLogCache()

			local refreshed = false
			ns.Leaderboard = { Refresh = function() refreshed = true end }
			ns.ui.mainFrame = {
				IsShown = function() return true end,
				GetTab = function() return 2 end,
				activityTabID = 3,
				leaderboardTabID = 2,
			}

			Cache.RefreshVisibleTabs()
			assert.is_true(refreshed)
		end)
	end)

	-- ================================================================
	-- OnActivityLogUpdated
	-- ================================================================

	describe("OnActivityLogUpdated", function()
		it("should cache data and refresh tabs on valid update", function()
			local ns, Cache = SetupActivityLogCache()

			local activityData = {
				isLoaded = true,
				neighborhoodGUID = "GUID-1",
				taskActivity = { { taskID = 1 } },
			}
			ns.API.GetActivityLogInfo = function() return activityData end
			ns.API.GetActiveNeighborhoodGUID = function() return "GUID-1" end

			local cachedGUID
			ns.DB.SetActivityLogCache = function(guid) cachedGUID = guid end

			-- Provide a hidden frame to prevent RefreshVisibleTabs from erroring
			ns.ui.mainFrame = { IsShown = function() return false end }

			Cache.OnActivityLogUpdated()
			assert.are.equal("GUID-1", cachedGUID)
		end)

		it("should ignore update when data is not loaded", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return { isLoaded = false, taskActivity = {} } end

			local setCalled = false
			ns.DB.SetActivityLogCache = function() setCalled = true end

			Cache.OnActivityLogUpdated()
			assert.is_false(setCalled)
		end)

		it("should ignore update when taskActivity is empty", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return { isLoaded = true, taskActivity = {} } end

			local setCalled = false
			ns.DB.SetActivityLogCache = function() setCalled = true end

			Cache.OnActivityLogUpdated()
			assert.is_false(setCalled)
		end)

		it("should ignore update when activityLogInfo is nil", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function() return nil end

			local setCalled = false
			ns.DB.SetActivityLogCache = function() setCalled = true end

			Cache.OnActivityLogUpdated()
			assert.is_false(setCalled)
		end)

		it("should not cache when no active neighborhood", function()
			local ns, Cache = SetupActivityLogCache()

			ns.API.GetActivityLogInfo = function()
				return { isLoaded = true, taskActivity = { { taskID = 1 } } }
			end
			ns.API.GetActiveNeighborhoodGUID = function() return nil end

			local setCalled = false
			ns.DB.SetActivityLogCache = function() setCalled = true end

			Cache.OnActivityLogUpdated()
			assert.is_false(setCalled)
		end)
	end)
end)
