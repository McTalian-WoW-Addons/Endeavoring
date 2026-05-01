---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local PositionBroadcaster = {}
ns.PositionBroadcaster = PositionBroadcaster

--[[
Position Broadcaster Service

PURPOSE:
Sends the player's current position over the active neighborhood channel during
movement and on stop.

BROADCAST STRATEGY:
  PLAYER_STARTED_MOVING → broadcast immediately, then start a 1.5s repeating
                          ticker (if not already running).
  PLAYER_STOPPED_MOVING → cancel the ticker, broadcast immediately with the
                          final stopped position.

This gives a smooth moving indicator (updates every 1.5s in flight) and an
accurate final dot when the player lands.

Why 1.5 seconds?
- WoW's addon message throttle is roughly 1 message per second on a custom channel.
- 1.5s gives comfortable headroom above the throttle floor.
- Position updates at 1.5s resolution are smooth enough for a minimap overlay
  without causing channel congestion.

GUARD CONDITIONS:
- No active neighborhood channel  → skip send, log PREFIX_ERROR
- No neighborhood GUID            → skip send, log PREFIX_ERROR
- AddonMessages not initialized   → SendMessage returns false; logged there
- BattleTag unavailable           → skip send, log PREFIX_ERROR

OBSERVABILITY:
  GetDiagnostics() → {lastBroadcastTime, tickerState, messagesSentCount}
  Every successful send → DebugPrint with timestamp
  Every failed send     → print(PREFIX_ERROR …)
--]]

-- Constants
local TICKER_SECONDS = 1.5

-- Shortcuts
local ERROR = ns.Constants and ns.Constants.PREFIX_ERROR or ("|cffff0000" .. addonName .. ":|r")
local DebugPrint = ns.DebugPrint

-- State
local initialized       = false
local active            = true  -- false after Shutdown(); blocks BroadcastPosition until re-Init
local activeTicker      = nil   -- C_Timer.NewTicker handle; non-nil means ticker is running
local lastBroadcastTime = nil   -- unix timestamp of the most recent successful send
local messagesSentCount = 0     -- total sends since Init()

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Fetch the player's current normalized map position.
--- Uses C_Map.GetPlayerMapPosition which returns normalized 0-1 fractions directly.
--- @return number|nil x  normalized horizontal (0=left, 1=right)
--- @return number|nil y  normalized vertical (0=top, 1=bottom)
--- @return number|nil mapID
local function GetPlayerPosition()
	local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	if not mapID then return nil, nil, nil end
	local pos = C_Map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then return nil, nil, nil end
	return pos.x, pos.y, mapID
end

-- ---------------------------------------------------------------------------
-- Core broadcast
-- ---------------------------------------------------------------------------

--- Send the player's current position over the active neighborhood channel.
--- Safe to call at any time; all guards are internal.
function PositionBroadcaster.BroadcastPosition()
	-- Guard: no-op if shut down (queued events or stale ticker firing after Shutdown)
	if not active then return end

	-- Guard: require an active neighborhood channel
	local neighborhoodGUID, channelName = ns.Position.GetActiveChannel()
	if not neighborhoodGUID then
		print(ERROR .. " [PositionBroadcaster] Cannot broadcast — no active neighborhood channel")
		return
	end

	-- Guard: get the cached channel number (resolved at join time)
	local channelNumber = ns.Position.GetActiveChannelNumber()
	if not channelNumber or channelNumber == 0 then
		print(ERROR .. string.format(
			" [PositionBroadcaster] Cannot broadcast — channel number not resolved (channel=%q channelNum=%s)",
			tostring(channelName),
			tostring(channelNumber)
		))
		return
	end

	-- Guard: require the player's BattleTag
	local battleTag = ns.PlayerInfo.GetBattleTag()
	if not battleTag then
		print(ERROR .. " [PositionBroadcaster] Cannot broadcast — BattleTag unavailable")
		return
	end

	-- Fetch current position
	local x, y, mapID = GetPlayerPosition()
	if not x or not y then
		print(ERROR .. " [PositionBroadcaster] Cannot broadcast — GetPlayerMapPosition returned nil")
		return
	end

	local ts = time()

	-- Get the player's class for colored dots
	local _, classFile = UnitClass("player")

	-- Build payload using short keys
	local payload = {
		[ns.SK.x]                = x,
		[ns.SK.y]                = y,
		[ns.SK.mapID]            = mapID,
		[ns.SK.neighborhoodGUID] = neighborhoodGUID,
		[ns.SK.timestamp]        = ts,
		[ns.SK.battleTag]        = battleTag,
	}

	if classFile then
		payload[ns.SK.classFile] = classFile
	end

	local message = ns.AddonMessages.BuildMessage(ns.MSG_TYPE.POSITION_UPDATE, payload)
	if not message then
		print(ERROR .. " [PositionBroadcaster] Failed to encode position message")
		return
	end

	local success = ns.AddonMessages.SendMessage(
		message,
		ns.AddonMessages.ChatType.Channel,
		tostring(channelNumber)
	)

	if success then
		lastBroadcastTime = ts
		messagesSentCount = messagesSentCount + 1
		DebugPrint(string.format(
			"[PositionBroadcaster] Sent POSITION_UPDATE: x=%.4f y=%.4f classFile=%s mapID=%s ng=%s ts=%d (total=%d)",
			x, y, tostring(classFile),
			tostring(mapID),
			neighborhoodGUID,
			ts,
			messagesSentCount
		))
	else
		print(ERROR .. string.format(
			" [PositionBroadcaster] SendMessage failed: x=%.4f y=%.4f mapID=%s ng=%s ts=%d",
			x, y,
			tostring(mapID),
			neighborhoodGUID,
			ts
		))
	end
