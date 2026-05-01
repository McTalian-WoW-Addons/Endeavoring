--- Tests for Features/NeighborhoodMap.lua (data provider / pin model)
---
--- Covers:
---   - Init() registers a data provider with WorldMapFrame (idempotent)
---   - Init() skips when position opt-out is enabled
---   - RefreshAllData() acquires pins for positions matching the current map
---   - RefreshAllData() skips positions on a different mapID
---   - RefreshAllData() does nothing when no positions
---   - RemoveAllData() releases all pins by template
---   - GetDiagnostics() returns expected shape

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- ---------------------------------------------------------------------------
-- Minimal stubs
-- ---------------------------------------------------------------------------

--- Build a fake pin that tracks SetPosition and SetupDot calls.
local function MakePin()
	local p = { _pos = nil, _dot = nil }
	function p:SetPosition(x, y) self._pos = {x=x, y=y} end
	function p:SetupDot(bt, label, r, g, b) self._dot = {battleTag=bt, label=label, r=r, g=g, b=b} end
	function p:OnReleased() end
	return p
end

--- Build a fake WorldMapFrame that supports AddDataProvider / AcquirePin / etc.
local function MakeWorldMapFrame(mapID)
	local wm = {
		_dataProviders = {},
		_pins = {},
		_mapID = mapID or 100,
		_shown = true,
	}

	function wm:AddDataProvider(dp)
		table.insert(self._dataProviders, dp)
		dp.owningMap = self
		if dp.OnAdded then dp:OnAdded(self) end
	end

	function wm:RemoveDataProvider(dp)
		for i, v in ipairs(self._dataProviders) do
			if v == dp then
				table.remove(self._dataProviders, i)
				if dp.OnRemoved then dp:OnRemoved(self) end
				return
			end
		end
	end

	function wm:GetMapID() return self._mapID end

	function wm:AcquirePin(template, ...)
		local pin = MakePin()
		pin.template = template
		table.insert(self._pins, pin)
		return pin
	end

	function wm:RemoveAllPinsByTemplate(template)
		local kept = {}
		for _, p in ipairs(self._pins) do
			if p.template ~= template then table.insert(kept, p) end
		end
		self._pins = kept
	end

	function wm:IsShown() return self._shown end
	function wm:HookScript() end  -- no-op in tests

	return wm
end

-- ---------------------------------------------------------------------------
-- Setup helper
-- ---------------------------------------------------------------------------

