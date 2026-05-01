--- Tests for Services/PositionService.lua
---
--- Covers:
--- - Set and Get by battleTag
--- - GetAllByNeighborhood returns only the target neighborhood
--- - Set updates timestamp on re-insert of same battleTag
--- - Clear removes all entries
--- - Stale cleanup removes entries older than 60s, keeps fresh ones
--- - GetDiagnostics returns correct cacheSize and staleCount
--- - Invalid input (nil battleTag, nil position) is logged and skipped

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Load PositionService into a fresh namespace and return service + ns.
--- C_Timer.NewTicker is already stubbed by WoWGlobals.lua (returns no-op ticker),
--- so Init() is safe to call without starting a real timer.
local function Setup()
	local ns = nsMocks.CreateNS()
	nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
	return ns, ns.PositionService
end

--- Build a minimal valid position table.
local function Pos(overrides)
	local base = {
		x = 0.5,
		y = 0.3,
		mapID = 1234,
		neighborhoodGUID = "NGUID-001",
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("PositionService", function()

	-- =========================================================================
	-- Set / Get round-trip
	-- =========================================================================
	describe("Set and Get", function()

		it("stores and retrieves a position by battleTag", function()
			local _, svc = Setup()

			svc.Set("Player#1234", Pos(), 1000)

			local entry = svc.Get("Player#1234")
			assert.is_not_nil(entry)
			assert.are.equal("Player#1234", entry.battleTag)
			assert.are.equal(0.5, entry.x)
			assert.are.equal(0.3, entry.y)
			assert.are.equal(1234, entry.mapID)
			assert.are.equal("NGUID-001", entry.neighborhoodGUID)
			assert.are.equal(1000, entry.timestamp)
		end)

		it("returns nil for an unknown battleTag", function()
			local _, svc = Setup()

			local entry = svc.Get("Ghost#9999")
			assert.is_nil(entry)
		end)

		it("updates timestamp and coordinates when same battleTag is set again", function()
			local _, svc = Setup()

			svc.Set("Player#1234", Pos({ x = 0.1, y = 0.2 }), 1000)
			svc.Set("Player#1234", Pos({ x = 0.9, y = 0.8 }), 2000)

			local entry = svc.Get("Player#1234")
			assert.are.equal(0.9, entry.x)
			assert.are.equal(0.8, entry.y)
			assert.are.equal(2000, entry.timestamp)
		end)

	end)

	-- =========================================================================
	-- GetAllByNeighborhood
	-- =========================================================================
	describe("GetAllByNeighborhood", function()

		it("returns only entries from the requested neighborhood", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos({ neighborhoodGUID = "NGUID-001" }), 1000)
			svc.Set("Player#B", Pos({ neighborhoodGUID = "NGUID-001" }), 1001)
			svc.Set("Player#C", Pos({ neighborhoodGUID = "NGUID-002" }), 1002)

			local results = svc.GetAllByNeighborhood("NGUID-001")
			assert.are.equal(2, #results)

			-- All returned entries must belong to NGUID-001
			for _, entry in ipairs(results) do
				assert.are.equal("NGUID-001", entry.neighborhoodGUID)
			end
		end)

		it("returns empty table when no entries match the neighborhood", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos({ neighborhoodGUID = "NGUID-001" }), 1000)

			local results = svc.GetAllByNeighborhood("NGUID-UNKNOWN")
			assert.are.equal(0, #results)
		end)

		it("returns empty table when cache is empty", function()
			local _, svc = Setup()

			local results = svc.GetAllByNeighborhood("NGUID-001")
			assert.are.equal(0, #results)
		end)

	end)

	-- =========================================================================
	-- Clear
	-- =========================================================================
	describe("Clear", function()

		it("removes all cached entries", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos(), 1000)
			svc.Set("Player#B", Pos(), 1001)
			svc.Clear()

			assert.is_nil(svc.Get("Player#A"))
			assert.is_nil(svc.Get("Player#B"))
		end)

		it("GetDiagnostics reports zero after Clear", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos(), 1000)
			svc.Clear()

			local diag = svc.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
		end)

	end)

	-- =========================================================================
	-- Stale cleanup
	-- =========================================================================
	describe("stale cleanup", function()

		it("removes entries older than 60s and keeps fresh ones", function()
			local _, svc = Setup()

			-- Freeze time at T=10000.  Stale entries have ts <= 9940 (10000-60).
			local fakeNow = 10000
			local origTime = _G.time
			_G.time = function() return fakeNow end

			-- Fresh: only 30s old
			svc.Set("Fresh#1", Pos(), fakeNow - 30)
			-- Stale: exactly 61s old
			svc.Set("Stale#1", Pos(), fakeNow - 61)
			-- Stale: 120s old
			svc.Set("Stale#2", Pos(), fakeNow - 120)

			-- Manually trigger cleanup (exported for testability via RunCleanup path)
			-- We drive cleanup through Init() + a direct timer callback capture.
			-- Because the timer is stubbed, we call the internal cleanup by
			-- re-loading the module and exercising it via GetDiagnostics staleCount.
			-- Instead, we use the public surface: call Set with an old timestamp,
			-- then call the private cleanup through a white-box approach.
			--
			-- White-box: C_Timer.NewTicker captures the callback; invoke it directly.
			local capturedCallback = nil
			_G.C_Timer.NewTicker = function(_, cb)
				capturedCallback = cb
				return { Cancel = function() end }
			end

			-- Reload the module with the ticker-capturing stub
			local ns2 = nsMocks.CreateNS()
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns2)
			local svc2 = ns2.PositionService

			-- Seed entries with the frozen clock
			svc2.Set("Fresh#1", Pos(), fakeNow - 30)
			svc2.Set("Stale#1", Pos(), fakeNow - 61)
			svc2.Set("Stale#2", Pos(), fakeNow - 120)

			-- Init starts the timer and captures the callback
			svc2.Init()
			assert.is_not_nil(capturedCallback)

			-- Fire the cleanup
			capturedCallback()

			-- Fresh entry survives
			assert.is_not_nil(svc2.Get("Fresh#1"))
			-- Stale entries are gone
			assert.is_nil(svc2.Get("Stale#1"))
			assert.is_nil(svc2.Get("Stale#2"))

			_G.time = origTime
		end)

		it("does not remove entries that are exactly at the boundary (60s)", function()
			local fakeNow = 10000
			local origTime = _G.time
			_G.time = function() return fakeNow end

			local capturedCallback = nil
			_G.C_Timer.NewTicker = function(_, cb)
				capturedCallback = cb
				return { Cancel = function() end }
			end

			local ns = nsMocks.CreateNS()
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
			local svc = ns.PositionService

			-- Exactly 60s old — threshold is "> 60", so this entry stays
			svc.Set("Boundary#1", Pos(), fakeNow - 60)
			svc.Init()
			capturedCallback()

			assert.is_not_nil(svc.Get("Boundary#1"))

			_G.time = origTime
		end)

	end)

	-- =========================================================================
	-- GetDiagnostics
	-- =========================================================================
	describe("GetDiagnostics", function()

		it("returns correct cacheSize", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos(), 1000)
			svc.Set("Player#B", Pos(), 1001)

			local diag = svc.GetDiagnostics()
			assert.are.equal(2, diag.cacheSize)
		end)

		it("returns correct staleCount without modifying the cache", function()
			local fakeNow = 10000
			local origTime = _G.time
			_G.time = function() return fakeNow end

			local _, svc = Setup()

			svc.Set("Fresh#1", Pos(), fakeNow - 30)  -- not stale
			svc.Set("Stale#1", Pos(), fakeNow - 61)  -- stale
			svc.Set("Stale#2", Pos(), fakeNow - 120) -- stale

			local diag = svc.GetDiagnostics()
			assert.are.equal(3, diag.cacheSize)  -- nothing removed
			assert.are.equal(2, diag.staleCount)

			_G.time = origTime
		end)

		it("reports lastUpdate after a Set", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos(), 5000)

			local diag = svc.GetDiagnostics()
			assert.are.equal(5000, diag.lastUpdate)
		end)

		it("returns zero cacheSize and zero staleCount on fresh load", function()
			local _, svc = Setup()

			local diag = svc.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
			assert.are.equal(0, diag.staleCount)
			assert.is_nil(diag.lastUpdate)
		end)

	end)

	-- =========================================================================
	-- Invalid input handling
	-- =========================================================================
	describe("invalid input", function()

		it("Set with nil battleTag logs error and does not store entry", function()
			local ns, svc = Setup()

			local logged = false
			ns.DebugPrint = function(msg)
				if msg:find("battleTag is required") then
					logged = true
				end
			end
			-- Reload so DebugPrint spy is used
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
			ns.PositionService.Set(nil, Pos(), 1000)

			assert.is_true(logged)
			-- Cache must remain empty
			local diag = ns.PositionService.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
		end)

		it("Set with empty string battleTag logs error and does not store entry", function()
			local ns, svc = Setup()

			local logged = false
			ns.DebugPrint = function(msg)
				if msg:find("battleTag is required") then
					logged = true
				end
			end
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
			ns.PositionService.Set("", Pos(), 1000)

			assert.is_true(logged)
			local diag = ns.PositionService.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
		end)

		it("Set with nil position logs error and does not store entry", function()
			local ns, svc = Setup()

			local logged = false
			ns.DebugPrint = function(msg)
				if msg:find("position is required") then
					logged = true
				end
			end
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
			ns.PositionService.Set("Player#1234", nil, 1000)

			assert.is_true(logged)
			local diag = ns.PositionService.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
		end)

		it("Set with non-number x/y logs error and does not store entry", function()
			local ns, svc = Setup()

			local logged = false
			ns.DebugPrint = function(msg)
				if msg:find("x and y must be numbers") then
					logged = true
				end
			end
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
			ns.PositionService.Set("Player#1234", Pos({ x = "bad" }), 1000)

			assert.is_true(logged)
			local diag = ns.PositionService.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
		end)

		it("Set with nil neighborhoodGUID logs error and does not store entry", function()
			local ns, svc = Setup()

			local logged = false
			ns.DebugPrint = function(msg)
				if msg:find("neighborhoodGUID is required") then
					logged = true
				end
			end
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionService.lua", ns)
			-- Build position without neighborhoodGUID (cannot pass nil via Pos() helper
			-- because pairs() skips nil values in override tables)
			local posNoGUID = { x = 0.5, y = 0.3, mapID = 1234 }
			ns.PositionService.Set("Player#1234", posNoGUID, 1000)

			assert.is_true(logged)
			local diag = ns.PositionService.GetDiagnostics()
			assert.are.equal(0, diag.cacheSize)
		end)

		it("Get with nil battleTag returns nil without error", function()
			local _, svc = Setup()

			local result = svc.Get(nil)
			assert.is_nil(result)
		end)

		it("GetAllByNeighborhood with nil neighborhoodGUID returns empty table", function()
			local _, svc = Setup()

			svc.Set("Player#A", Pos(), 1000)
			local results = svc.GetAllByNeighborhood(nil)
			assert.are.equal(0, #results)
		end)

	end)

	-- =========================================================================
	-- Init / StartCleanupTimer idempotence
	-- =========================================================================
	describe("Init", function()

		it("calling Init multiple times starts only one timer", function()
			local tickerCallCount = 0
			local origNewTicker = _G.C_Timer.NewTicker
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerCallCount = tickerCallCount + 1
				return { Cancel = function() end }
			end

			local _, svc = Setup()
			svc.Init()
			svc.Init()
			svc.Init()

			assert.are.equal(1, tickerCallCount)

			_G.C_Timer.NewTicker = origNewTicker
		end)

	end)

end)