end

-- ---------------------------------------------------------------------------
-- Movement handlers
-- ---------------------------------------------------------------------------

--- Called on PLAYER_STARTED_MOVING.
--- Broadcasts immediately (t=0 sample), then starts a repeating ticker for
--- subsequent samples while movement continues. Idempotent if ticker is
--- already running.
local function OnPlayerStartedMoving()
	PositionBroadcaster.BroadcastPosition()

	if not activeTicker then
		activeTicker = C_Timer.NewTicker(TICKER_SECONDS, function()
			PositionBroadcaster.BroadcastPosition()
		end)
	end
end

--- Called on PLAYER_STOPPED_MOVING.
--- Cancels the ticker and broadcasts one final accurate stopped position.
local function OnPlayerStoppedMoving()
	if activeTicker then
		activeTicker:Cancel()
		activeTicker = nil
	end

	PositionBroadcaster.BroadcastPosition()
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

--- Return a snapshot of broadcast state for monitoring and debugging.
--- @return table diagnostics {lastBroadcastTime, tickerState, messagesSentCount}
function PositionBroadcaster.GetDiagnostics()
	return {
		lastBroadcastTime = lastBroadcastTime,
		tickerState       = activeTicker ~= nil and "running" or "idle",
		messagesSentCount = messagesSentCount,
	}
end

--- Return the time of the last successful broadcast (unix timestamp or nil).
--- @return number|nil
function PositionBroadcaster.GetLastBroadcastTime()
	return lastBroadcastTime
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Initialize the broadcaster and register movement event handlers.
--- Idempotent — calling multiple times is safe; handlers are registered once.
function PositionBroadcaster.Init()
	if initialized then return end

	if ns.Settings and ns.Settings.GetPositionOptOut and ns.Settings.GetPositionOptOut() then
		DebugPrint("[PositionBroadcaster] Skipping initialization — position opt-out is enabled")
		return
	end

	eventFrame = CreateFrame("Frame")
	eventFrame:RegisterEvent("PLAYER_STARTED_MOVING")
	eventFrame:RegisterEvent("PLAYER_STOPPED_MOVING")
	eventFrame:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_STARTED_MOVING" then
			OnPlayerStartedMoving()
		elseif event == "PLAYER_STOPPED_MOVING" then
			OnPlayerStoppedMoving()
		end
	end)

	initialized = true
	active      = true
	DebugPrint("[PositionBroadcaster] Initialized (ticker=" .. TICKER_SECONDS .. "s)")
end

--- Shutdown the broadcaster and clean up resources.
--- Cancels any running ticker, unregisters movement events, and marks as
--- uninitialized so Init() can be called again on re-entry.
function PositionBroadcaster.Shutdown()
	if not initialized then return end

	if activeTicker then
		activeTicker:Cancel()
		activeTicker = nil
	end

	if eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame = nil
	end

	initialized = false
	active      = false
	DebugPrint("[PositionBroadcaster] Shutdown complete")
end
