--- Tests for Features/NeighborhoodMinimap.lua
---
--- Covers:
---   - Create() initialises the parent frame (idempotent)
---   - GetPixelPositionFromMinimap() coordinate math (happy path + edge cases + error paths)
---   - RenderPositions() with empty / nil / single / multiple positions
---   - RenderPositions() filters positions whose mapID doesn't match currentMapID
---   - RenderPositions() before Create() is a safe no-op
---   - Texture pool allocation and monotonic growth (reuses textures, hides excess)
---   - Class color lookup: found, not found (unknown), nil classFile
---   - GetDiagnostics() returns correct shape and counts
---   - RenderPositions() increments renderErrors on coordinate failure

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- ---------------------------------------------------------------------------
-- Frame / texture stubs
-- ---------------------------------------------------------------------------

--- Minimal texture stub that tracks Show/Hide state, vertex color, and SetPoint.
local function MakeTexture()
	local t = {
		_shown = false,
		_color = {r=1, g=1, b=1, a=1},
		_points = {},
	}
	function t:SetSize() end
	function t:SetAllPoints() end
	function t:SetColorTexture(r, g, b, a)
		self._color = {r=r or 1, g=g or 1, b=b or 1, a=a or 1}
	end
	function t:SetVertexColor(r, g, b, a)
		self._color = {r=r or 1, g=g or 1, b=b or 1, a=a or 1}
	end
	function t:SetPoint(anchor, relativeTo, relativeAnchor, x, y)
		table.insert(self._points, {anchor=anchor, x=x, y=y})
	end
	function t:ClearAllPoints() self._points = {} end
	function t:Show() self._shown = true end
	function t:Hide() self._shown = false end
	function t:IsShown() return self._shown end
	return t
end

--- Minimal frame stub that supports CreateTexture, Show/Hide, GetWidth/GetHeight.
--- textures is a shared list so tests can inspect created textures.
local function MakeFrame(width, height)
	local textures = {}
	local f = {
		_shown = false,
		_level = 0,
		_points = {},
		_textures = textures,
		_scripts = {},
		_width = width or 150,
		_height = height or 150,
	}
	function f:SetAllPoints() end
	function f:SetSize(w, h) self._width = w; self._height = h end
	function f:SetFrameLevel(l) self._level = l end
	function f:GetFrameLevel() return self._level end
	function f:GetWidth()  return self._width  end
	function f:GetHeight() return self._height end
	function f:SetPoint(anchor, rel, relAnchor, x, y)
		table.insert(self._points, {anchor=anchor, x=x, y=y})
	end
	function f:ClearAllPoints() self._points = {} end
	function f:Show() self._shown = true end
	function f:Hide() self._shown = false end
	function f:IsShown() return self._shown end
	function f:SetScript(event, handler) self._scripts[event] = handler end
	function f:CreateTexture()
		local tex = MakeTexture()
		table.insert(textures, tex)
		return tex
	end
	return f
end

-- ---------------------------------------------------------------------------
-- Setup helpers
-- ---------------------------------------------------------------------------

-- The minimap pixel radius in the stub is 75px (150px-wide Minimap / 2).
-- Player world position fixed at (500, 350) on mapID=100.
-- GetPlayerMapPosition returns {x=0.5, y=0.5} → world (500, 350).
-- GetWorldPosFromMapPos: mapID=100, frac → (frac.y*700, frac.x*1000) i.e. (worldY, worldX).
-- So player world position: x=0.5*1000=500, y=0.5*700=350.
local MINIMAP_PX_RADIUS = 75  -- 150/2
local MAP_ID            = 100

--- Shared C_Map stub: GetPlayerMapPosition + GetWorldPosFromMapPos for mapID=100.
--- Player is at world (500, 350); GetWorldPosFromMapPos returns (continentID, Vector2D).
local function MakeCMap()
	return {
		GetPlayerMapPosition = function(mapID, unit)
			if mapID == MAP_ID then
				return {x = 0.5, y = 0.5}   -- player at map fraction (0.5, 0.5)
			end
			return nil
		end,
		GetWorldPosFromMapPos = function(mapID, frac)
			if mapID ~= MAP_ID then return nil, nil end
			-- Returns (continentID, worldPosition Vector2D)
			return 0, {x = frac.x * 1000, y = frac.y * 700}
		end,
		GetBestMapForUnit = function(unit)
			return MAP_ID
		end,
	}
