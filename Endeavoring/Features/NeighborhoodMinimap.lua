---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local NeighborhoodMinimap = {}
ns.NeighborhoodMinimap = NeighborhoodMinimap

--[[
NeighborhoodMinimap Feature

PURPOSE:
Renders colored dot overlays on the Minimap for nearby players in the same
neighborhood. Each dot is a texture anchored to the Minimap frame. Dots are
colored by the player's class (when known) or fall back to white. The overlay
is always visible alongside the minimap (unlike NeighborhoodMap, there is no
open/close event for the minimap).

LIFECYCLE:
  NeighborhoodMinimap.Create()         → Call once on PLAYER_ENTERING_WORLD.
                                          Creates the parent frame anchored to Minimap.
  NeighborhoodMinimap.RenderPositions(positions, currentMapID)
                                        → Update visible dots. Filters positions by
                                          mapID. Converts world coordinates to minimap
                                          pixel coordinates via GetPixelPositionFromMinimap().
  NeighborhoodMinimap.Init()           → Called from Core.lua. Calls Create() and
                                          registers PositionService change listener.

COORDINATE CONVERSION:
  The minimap shows a circular region of the world centered on the player. The
  visible radius in world yards is determined by the minimap zoom level, retrieved
  via GetCVar("minimapZoom") or C_MiniMap (not available pre-11.x). We use
  C_Map.GetPlayerMapPosition() to get the player's map-fraction position, then
  C_Map.GetWorldPosFromMapPos() to convert both player and target positions to
  world-space yards. The relative world offset (dx, dy) is then scaled by the
  minimap's pixel-per-yard ratio.

  Minimap north is map north. The mapping from world-Y-axis to minimap vertical
  is inverted (positive world-Y is downward on map, but positive screen-Y is
  upward), so we negate the vertical offset.

  If any API call fails or the player's position is unavailable, the dot is
  skipped and renderErrors is incremented.

CLASS COLORS:
  Position entries that carry a `classFile` field (e.g. "WARRIOR", "MAGE") are
  colored via RAID_CLASS_COLORS. Entries without classFile receive white (1,1,1).

OBSERVABILITY:
  NeighborhoodMinimap.GetDiagnostics() → {textureCount, visiblePositions, lastRenderTime, renderErrors}
  DebugPrint logs each RenderPositions call with position count and map ID.
  PREFIX_ERROR logs on coordinate conversion failures or missing RAID_CLASS_COLORS entries.
--]]

-- Constants
local DOT_SIZE = 8  -- dot diameter in pixels for minimap dots (slightly smaller than world map)

-- Default minimap zoom radius in yards when CVar is unavailable.
-- Blizzard's default "medium" zoom is ~150 yards radius.
local DEFAULT_MINIMAP_RADIUS_YARDS = 150

-- Shortcuts
local ERROR      = ns.Constants and ns.Constants.PREFIX_ERROR or ("|cffff0000" .. addonName .. ":|r")
local DebugPrint = ns.DebugPrint

-- State
local parentFrame    = nil  -- Frame parented to Minimap
local dotPool        = {}   -- All allocated dot Buttons (reused across renders)
local renderErrors   = 0    -- Cumulative coordinate conversion errors
local lastRenderTime = nil  -- Timestamp of most recent RenderPositions call
local visibleCount   = 0    -- Number of dots shown in the last render

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return the RGBA color for a given classFile string (e.g. "WARRIOR").
--- Falls back to white (1, 1, 1) for unknown or nil classFile.
--- @param classFile string|nil WoW class file constant (e.g. "WARRIOR", "MAGE")
--- @return number r, number g, number b
local function GetClassColor(classFile)
	if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
		local c = RAID_CLASS_COLORS[classFile]
		return c.r, c.g, c.b
	end
	if classFile then
		DebugPrint(string.format("%s [NeighborhoodMinimap] Unknown classFile=%s; using default color",
			ERROR, tostring(classFile)))
	end
	return 1, 1, 1
end