local function Setup(opts)
	opts = opts or {}
	local ns = nsMocks.CreateNS()

	-- Position short keys
	ns.SK.x                = "px"
	ns.SK.y                = "py"
	ns.SK.mapID            = "mi"
	ns.SK.neighborhoodGUID = "ng"
	ns.SK.timestamp        = "ts"
	ns.SK.classFile        = "cf"

	-- Provide a fake neighborhood GUID
	ns.API = {
		GetActiveNeighborhoodGUID = function() return opts.guid or "NGUID-001" end
	}

	-- PositionService stub
	local positions = opts.positions or {}
	ns.PositionService = {
		_listeners = {},
		GetAllByNeighborhood = function(guid)
			return positions
		end,
		RegisterChangeListener = function(fn)
			table.insert(ns.PositionService._listeners, fn)
		end,
	}

	-- Settings stub — opt-out controlled by opts
	ns.Settings = {
		GetPositionOptOut = function() return opts.optOut or false end,
	}

	-- Globals
	_G.CreateFromMixins = function(...)
		local t = {}
		for i = 1, select("#", ...) do
			local mixin = select(i, ...)
			for k, v in pairs(mixin) do
				t[k] = v
			end
		end
		return t
	end

	_G.MapCanvasDataProviderMixin = {
		OnAdded = function() end,
		OnRemoved = function() end,
		RefreshAllData = function() end,
		RemoveAllData = function() end,
		GetMap = function(self) return self.owningMap end,
	}

	_G.MapCanvasPinMixin = {
		OnReleased = function() end,
	}

	_G.RAID_CLASS_COLORS = {
		MAGE    = {r=0.25, g=0.78, b=0.92},
		WARRIOR = {r=0.78, g=0.61, b=0.43},
	}

	local wm = MakeWorldMapFrame(opts.mapID or 100)
	_G.WorldMapFrame = wm

	nsMocks.LoadAddonFile("Endeavoring/Features/NeighborhoodMap.lua", ns)

	return ns, wm
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("NeighborhoodMap", function()

	describe("Init", function()
		it("registers a data provider with WorldMapFrame", function()
			local ns, wm = Setup()
			ns.NeighborhoodMap.Init()
			assert.equals(1, #wm._dataProviders)
		end)

		it("is idempotent — second Init is a no-op", function()
			local ns, wm = Setup()
			ns.NeighborhoodMap.Init()
			ns.NeighborhoodMap.Init()
			assert.equals(1, #wm._dataProviders)
		end)

		it("skips when position opt-out is enabled", function()
			local ns, wm = Setup({optOut = true})
			ns.NeighborhoodMap.Init()
			assert.equals(0, #wm._dataProviders)
		end)

		it("skips when WorldMapFrame is nil", function()
			local ns, wm = Setup()
			_G.WorldMapFrame = nil
			ns.NeighborhoodMap.Init()
			-- no crash, no data provider
		end)
	end)

	describe("RefreshAllData", function()
		it("acquires one pin per matching position", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile="MAGE"},
					{x=0.3, y=0.7, mapID=100, battleTag="Player#2", classFile="WARRIOR"},
				}
			})
			ns.NeighborhoodMap.Init()
			local dp = wm._dataProviders[1]
			dp:RefreshAllData()
			assert.equals(2, #wm._pins)
		end)

		it("skips positions on a different mapID", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.5, y=0.5, mapID=999, battleTag="Player#1", classFile="MAGE"},
				}
			})
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			assert.equals(0, #wm._pins)
		end)

		it("does nothing when positions table is empty", function()
			local ns, wm = Setup({mapID=100, positions={}})
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			assert.equals(0, #wm._pins)
		end)

		it("sets the correct normalized position on each pin", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.25, y=0.75, mapID=100, battleTag="Player#1", classFile="MAGE"},
				}
			})
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			local pin = wm._pins[1]
			assert.is_not_nil(pin._pos)
			assert.are.equal(0.25, pin._pos.x)
			assert.are.equal(0.75, pin._pos.y)
		end)

		it("applies class color to pin dot", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile="MAGE"},
				}
			})
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			local pin = wm._pins[1]
			assert.is_not_nil(pin._dot)
			assert.are.equal(0.25, pin._dot.r)
		end)

		it("falls back to white for unknown class", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile=nil},
				}
			})
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			local pin = wm._pins[1]
			assert.are.equal(1, pin._dot.r)
			assert.are.equal(1, pin._dot.g)
			assert.are.equal(1, pin._dot.b)
		end)

		it("clears previous pins on each refresh", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile="MAGE"},
				}
			})
			ns.NeighborhoodMap.Init()
			local dp = wm._dataProviders[1]
			dp:RefreshAllData()
			assert.equals(1, #wm._pins)
			dp:RefreshAllData()
			-- RemoveAllPinsByTemplate then re-acquire — still 1 (from second refresh)
			-- but total acquired is 2; only 1 remains after remove+re-acquire
			assert.equals(1, #wm._pins)
		end)
	end)

	describe("RemoveAllData", function()
		it("removes all pins by template", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {
					{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile="MAGE"},
				}
			})
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			assert.equals(1, #wm._pins)
			wm._dataProviders[1]:RemoveAllData()
			assert.equals(0, #wm._pins)
		end)
	end)

	describe("PositionService change listener", function()
		it("re-renders when map is shown and positions change", function()
			local positions = {
				{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile="MAGE"},
			}
			local ns, wm = Setup({mapID=100, positions=positions})
			wm._shown = true
			ns.NeighborhoodMap.Init()
			wm._dataProviders[1]:RefreshAllData()
			assert.equals(1, #wm._pins)

			-- Fire the change listener
			for _, fn in ipairs(ns.PositionService._listeners) do fn() end
			-- Should have re-rendered — pins removed and re-acquired
			assert.equals(1, #wm._pins)
		end)

		it("does not re-render when map is hidden", function()
			local ns, wm = Setup({
				mapID = 100,
				positions = {{x=0.5, y=0.5, mapID=100, battleTag="Player#1", classFile="MAGE"}},
			})
			wm._shown = false
			ns.NeighborhoodMap.Init()
			-- No initial render since map is hidden
			assert.equals(0, #wm._pins)
			-- Fire change listener — should not render
			for _, fn in ipairs(ns.PositionService._listeners) do fn() end
			assert.equals(0, #wm._pins)
		end)
	end)

	describe("GetDiagnostics", function()
		it("returns expected shape", function()
			local ns, wm = Setup()
			ns.NeighborhoodMap.Init()
			local diag = ns.NeighborhoodMap.GetDiagnostics()
			assert.is_not_nil(diag.visiblePositions)
			assert.is_not_nil(diag.renderErrors)
		end)
	end)

	describe("Shutdown", function()
		it("removes the data provider from WorldMapFrame", function()
			local ns, wm = Setup()
			ns.NeighborhoodMap.Init()
			assert.equals(1, #wm._dataProviders)
			ns.NeighborhoodMap.Shutdown()
			assert.equals(0, #wm._dataProviders)
		end)

		it("is safe to call when not initialized", function()
			local ns, wm = Setup()
			-- should not crash
			ns.NeighborhoodMap.Shutdown()
		end)
	end)

end)