end

--- Build a fresh ns, set up WoW globals, load the module, return ns.
--- minimapWidth: width of the Minimap stub (default 150 → pixel radius 75).
local function Setup(minimapWidth)
	minimapWidth = minimapWidth or 150

	local ns = nsMocks.CreateNS()

	-- RAID_CLASS_COLORS global
	_G.RAID_CLASS_COLORS = {
		WARRIOR = {r=0.78, g=0.61, b=0.43},
		MAGE    = {r=0.41, g=0.80, b=0.94},
	}

	-- CreateVector2D stub (used internally for GetWorldPosFromMapPos arg)
	_G.CreateVector2D = function(x, y) return {x=x, y=y} end

	-- Minimap stub: a fixed-width circular frame
	_G.Minimap = MakeFrame(minimapWidth, minimapWidth)
	_G.Minimap:SetFrameLevel(5)

	-- UIParent fallback
	_G.UIParent = MakeFrame(1024, 768)

	-- GetCVar stub: minimapZoom level 2 → 133 yards radius
	_G.GetCVar = function(key)
		if key == "minimapZoom" then return "2" end
		return nil
	end

	-- time() stub (returns a fixed epoch value)
	_G.time = function() return 1700000000 end

	-- CreateFrame stub — returns a MakeFrame anchored to Minimap size
	_G.CreateFrame = function(frameType, name, parent, template)
		return MakeFrame(minimapWidth, minimapWidth)
	end

	-- C_Map stub
	_G.C_Map = MakeCMap()

	nsMocks.LoadAddonFile("Endeavoring/Features/NeighborhoodMinimap.lua", ns)
	return ns
end