--- Return the current minimap radius in yards.
--- Reads the "minimapZoom" CVar which stores 0–5 as an integer zoom level.
--- Each zoom step roughly halves/doubles the visible area; we use a lookup table.
--- Falls back to DEFAULT_MINIMAP_RADIUS_YARDS if the CVar is unavailable.
--- @return number radiusYards
local function GetMinimapRadiusYards()
	-- Zoom level 0 = most zoomed out, 5 = most zoomed in.
	-- Empirically: zoom 0 ~233 yd, 1 ~166, 2 ~133, 3 ~100, 4 ~83, 5 ~66
	local zoomTable = {233, 166, 133, 100, 83, 66}
	local ok, zoomStr = pcall(GetCVar, "minimapZoom")
	if ok and zoomStr then
		local zoom = tonumber(zoomStr)
		if zoom then
			local level = math.max(1, math.min(#zoomTable, math.floor(zoom) + 1))
			return zoomTable[level]
		end
	end
	return DEFAULT_MINIMAP_RADIUS_YARDS
end

--- Get or create a dot Button from the pool at the given index.
--- Buttons (unlike bare textures) receive mouse events, enabling tooltips.
--- @param index number 1-based index in the dot pool
--- @return table button WoW Button frame with an embedded dot texture
local function GetOrCreateDot(index)
	if not dotPool[index] then
		local btn = CreateFrame("Button", nil, parentFrame)
		btn:SetSize(DOT_SIZE, DOT_SIZE)
		btn:SetFrameLevel(parentFrame:GetFrameLevel() + 1)

		local tex = btn:CreateTexture(nil, "OVERLAY")
		tex:SetAllPoints(btn)
		tex:SetColorTexture(1, 1, 1, 1)
		btn.dot = tex

		btn:SetScript("OnEnter", function(self)
			if self.tooltipLabel then
				GameTooltip:SetOwner(self, "ANCHOR_LEFT")
				GameTooltip:SetText(self.tooltipLabel, 1, 1, 1, 1, true)
				GameTooltip:Show()
			end
		end)
		btn:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then
				GameTooltip:Hide()
			end
		end)

		dotPool[index] = btn
	end
	return dotPool[index]
end

--- Hide all dots in the pool from index `from` to end.
--- @param from number First index to hide (1-based)
local function HideDotsFrom(from)
	for i = from, #dotPool do
		dotPool[i]:Hide()
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Convert normalized map position to minimap pixel offsets from center.
---
--- Algorithm:
---   1. Get the player's current normalized position via C_Map.GetPlayerMapPosition().
---   2. Compute normalized frac delta (dx, dy) from player to target.
---   3. Convert frac delta to world yards using GetWorldPosFromMapPos extents.
---   4. Scale yards delta to pixels using minimap radius (yards/pixel ratio).
---   5. Clamp to just inside the circular boundary.
---
--- @param fracX number Normalized X (0-1) of target position
--- @param fracY number Normalized Y (0-1) of target position
--- @param mapID number Map ID the target position was recorded on
--- @return number|nil offsetX, number|nil offsetY, string|nil errMsg
function NeighborhoodMinimap.GetPixelPositionFromMinimap(fracX, fracY, mapID)
	if not C_Map or not C_Map.GetPlayerMapPosition or not C_Map.GetWorldPosFromMapPos then
		return nil, nil, "C_Map API unavailable"
	end

	-- Player's normalized position on this map
	local playerPos = C_Map.GetPlayerMapPosition(mapID, "player")
	if not playerPos then
		return nil, nil, string.format("GetPlayerMapPosition returned nil for mapID=%d", mapID)
	end

	-- Get world extents to derive yards-per-normalized-unit
	local mkVec = CreateVector2D and CreateVector2D or function(x, y) return {x=x, y=y} end
	local _, topLeft  = C_Map.GetWorldPosFromMapPos(mapID, mkVec(0, 0))
	local _, botRight = C_Map.GetWorldPosFromMapPos(mapID, mkVec(1, 1))
	if not topLeft or not botRight then
		return nil, nil, string.format("GetWorldPosFromMapPos returned nil for mapID=%d", mapID)
	end

	-- worldPos.y = horizontal axis, worldPos.x = vertical axis (confirmed by world map testing)
	local yardsPerFracH = math.abs(botRight.y - topLeft.y)
	local yardsPerFracV = math.abs(botRight.x - topLeft.x)

	if yardsPerFracH == 0 or yardsPerFracV == 0 then
		return nil, nil, string.format("Map extents are zero for mapID=%d", mapID)
	end

	-- Normalized frac delta from player to target
	local dFracX = fracX - playerPos.x
	local dFracY = fracY - playerPos.y

	-- Convert to world yards
	local dxYards =  dFracX * yardsPerFracH   -- positive = east
	local dyYards =  dFracY * yardsPerFracV   -- positive = south

	-- Minimap pixel radius
	local mmFrame = Minimap
	if not mmFrame then return nil, nil, "Minimap frame unavailable" end
	local mmWidth = mmFrame:GetWidth()
	if not mmWidth or mmWidth == 0 then return nil, nil, "Minimap has zero width" end
	local pixelRadius = mmWidth / 2.0

	local radiusYards = GetMinimapRadiusYards()

	-- Scale to pixels: right = +X, up = -Y (minimap Y is inverted vs world Y)
	local pixelX =  (dxYards / radiusYards) * pixelRadius
	local pixelY = -(dyYards / radiusYards) * pixelRadius

	-- Clamp to 95% of minimap circle radius
	local dist = math.sqrt(pixelX * pixelX + pixelY * pixelY)
	if dist > pixelRadius * 0.95 then
		local scale = (pixelRadius * 0.95) / dist
		pixelX = pixelX * scale
		pixelY = pixelY * scale
	end

	return pixelX, pixelY, nil
end

--- Create the NeighborhoodMinimap overlay frame, anchored to the Minimap frame.
--- Safe to call once. Subsequent calls are no-ops.
function NeighborhoodMinimap.Create()
	if parentFrame then
		return
	end

	-- Anchor to Minimap if available, fall back to UIParent
	local mmParent = Minimap or UIParent
	parentFrame = CreateFrame("Frame", "EndeavoringNeighborhoodMinimapOverlay", mmParent)
	parentFrame:SetAllPoints(mmParent)
	parentFrame:SetFrameLevel(
		(mmParent.GetFrameLevel and mmParent:GetFrameLevel() or 0) + 5
	)
	-- Minimap overlay is always shown (no open/close event like WorldMapFrame)
	parentFrame:Show()

	DebugPrint("[NeighborhoodMinimap] Overlay frame created")
end

--- Render position dots on the minimap for the given entries.
--- Positions whose mapID does not match currentMapID are skipped.
--- Each position may optionally carry a `classFile` field for class-colored dots.
---
--- @param positions table[] Array of position entries from PositionService.GetAllByNeighborhood().
---                          Each entry: {x, y, mapID, battleTag, neighborhoodGUID, [classFile]}
--- @param currentMapID number The player's current map (from C_Map.GetBestMapForUnit("player"))
function NeighborhoodMinimap.RenderPositions(positions, currentMapID)
	if not parentFrame then
		DebugPrint(string.format("%s [NeighborhoodMinimap] RenderPositions called before Create()", ERROR))
		return
	end

	lastRenderTime = time()
	local count = positions and #positions or 0
	DebugPrint(string.format("[NeighborhoodMinimap] RenderPositions: %d position(s) mapID=%s",
		count, tostring(currentMapID)))

	-- No positions or no map → hide all dots
	if count == 0 or not currentMapID then
		HideDotsFrom(1)
		visibleCount = 0
		return
	end

	local dotIndex = 0

	for _, entry in ipairs(positions) do
		-- Skip positions not on the current map
		if entry.mapID ~= currentMapID then
			DebugPrint(string.format("[NeighborhoodMinimap] Skipping %s: mapID=%d vs current=%d",
				tostring(entry.battleTag), entry.mapID, currentMapID))
		else
			local offsetX, offsetY, err = NeighborhoodMinimap.GetPixelPositionFromMinimap(
				entry.x, entry.y, entry.mapID
			)

			if err then
				renderErrors = renderErrors + 1
				DebugPrint(string.format("%s [NeighborhoodMinimap] Coord conversion failed for %s: %s",
					ERROR, tostring(entry.battleTag), err))
			elseif offsetX and offsetY then
				dotIndex = dotIndex + 1
				local dot = GetOrCreateDot(dotIndex)

				-- Position dot relative to Minimap CENTER using pixel offset
				dot:ClearAllPoints()
				dot:SetPoint("CENTER", parentFrame, "CENTER", offsetX, offsetY)

				-- Apply class color
				local r, g, b = GetClassColor(entry.classFile)
				dot.dot:SetVertexColor(r, g, b, 1)

				-- Tooltip label: character name if available, else battleTag prefix
				dot.tooltipLabel = ns.GetTooltipLabel and ns.GetTooltipLabel(entry)
					or entry.battleTag

				dot:Show()

				DebugPrint(string.format("[NeighborhoodMinimap] Dot %d for %s at offset=(%.1f, %.1f) class=%s",
					dotIndex, tostring(entry.battleTag), offsetX, offsetY, tostring(entry.classFile)))
			end
		end
	end

	-- Hide unused dots (pool monotonically grows, excess are hidden)
	HideDotsFrom(dotIndex + 1)
	visibleCount = dotIndex
end

--- Re-render positions using current PositionService state and current map.
--- Called whenever PositionService cache changes.
local function RefreshFromPositionService()
	if not parentFrame then return end
	local currentMapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if not currentMapID then
		DebugPrint(string.format("%s [NeighborhoodMinimap] RefreshFromPositionService: no current mapID; skipping render", ERROR))
		return
	end
	local guid = ns.API and ns.API.GetActiveNeighborhoodGUID and ns.API.GetActiveNeighborhoodGUID()
	local positions = {}
	if guid and ns.PositionService then
		positions = ns.PositionService.GetAllByNeighborhood(guid)
	end
	NeighborhoodMinimap.RenderPositions(positions, currentMapID)
end

--- Initialize NeighborhoodMinimap: create the overlay frame and register for
--- PositionService cache changes. Unlike NeighborhoodMap, there is no
--- WorldMapFrame open/close event — the minimap is always visible.
--- Called once from Core.lua on PLAYER_ENTERING_WORLD.
--- Safe to call multiple times — subsequent calls are no-ops.
local initialized = false
function NeighborhoodMinimap.Init()
	if initialized then return end

	-- Privacy opt-out: skip rendering entirely if the player has opted out
	if ns.Settings and ns.Settings.GetPositionOptOut and ns.Settings.GetPositionOptOut() then
		DebugPrint("[NeighborhoodMinimap] Init skipped — position opt-out is enabled")
		return
	end

	initialized = true

	NeighborhoodMinimap.Create()

	-- Register for PositionService updates so we re-render whenever
	-- the position cache changes. Coalesce rapid updates into one render.
	if ns.PositionService and ns.PositionService.RegisterChangeListener then
		local pendingRefresh = false
		ns.PositionService.RegisterChangeListener(function()
			if not pendingRefresh then
				pendingRefresh = true
				C_Timer.After(0.1, function()
					pendingRefresh = false
					RefreshFromPositionService()
				end)
			end
		end)
	end

	DebugPrint("[NeighborhoodMinimap] Initialized")
end

--- Shutdown the minimap overlay and clean up resources.
--- Hides all textures in the pool and unregisters from position updates.
--- Called when leaving a neighborhood.
function NeighborhoodMinimap.Shutdown()
	if not initialized then
		return
	end

	-- Hide all dots in the pool
	for _, dot in ipairs(dotPool) do
		dot:Hide()
	end

	initialized = false
	DebugPrint("[NeighborhoodMinimap] Shutdown complete")
end

--- Return diagnostic snapshot for runtime inspection.
--- @return table diagnostics {textureCount, visiblePositions, lastRenderTime, renderErrors}
function NeighborhoodMinimap.GetDiagnostics()
	return {
		textureCount     = #dotPool,
		visiblePositions = visibleCount,
		lastRenderTime   = lastRenderTime,
		renderErrors     = renderErrors,
	}
end
