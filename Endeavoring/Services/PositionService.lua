---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local PositionService = {}
ns.PositionService = PositionService

--[[
Position Cache Service

PURPOSE:
Caches real-time position data for players in the same neighborhood, keyed by
BattleTag. Used by the minimap overlay (S03/S04) to render neighbor positions
without repeatedly querying protocol state.

DATA MODEL:
Each cache entry is a table:
  { x, y, mapID, battleTag, neighborhoodGUID, timestamp }

SCOPING:
Positions are scoped by neighborhoodGUID so GetAllByNeighborhood() returns only
players who were last seen in a specific neighborhood.

STALE CLEANUP:
Positions older than STALE_THRESHOLD_SECONDS are removed by a periodic timer
started in PositionService.Init(). Stale entries do not raise errors; they are
silently pruned and logged.

LIFECYCLE:
  PositionService.Init() → starts cleanup timer; called from Core.lua on PLAYER_ENTERING_WORLD.
  PositionService.Set()  → upsert a position entry.
  PositionService.Get()  → retrieve a single entry by BattleTag.
  PositionService.GetAllByNeighborhood() → all entries for a neighborhood GUID.
  PositionService.Clear() → remove all entries (used on logout / test teardown).
  PositionService.GetDiagnostics() → runtime inspection of cache state.
--]]

-- Constants
local STALE_THRESHOLD_SECONDS = 60
local CLEANUP_INTERVAL_SECONDS = 30

-- Shortcuts
local ERROR = ns.Constants and ns.Constants.PREFIX_ERROR or ("|cffff0000" .. addonName .. ":|r")
local DebugPrint = ns.DebugPrint

-- State
--- @type table<string, {x:number, y:number, mapID:number, battleTag:string, neighborhoodGUID:string, timestamp:number}>
local cache = {}
local lastUpdate = nil
local cleanupTimer = nil
local changeListeners = {}  -- callbacks registered via RegisterChangeListener

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Returns the number of stale entries in cache without removing them.
local function CountStale()
	local now = time()
	local count = 0
	for _, entry in pairs(cache) do
		if (now - entry.timestamp) > STALE_THRESHOLD_SECONDS then
			count = count + 1
		end
	end
	return count
end

--- Core cleanup: removes entries older than STALE_THRESHOLD_SECONDS.
local function RunCleanup()
	local now = time()
	local removed = 0
	for battleTag, entry in pairs(cache) do
		if (now - entry.timestamp) > STALE_THRESHOLD_SECONDS then
			cache[battleTag] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		DebugPrint(string.format("[PositionService] Cleaned up %d stale position(s)", removed))
	end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Store or update a player's position.
--- @param battleTag string The player's BattleTag (non-empty).
--- @param position table {x:number, y:number, mapID:number, neighborhoodGUID:string}
--- @param timestamp number|nil Unix timestamp (defaults to now).
function PositionService.Set(battleTag, position, timestamp)
	if not battleTag or battleTag == "" then
		DebugPrint(string.format("%s PositionService.Set: battleTag is required", ERROR))
		return
	end
	if not position then
		DebugPrint(string.format("%s PositionService.Set: position is required for %s", ERROR, tostring(battleTag)))
		return
	end
	if type(position.x) ~= "number" or type(position.y) ~= "number" then
		DebugPrint(string.format("%s PositionService.Set: x and y must be numbers for %s", ERROR, tostring(battleTag)))
		return
	end
	if type(position.mapID) ~= "number" then
		DebugPrint(string.format("%s PositionService.Set: mapID must be a number for %s", ERROR, tostring(battleTag)))
		return
	end
	if not position.neighborhoodGUID or position.neighborhoodGUID == "" then
		DebugPrint(string.format("%s PositionService.Set: neighborhoodGUID is required for %s", ERROR, tostring(battleTag)))
		return
	end

	local ts = timestamp or time()
	cache[battleTag] = {
		x = position.x,
		y = position.y,
		mapID = position.mapID,
		battleTag = battleTag,
		neighborhoodGUID = position.neighborhoodGUID,
		timestamp = ts,
		classFile = position.classFile,
	}
	lastUpdate = ts
	DebugPrint(string.format("[PositionService] Set position for %s at (%.2f, %.2f) mapID=%d neighborhood=%s ts=%d",
		battleTag, position.x, position.y, position.mapID, tostring(position.neighborhoodGUID), ts))
	-- Notify registered listeners that the cache has changed
	for _, fn in ipairs(changeListeners) do
		local ok, err = pcall(fn)
		if not ok then
			DebugPrint(string.format("%s PositionService.Set: changeListener error: %s", ERROR, tostring(err)))
		end
	end