--- Build a minimal position entry on mapID=100, normalized fracs by default.
local function Pos(overrides)
	local base = {
		x              = 0.5,    -- normalized X (same as player → offset 0,0)
		y              = 0.5,    -- normalized Y (same as player → offset 0,0)
		mapID          = MAP_ID,
		battleTag      = "Player#1234",
		neighborhoodGUID = "NG-001",
	}
	if overrides then
		for k, v in pairs(overrides) do base[k] = v end
	end
	return base
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("NeighborhoodMinimap", function()

	-- Reset globals between tests by rebuilding via Setup()
	before_each(function()
		_G.Minimap        = nil
		_G.C_Map          = nil
		_G.CreateFrame    = nil
		_G.RAID_CLASS_COLORS = nil
		_G.CreateVector2D = nil
		_G.GetCVar        = nil
		_G.UIParent       = nil
		_G.time           = nil
	end)

	-- =========================================================================
	-- Create
	-- =========================================================================
	describe("Create", function()

		it("creates the overlay frame on first call", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
			assert.are.equal(0, diag.textureCount)
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("is idempotent — second call does not error", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.Create()  -- should be a no-op
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
		end)

		it("falls back to UIParent when Minimap global is nil", function()
			local ns = Setup()
			_G.Minimap = nil
			-- Should not error — falls back to UIParent
			ns.NeighborhoodMinimap.Create()
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
		end)

	end)

	-- =========================================================================
	-- GetPixelPositionFromMinimap
	-- =========================================================================
	describe("GetPixelPositionFromMinimap", function()
		-- Mock setup:
		--   GetWorldPosFromMapPos: {x = frac.x * 1000, y = frac.y * 700}
		--   yardsPerFracH = |botRight.y - topLeft.y| = 700  (horizontal)
		--   yardsPerFracV = |botRight.x - topLeft.x| = 1000 (vertical)
		--   zoom level 2 → 133 yards radius; pixelRadius = 75px

		it("returns (0, 0) offsets when target equals player position", function()
			local ns = Setup()
			-- Player at frac (0.5, 0.5); target same → zero offset
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(err)
			assert.are.equal(0, px)
			assert.are.equal(0, py)
		end)

		it("returns a positive X offset for a target east of player", function()
			-- East = larger fracX; dFracX = +133/700 ≈ 0.190 → fracX ≈ 0.690
			-- dxYards = 0.190 * 700 = 133; pixelX = (133/133)*75 = 75 → clamped to ~71.25
			local ns = Setup()
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.690, 0.5, MAP_ID)
			assert.is_nil(err)
			assert.truthy(px > 0)
			assert.truthy(math.abs(px) <= MINIMAP_PX_RADIUS)
		end)

		it("returns a negative Y offset for a target south of player", function()
			-- South = larger fracY; dyYards positive → pixelY negated
			local ns = Setup()
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.633, MAP_ID)
			assert.is_nil(err)
			assert.truthy(py < 0)
		end)

		it("clamps target outside minimap radius to 95% of pixel radius", function()
			local ns = Setup()
			-- Very large fracX → far east → clamps
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(1.0, 0.5, MAP_ID)
			assert.is_nil(err)
			local dist = math.sqrt(px*px + py*py)
			assert.truthy(dist <= MINIMAP_PX_RADIUS * 0.95 + 0.01)
		end)

		it("returns nil + error when C_Map is unavailable", function()
			local ns = Setup()
			_G.C_Map = nil
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(px)
			assert.is_nil(py)
			assert.is_not_nil(err)
		end)

		it("returns nil + error when C_Map.GetPlayerMapPosition is nil", function()
			local ns = Setup()
			_G.C_Map = MakeCMap()
			_G.C_Map.GetPlayerMapPosition = nil
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(px)
			assert.is_nil(py)
			assert.is_not_nil(err)
		end)

		it("returns nil + error when GetPlayerMapPosition returns nil (no player position)", function()
			local ns = Setup()
			_G.C_Map = MakeCMap()
			-- Unknown mapID → returns nil
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, 999)
			assert.is_nil(px)
			assert.is_nil(py)
			assert.is_not_nil(err)
			assert.truthy(err:find("GetPlayerMapPosition", 1, true))
		end)

		it("returns nil + error when GetWorldPosFromMapPos returns nil", function()
			local ns = Setup()
			local cmap = MakeCMap()
			cmap.GetWorldPosFromMapPos = function() return nil, nil end
			_G.C_Map = cmap
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(px)
			assert.is_nil(py)
			assert.is_not_nil(err)
		end)

		it("returns nil + error when Minimap global frame is nil", function()
			local ns = Setup()
			_G.Minimap = nil
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(px)
			assert.is_nil(py)
			assert.is_not_nil(err)
		end)

		it("returns nil + error when Minimap frame reports zero width", function()
			local ns = Setup()
			_G.Minimap = MakeFrame(0, 0)
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(px)
			assert.is_nil(py)
			assert.is_not_nil(err)
			assert.truthy(err:find("zero", 1, true))
		end)

		it("falls back to default radius when GetCVar is unavailable", function()
			local ns = Setup()
			_G.GetCVar = nil
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(err)
			assert.are.equal(0, px)
			assert.are.equal(0, py)
		end)

		it("falls back to default radius when GetCVar returns non-numeric string", function()
			local ns = Setup()
			_G.GetCVar = function() return "invalid" end
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(err)
		end)

		it("uses zoom level 0 (most zoomed out) correctly", function()
			local ns = Setup()
			_G.GetCVar = function(key)
				if key == "minimapZoom" then return "0" end
			end
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(err)
			assert.are.equal(0, px)
			assert.are.equal(0, py)
		end)

		it("uses zoom level 5 (most zoomed in) correctly", function()
			local ns = Setup()
			_G.GetCVar = function(key)
				if key == "minimapZoom" then return "5" end
			end
			local px, py, err = ns.NeighborhoodMinimap.GetPixelPositionFromMinimap(0.5, 0.5, MAP_ID)
			assert.is_nil(err)
			assert.are.equal(0, px)
			assert.are.equal(0, py)
		end)

	end)

	-- =========================================================================
	-- RenderPositions
	-- =========================================================================
	describe("RenderPositions", function()

		it("is a safe no-op when called before Create()", function()
			local ns = Setup()
			-- Do NOT call Create() — should handle gracefully, no error
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.textureCount)
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("hides all textures when given an empty positions table", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({}, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("hides all textures when positions is nil", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions(nil, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("hides all textures when currentMapID is nil", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, nil)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("skips entries whose mapID does not match currentMapID", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			-- Position on wrong map
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ mapID = 999 }) }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("renders a single dot for a valid position on the current map", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(1, diag.visiblePositions)
			assert.are.equal(1, diag.textureCount)
		end)

		it("renders multiple dots for multiple valid positions", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			local positions = {
				Pos({ battleTag="A#1", x=0.4, y=0.5 }),
				Pos({ battleTag="B#2", x=0.5, y=0.5 }),
				Pos({ battleTag="C#3", x=0.6, y=0.5 }),
			}
			ns.NeighborhoodMinimap.RenderPositions(positions, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(3, diag.visiblePositions)
			assert.are.equal(3, diag.textureCount)
		end)

		it("mixes valid and wrong-map positions — only same-map positions rendered", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			local positions = {
				Pos({ battleTag="A#1" }),           -- correct map
				Pos({ battleTag="B#2", mapID=999 }), -- wrong map
				Pos({ battleTag="C#3" }),            -- correct map
			}
			ns.NeighborhoodMinimap.RenderPositions(positions, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(2, diag.visiblePositions)
		end)

		it("increments renderErrors when coordinate conversion fails", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			-- Remove C_Map so conversion fails
			_G.C_Map = nil
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(1, diag.renderErrors)
			assert.are.equal(0, diag.visiblePositions)
		end)

		it("accumulates renderErrors across multiple failing renders", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			_G.C_Map = nil
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(2, diag.renderErrors)
		end)

		it("applies WARRIOR class color (no renderError)", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ classFile="WARRIOR" }) }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
			assert.are.equal(1, diag.visiblePositions)
		end)

		it("applies MAGE class color (no renderError)", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ classFile="MAGE" }) }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
			assert.are.equal(1, diag.visiblePositions)
		end)

		it("falls back to white for unknown classFile (no renderError)", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ classFile="UNKNOWN_CLASS" }) }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			-- Unknown class should NOT be a renderError — it uses white fallback
			assert.are.equal(0, diag.renderErrors)
			assert.are.equal(1, diag.visiblePositions)
		end)

		it("falls back to white when classFile is nil (no renderError)", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			local pos = Pos()  -- no classFile set
			ns.NeighborhoodMinimap.RenderPositions({ pos }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
			assert.are.equal(1, diag.visiblePositions)
		end)

		it("falls back gracefully when RAID_CLASS_COLORS is nil", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			_G.RAID_CLASS_COLORS = nil
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ classFile="WARRIOR" }) }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.renderErrors)
			assert.are.equal(1, diag.visiblePositions)
		end)

	end)

	-- =========================================================================
	-- Texture pool behaviour
	-- =========================================================================
	describe("Texture pool", function()

		it("reuses textures across renders (pool grows monotonically)", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			-- First render with 3 positions → 3 textures allocated
			ns.NeighborhoodMinimap.RenderPositions({
				Pos({ battleTag="A#1" }),
				Pos({ battleTag="B#2" }),
				Pos({ battleTag="C#3" }),
			}, MAP_ID)
			assert.are.equal(3, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)

			-- Second render with 1 position → pool stays at 3, only 1 visible
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ battleTag="A#1" }) }, MAP_ID)
			assert.are.equal(3, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)
			assert.are.equal(1, ns.NeighborhoodMinimap.GetDiagnostics().visiblePositions)
		end)

		it("pool grows to accommodate more positions on subsequent render", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ battleTag="A#1" }) }, MAP_ID)
			assert.are.equal(1, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)

			ns.NeighborhoodMinimap.RenderPositions({
				Pos({ battleTag="A#1" }),
				Pos({ battleTag="B#2" }),
			}, MAP_ID)
			assert.are.equal(2, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)
			assert.are.equal(2, ns.NeighborhoodMinimap.GetDiagnostics().visiblePositions)
		end)

		it("excess textures are hidden after render reduces position count", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({
				Pos({ battleTag="A#1" }),
				Pos({ battleTag="B#2" }),
			}, MAP_ID)
			-- Pool has 2 textures, both visible
			assert.are.equal(2, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)
			assert.are.equal(2, ns.NeighborhoodMinimap.GetDiagnostics().visiblePositions)

			-- Render with 1 — second texture should be hidden
			ns.NeighborhoodMinimap.RenderPositions({ Pos({ battleTag="A#1" }) }, MAP_ID)
			assert.are.equal(2, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)
			assert.are.equal(1, ns.NeighborhoodMinimap.GetDiagnostics().visiblePositions)
		end)

		it("all textures hidden when empty list rendered after non-empty", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			assert.are.equal(1, ns.NeighborhoodMinimap.GetDiagnostics().visiblePositions)

			ns.NeighborhoodMinimap.RenderPositions({}, MAP_ID)
			assert.are.equal(0, ns.NeighborhoodMinimap.GetDiagnostics().visiblePositions)
			-- Pool size unchanged
			assert.are.equal(1, ns.NeighborhoodMinimap.GetDiagnostics().textureCount)
		end)

	end)

	-- =========================================================================
	-- GetDiagnostics
	-- =========================================================================
	describe("GetDiagnostics", function()

		it("returns the required keys in correct shape before any render", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal("number", type(diag.textureCount))
			assert.are.equal("number", type(diag.visiblePositions))
			assert.are.equal("number", type(diag.renderErrors))
			-- lastRenderTime is nil before first render
			assert.is_nil(diag.lastRenderTime)
		end)

		it("initialises textureCount, visiblePositions, renderErrors all to zero", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(0, diag.textureCount)
			assert.are.equal(0, diag.visiblePositions)
			assert.are.equal(0, diag.renderErrors)
		end)

		it("updates lastRenderTime after RenderPositions call", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			assert.is_nil(ns.NeighborhoodMinimap.GetDiagnostics().lastRenderTime)
			ns.NeighborhoodMinimap.RenderPositions({ Pos() }, MAP_ID)
			assert.is_not_nil(ns.NeighborhoodMinimap.GetDiagnostics().lastRenderTime)
		end)

		it("lastRenderTime is set even when all positions are skipped (no dots rendered)", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			ns.NeighborhoodMinimap.RenderPositions({}, MAP_ID)
			-- time() was called → lastRenderTime should be set
			assert.is_not_nil(ns.NeighborhoodMinimap.GetDiagnostics().lastRenderTime)
		end)

		it("reflects accumulated renderErrors correctly", function()
			local ns = Setup()
			ns.NeighborhoodMinimap.Create()
			_G.C_Map = nil
			ns.NeighborhoodMinimap.RenderPositions({ Pos(), Pos({ battleTag="B#2" }) }, MAP_ID)
			local diag = ns.NeighborhoodMinimap.GetDiagnostics()
			assert.are.equal(2, diag.renderErrors)
		end)

	end)

	-- =========================================================================
	-- Init
	-- =========================================================================
	describe("Init", function()

		local function SetupWithInit(guid, positions)
			guid = guid or "NG-TEST"
			positions = positions or {}
			local ns2 = Setup()
			local changeListeners = {}
			ns2.PositionService = {
				GetAllByNeighborhood = function(g)
					if g == guid then return positions end
					return {}
				end,
				RegisterChangeListener = function(fn)
					table.insert(changeListeners, fn)
				end,
			}
			ns2.API = { GetActiveNeighborhoodGUID = function() return guid end }
			_G.C_Map.GetBestMapForUnit = function() return MAP_ID end
			local helpers = {}
			helpers.fireChange = function()
				for _, fn in ipairs(changeListeners) do fn() end
			end
			return ns2, helpers
		end

		it("Init() is idempotent — second call is a no-op", function()
			local ns2, helpers = SetupWithInit()
			local listenerCount = 0
			ns2.PositionService.RegisterChangeListener = function()
				listenerCount = listenerCount + 1
			end
			ns2.NeighborhoodMinimap.Init()
			ns2.NeighborhoodMinimap.Init()
			assert.are.equal(1, listenerCount)
		end)

		it("Init() skips initialization when privacy opt-out is enabled", function()
			local ns2, helpers = SetupWithInit()
			local listenerCount = 0
			ns2.PositionService.RegisterChangeListener = function()
				listenerCount = listenerCount + 1
			end
			ns2.Settings = { GetPositionOptOut = function() return true end }
			ns2.NeighborhoodMinimap.Init()
			-- No listener registered — Init returned early
			assert.are.equal(0, listenerCount)
		end)

		it("Init() proceeds normally when privacy opt-out is disabled", function()
			local ns2, helpers = SetupWithInit()
			local listenerCount = 0
			ns2.PositionService.RegisterChangeListener = function()
				listenerCount = listenerCount + 1
			end
			ns2.Settings = { GetPositionOptOut = function() return false end }
			ns2.NeighborhoodMinimap.Init()
			assert.are.equal(1, listenerCount)
		end)

	end)

end)
