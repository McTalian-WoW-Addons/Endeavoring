---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local NeighborhoodMap = {}
ns.NeighborhoodMap = NeighborhoodMap

--[[
NeighborhoodMap Feature

PURPOSE:
Renders colored dot pins on the World Map for players in the same neighborhood.
Uses WoW's MapCanvas data provider / pin system (MapCanvasDataProviderMixin +
MapCanvasPinMixin) — the same system Blizzard uses for all world map overlays.

COORDINATE SYSTEM:
  Positions are stored as normalized (0-1) fractions from C_Map.GetPlayerMapPosition().
  pin:SetPosition(x, y) takes these fractions directly — no coordinate math needed.

CLASS COLORS:
  Position entries carry classFile (e.g. "WARRIOR") for RAID_CLASS_COLORS lookup.
  Falls back to white.

LIFECYCLE:
  NeighborhoodMap.Init() → registers data provider with WorldMapFrame once.
  Data provider RefreshAllData() → acquires pins and sets positions.
  Data provider RemoveAllData() → releases all pins back to pool.
--]]

-- Shortcuts
local ERROR      = ns.Constants and ns.Constants.PREFIX_ERROR or ("|cffff0000" .. addonName .. ":|r")
local DebugPrint = ns.DebugPrint

-- Pin template name — must match the XML template defined in NeighborhoodMap.xml
local PIN_TEMPLATE = "EndeavoringNeighborPinTemplate"

-- State
local dataProvider   = nil
local renderErrors   = 0
local lastRenderTime = nil
local visibleCount   = 0
local initialized    = false

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Return the RGBA color for a given classFile string (e.g. "WARRIOR").
--- Falls back to white (1, 1, 1) for unknown or nil classFile.
--- @param classFile string|nil
--- @return number r, number g, number b
local function GetClassColor(classFile)
	if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
		local c = RAID_CLASS_COLORS[classFile]
		return c.r, c.g, c.b
	end
	return 1, 1, 1
end

--- Fetch all positions for the current neighborhood.
--- @return table positions array of position entries
--- @return string|nil neighborhoodGUID
local function GetCurrentPositions()
	local guid = ns.API and ns.API.GetActiveNeighborhoodGUID and ns.API.GetActiveNeighborhoodGUID()
	if not guid or not ns.PositionService then return {}, nil end
	return ns.PositionService.GetAllByNeighborhood(guid), guid
end

-- ---------------------------------------------------------------------------
-- Data Provider
-- ---------------------------------------------------------------------------

local EndeavoringNeighborDataProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function EndeavoringNeighborDataProviderMixin:RemoveAllData()
	self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
	visibleCount = 0
end

function EndeavoringNeighborDataProviderMixin:RefreshAllData()
	self:RemoveAllData()

	lastRenderTime = time()

	local currentMapID = self:GetMap():GetMapID()
	local positions, _ = GetCurrentPositions()
	local count = positions and #positions or 0

	DebugPrint(string.format("[NeighborhoodMap] RefreshAllData: %d position(s) mapID=%s",
		count, tostring(currentMapID)))

	if count == 0 then return end

	for _, entry in ipairs(positions) do
		if entry.mapID ~= currentMapID then
			DebugPrint(string.format("[NeighborhoodMap] Skipping %s: mapID=%d vs current=%d",
				tostring(entry.battleTag), entry.mapID, currentMapID))
		else
			-- entry.x and entry.y are already normalized (0-1) fractions
			local pin = self:GetMap():AcquirePin(PIN_TEMPLATE)
			if pin then
				local r, g, b = GetClassColor(entry.classFile)
				local label = ns.GetTooltipLabel and ns.GetTooltipLabel(entry) or entry.battleTag
				pin:SetupDot(entry.battleTag, label, r, g, b)
				pin:SetPosition(entry.x, entry.y)
				visibleCount = visibleCount + 1
				DebugPrint(string.format("[NeighborhoodMap] Pin for %s at (%.3f, %.3f) class=%s",
					tostring(entry.battleTag), entry.x, entry.y, tostring(entry.classFile)))
			else
				renderErrors = renderErrors + 1
				DebugPrint(string.format("%s [NeighborhoodMap] AcquirePin failed for %s",
					ERROR, tostring(entry.battleTag)))
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Initialize NeighborhoodMap: register data provider with WorldMapFrame.
--- Called once from Core.lua on PLAYER_ENTERING_WORLD.
function NeighborhoodMap.Init()
	if initialized then return end

	if ns.Settings and ns.Settings.GetPositionOptOut and ns.Settings.GetPositionOptOut() then
		DebugPrint("[NeighborhoodMap] Init skipped — position opt-out is enabled")
		return
	end

	if not WorldMapFrame then
		DebugPrint(string.format("%s [NeighborhoodMap] WorldMapFrame unavailable at Init", ERROR))
		return
	end

	initialized = true

	dataProvider = CreateFromMixins(EndeavoringNeighborDataProviderMixin)
	WorldMapFrame:AddDataProvider(dataProvider)

	-- Refresh whenever the position cache changes and the map is open.
	-- Coalesce rapid updates with a short timer so multiple arrivals in the
	-- same frame batch into one render.
	if ns.PositionService and ns.PositionService.RegisterChangeListener then
		local pendingRefresh = false
		ns.PositionService.RegisterChangeListener(function()
			if not dataProvider or not WorldMapFrame:IsShown() then return end
			if not pendingRefresh then
				pendingRefresh = true
				C_Timer.After(0.1, function()
					pendingRefresh = false
					if dataProvider and WorldMapFrame:IsShown() then
						dataProvider:RefreshAllData()
					end
				end)
			end
		end)
	end

	DebugPrint("[NeighborhoodMap] Initialized — data provider registered")
end

--- Force a refresh (e.g. called from commands or tests).
function NeighborhoodMap.Refresh()
	if dataProvider then
		dataProvider:RefreshAllData()
	end
end

--- Shutdown and remove the data provider.
function NeighborhoodMap.Shutdown()
	if not initialized then return end
	if dataProvider then
		WorldMapFrame:RemoveDataProvider(dataProvider)
		dataProvider = nil
	end
	initialized = false
	DebugPrint("[NeighborhoodMap] Shutdown complete")
end

--- Return diagnostic snapshot.
function NeighborhoodMap.GetDiagnostics()
	return {
		visiblePositions = visibleCount,
		lastRenderTime   = lastRenderTime,
		renderErrors     = renderErrors,
	}
end