end

--- Retrieve a cached position by BattleTag.
--- @param battleTag string
--- @return table|nil entry {x, y, mapID, battleTag, neighborhoodGUID, timestamp}, or nil if not found.
function PositionService.Get(battleTag)
	if not battleTag or battleTag == "" then
		DebugPrint(string.format("%s PositionService.Get: battleTag is required", ERROR))
		return nil
	end
	local entry = cache[battleTag]
	DebugPrint(string.format("[PositionService] Get %s -> %s", battleTag, entry and "found" or "miss"))
	return entry
end

--- Return all cached positions for the given neighborhood.
--- @param neighborhoodGUID string
--- @return table[] entries List of position entries; may be empty.
function PositionService.GetAllByNeighborhood(neighborhoodGUID)
	if not neighborhoodGUID or neighborhoodGUID == "" then
		DebugPrint(string.format("%s PositionService.GetAllByNeighborhood: neighborhoodGUID is required", ERROR))
		return {}
	end
	local results = {}
	for _, entry in pairs(cache) do
		if entry.neighborhoodGUID == neighborhoodGUID then
			table.insert(results, entry)
		end
	end
	DebugPrint(string.format("[PositionService] GetAllByNeighborhood %s -> %d entries", tostring(neighborhoodGUID), #results))
	return results
end

--- Remove all cached positions and notify change listeners.
function PositionService.Clear()
	local count = 0
	for _ in pairs(cache) do
		count = count + 1
	end
	cache = {}
	lastUpdate = nil
	DebugPrint(string.format("[PositionService] Clear: removed %d entries", count))
	-- Notify listeners so minimap/map clear their dots immediately
	for _, fn in ipairs(changeListeners) do
		local ok, err = pcall(fn)
		if not ok then
			DebugPrint(string.format("%s PositionService.Clear: changeListener error: %s", ERROR, tostring(err)))
		end
	end
end

--- Register a callback to be invoked whenever the position cache is updated via Set().
--- Callbacks receive no arguments. Errors in callbacks are caught and logged.
--- @param fn function Callback function.
function PositionService.RegisterChangeListener(fn)
	if type(fn) ~= "function" then
		DebugPrint(string.format("%s PositionService.RegisterChangeListener: fn must be a function", ERROR))
		return
	end
	table.insert(changeListeners, fn)
	DebugPrint(string.format("[PositionService] RegisterChangeListener: now %d listener(s)", #changeListeners))
end

--- Return diagnostic snapshot for runtime inspection.
--- @return table diagnostics {cacheSize, staleCount, lastUpdate}
function PositionService.GetDiagnostics()
	local cacheSize = 0
	for _ in pairs(cache) do
		cacheSize = cacheSize + 1
	end
	return {
		cacheSize = cacheSize,
		staleCount = CountStale(),
		lastUpdate = lastUpdate,
	}
end

-- ---------------------------------------------------------------------------
-- Cleanup timer
-- ---------------------------------------------------------------------------

--- Start the periodic stale-position cleanup timer.
--- Safe to call multiple times — creates only one timer.
function PositionService.StartCleanupTimer()
	if cleanupTimer then
		return
	end
	cleanupTimer = C_Timer.NewTicker(CLEANUP_INTERVAL_SECONDS, RunCleanup)
	DebugPrint(string.format("[PositionService] Cleanup timer started (interval=%ds, stale_threshold=%ds)",
		CLEANUP_INTERVAL_SECONDS, STALE_THRESHOLD_SECONDS))
end

--- Initialize the service: start cleanup timer.
--- Called from Core.lua on PLAYER_ENTERING_WORLD.
function PositionService.Init()
	PositionService.StartCleanupTimer()
	DebugPrint("[PositionService] Initialized") -- nocheck
end

--- Shutdown the service and clean up resources.
--- Stops the cleanup timer and clears all cached positions.
--- Called when leaving a neighborhood.
function PositionService.Shutdown()
	if cleanupTimer then
		cleanupTimer:Cancel()
		cleanupTimer = nil
	end

	-- Clear all cached positions
	PositionService.Clear()

	DebugPrint("[PositionService] Shutdown complete") -- nocheck
end
