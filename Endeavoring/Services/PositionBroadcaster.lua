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
movement and on stop, with natural stutter-step handling.

BROADCAST STRATEGY:
  - Single 1.5s ticker broadcasts position when pending
  - PLAYER_STARTED_MOVING → set pending flag, start ticker (if not running),
                            cancel any pending ticker stop
  - PLAYER_STOPPED_MOVING → set pending flag, schedule debounced ticker stop
  - Ticker fires → broadcast if pending, clear flag
  - Debounce expires → stop ticker (if no new movement cancels it)

STUTTER-STEP HANDLING:
Rapid stop/start cycles naturally keep the ticker alive:
  - STARTED → pending=true, start ticker, cancel stop debounce
  - STOPPED → pending=true, schedule stop (5s)
  - STARTED → pending=true, start ticker (no-op), cancel stop debounce ✓
  - STOPPED → pending=true, schedule stop (5s)
  - After 5s with no new movement → ticker stops

Benefits:
  - Single controlled interval (no rapid broadcasts)
  - Always broadcasts latest position (pending flag)
  - Automatic stutter-step resilience (debounce keeps cancelling)
  - CPU efficient (ticker only runs during/near movement)

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
local TICKER_STOP_DEBOUNCE_SECONDS = 5  -- Debounce time before stopping ticker after movement stops

-- Shortcuts
local ERROR = ns.Constants and ns.Constants.PREFIX_ERROR or ("|cffff0000" .. addonName .. ":|r")
local DebugPrint = ns.DebugPrint

-- State
local initialized           = false
local active                = true  -- false after Shutdown(); blocks BroadcastPosition until re-Init
local activeTicker          = nil   -- C_Timer.NewTicker handle; non-nil means ticker is running
local lastBroadcastTime     = nil   -- unix timestamp of the most recent successful send
local messagesSentCount     = 0     -- total sends since Init()
local pendingPosition       = false -- flag: broadcast on next ticker fire
local tickerStopDebounceTimer = nil -- timer for debounced ticker stop

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
--- Sets pending flag, starts ticker (if not running), and cancels any pending
--- ticker stop to keep moving indicator alive during movement.
local function OnPlayerStartedMoving()
	pendingPosition = true

	if not activeTicker then
		activeTicker = C_Timer.NewTicker(TICKER_SECONDS, function()
			if pendingPosition then
				PositionBroadcaster.BroadcastPosition()
			end
		end)
	end

	-- Cancel any pending ticker stop (movement resumed)
	if tickerStopDebounceTimer then
		tickerStopDebounceTimer:Cancel()
		tickerStopDebounceTimer = nil
	end
end

--- Called on PLAYER_STOPPED_MOVING.
--- Sets pending flag so the next ticker broadcasts the final stopped position,
--- then schedules a debounced ticker stop. If movement resumes before debounce
--- expires, this is cancelled by the next STARTED event.
local function OnPlayerStoppedMoving()
	pendingPosition = true

	-- Cancel any existing debounce timer
	if tickerStopDebounceTimer then
		tickerStopDebounceTimer:Cancel()
	end

	-- Schedule ticker stop with debounce
	tickerStopDebounceTimer = C_Timer.NewTimer(TICKER_STOP_DEBOUNCE_SECONDS, function()
		pendingPosition = false
		if activeTicker then
			activeTicker:Cancel()
			activeTicker = nil
		end
		tickerStopDebounceTimer = nil
	end)
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
		DebugPrint("[PositionBroadcaster] Skipping initialization — position opt-out is enabled") -- nocheck
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
	DebugPrint("[PositionBroadcaster] Initialized (ticker=" .. TICKER_SECONDS .. "s)") -- nocheck
end

--- Shutdown the broadcaster and clean up resources.
--- Cancels any running ticker and debounce timer, unregisters movement events,
--- and marks as uninitialized so Init() can be called again on re-entry.
function PositionBroadcaster.Shutdown()
	if not initialized then return end

	if activeTicker then
		activeTicker:Cancel()
		activeTicker = nil
	end

	if tickerStopDebounceTimer then
		tickerStopDebounceTimer:Cancel()
		tickerStopDebounceTimer = nil
	end

	if eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame = nil
	end

	initialized = false
	active      = false
	DebugPrint("[PositionBroadcaster] Shutdown complete") -- nocheck
end
