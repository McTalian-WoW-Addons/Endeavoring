---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local Position = {}
ns.Position = Position

--[[
Sync/Position - Neighborhood Channel Lifecycle

PURPOSE:
Manages the WoW custom-chat channel that scopes position broadcasts to a
specific neighborhood. One player can be in at most one neighborhood channel
at a time; joining a new neighborhood first leaves the previous one.

CHANNEL NAMING (deterministic):
  Channel name = "Ndvrng" .. guid.gsub("[^%w]", "") -- nocheck
  Example: "NdvrngHousing422996E58" for GUID "Housing-4-2-2996-E58"
All players in the same neighborhood derive the same channel name from the
GUID, so JoinChannelByName acts as a create-or-join operation.

RESPONSIBILITIES:
- Join or leave neighborhood channels via C_ChatInfo WoW API
- Track the currently active neighborhood channel (GUID + name)
- Log join/leave events with timestamp, GUID, and channel number
- Log errors to PREFIX_ERROR for discoverability

NOT RESPONSIBLE FOR:
- Sending position updates (see S02 — Sync/Coordinator or future sender)
- Rendering positions on the minimap (see S03/S04)
- Stale-cache cleanup (see Services/PositionService)

LIFECYCLE:
  Position.JoinNeighborhood(guid)  -- called when player zones into neighborhood
  Position.LeaveNeighborhood(guid) -- called when player zones out

OBSERVABILITY:
  Join events  → DebugPrint + PREFIX_ERROR on failure
  Leave events → DebugPrint + PREFIX_ERROR on unexpected state
  Active state → Position.GetActiveChannel() for diagnostics
--]]

-- Shortcuts
local ERROR = ns.Constants and ns.Constants.PREFIX_ERROR
	or ("|cffff0000" .. addonName .. ":|r")
local DebugPrint = ns.DebugPrint

-- Channel name template — must match across all clients in the neighborhood.
-- Strip all non-alphanumeric characters from the GUID and prefix with "Ndvrng".
-- e.g. "Housing-4-2-2996-E58" → "NdvrngHousing422996E58"
-- This is deterministic, collision-free, and avoids the dashes that caused
-- channel join issues with WoW's custom channel API.
local CHANNEL_NAME_PREFIX = "Ndvrng" -- nocheck

-- State: only one active neighborhood channel at a time
local activeNeighborhoodGUID    = nil  -- GUID of the currently joined neighborhood
local activeChannelName         = nil  -- full channel name string
local activeChannelNumber       = nil  -- numeric channel ID (cached at join time for reliable lookup)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Derive a channel name from a neighborhood GUID.
--- Strips all non-alphanumeric characters and prepends the addon prefix.
--- @param neighborhoodGUID string e.g. "Housing-4-2-2996-E58"
--- @return string channelName e.g. "NdvrngHousing422996E58"
local function ChannelName(neighborhoodGUID)
	if not neighborhoodGUID or neighborhoodGUID == "" then
		return CHANNEL_NAME_PREFIX
	end
	local stripped = neighborhoodGUID:gsub("[^%w]", "")
	return CHANNEL_NAME_PREFIX .. stripped
end

--- Resolve the numeric channel number for a named channel by enumerating the channel list.
--- GetChannelList() returns (id1, name1, disabled1, id2, name2, disabled2, ...)
--- Returns 0 if the channel is not in the list (not joined).
--- @param channelName string
--- @return number channelNumber 0 if not found
local function GetChannelNumber(channelName)
	if not GetChannelList then
		return 0
	end
	
	local channels = {GetChannelList()}
	for i = 1, #channels, 3 do
		local id, name = channels[i], channels[i + 1]
		if name and name:lower() == channelName:lower() then
			return id
		end
	end
	
	return 0
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Join the custom channel for a neighborhood.
--- If already in a different neighborhood channel, leaves that one first.
--- If already in the requested neighborhood, this is a no-op.
--- @param neighborhoodGUID string  GUID of the neighborhood being entered
function Position.JoinNeighborhood(neighborhoodGUID)
	if not neighborhoodGUID or neighborhoodGUID == "" then
		print(ERROR .. " Position.JoinNeighborhood: neighborhoodGUID is required")
		return
	end

	-- Skip channel join when the player has opted out of position sharing
	if ns.Settings and ns.Settings.GetPositionOptOut and ns.Settings.GetPositionOptOut() then
		DebugPrint("[Position] JoinNeighborhood skipped — position opt-out is enabled (GUID=" .. neighborhoodGUID .. ")") -- nocheck
		return
	end

	-- No-op if we are already in this neighborhood's channel
	if activeNeighborhoodGUID == neighborhoodGUID then
		DebugPrint(string.format(
			"[Position] Already in neighborhood channel (GUID=%s)",
			neighborhoodGUID
		))
		return
	end

	-- Leave the previous neighborhood channel before joining a new one
	if activeNeighborhoodGUID then
		Position.LeaveNeighborhood(activeNeighborhoodGUID)
	end

	local channelName = ChannelName(neighborhoodGUID)
	local timestamp   = time()

	-- Use JoinChannelByName global function to join the channel
	if not JoinChannelByName then
		print(ERROR .. string.format(
			" [Position] JoinChannelByName unavailable — cannot join channel for GUID=%s (ts=%d)",
			neighborhoodGUID, timestamp
		))
		return
	end

	local channelType, resultName = JoinChannelByName(channelName, nil, DEFAULT_CHAT_FRAME:GetID(), false)
	DebugPrint(string.format(
		"[Position] JoinChannelByName result: channelType=%s resultName=%s for channelName=%q (GUID=%s ts=%d)",
		tostring(channelType), tostring(resultName), channelName, neighborhoodGUID, timestamp
	))
	if not channelType then
		print(ERROR .. string.format(
			" [Position] Failed to join channel %q for GUID=%s (JoinChannelByName returned nil)",
			channelName, neighborhoodGUID
		))
		return
	end

	activeNeighborhoodGUID = neighborhoodGUID
	activeChannelName      = channelName
	activeChannelNumber    = GetChannelNumber(channelName)

	DebugPrint(string.format(
		"[Position] Joined neighborhood channel: GUID=%s channel=%q (channelNum=%d) ts=%d",
		neighborhoodGUID, channelName, activeChannelNumber or 0, timestamp
	))
end

--- Leave the custom channel for a neighborhood.
--- If the specified GUID does not match the active channel, logs a warning and
--- returns without attempting to leave — prevents accidental double-leave.
--- @param neighborhoodGUID string  GUID of the neighborhood being exited
function Position.LeaveNeighborhood(neighborhoodGUID)
	if not neighborhoodGUID or neighborhoodGUID == "" then
		print(ERROR .. " Position.LeaveNeighborhood: neighborhoodGUID is required")
		return
	end

	local timestamp = time()

	-- Guard: only leave if this GUID matches our active channel
	if activeNeighborhoodGUID ~= neighborhoodGUID then
		DebugPrint(string.format(
			"[Position] LeaveNeighborhood called for GUID=%s but active is GUID=%s — ignoring (ts=%d)",
			neighborhoodGUID,
			tostring(activeNeighborhoodGUID),
			timestamp
		))
		return
	end

	local channelName = activeChannelName or ChannelName(neighborhoodGUID)

	-- Use LeaveChannelByName global function to leave the channel
	if not LeaveChannelByName then
		print(ERROR .. string.format(
			" [Position] LeaveChannelByName unavailable — cannot leave channel for GUID=%s (ts=%d)",
			neighborhoodGUID, timestamp
		))
		-- Clear state anyway to avoid being stuck
		activeNeighborhoodGUID = nil
		activeChannelName      = nil
		return
	end

	LeaveChannelByName(channelName)

	DebugPrint(string.format(
		"[Position] Left neighborhood channel: GUID=%s channel=%q ts=%d",
		neighborhoodGUID, channelName, timestamp
	))

	activeNeighborhoodGUID = nil
	activeChannelName      = nil
	activeChannelNumber    = nil
end

--- Return the currently active neighborhood GUID and channel name, or nil.
--- Intended for diagnostics and observability — callers must not mutate state.
--- @return string|nil neighborhoodGUID
--- @return string|nil channelName
function Position.GetActiveChannel()
	return activeNeighborhoodGUID, activeChannelName
end

--- Return the numeric channel ID of the currently active neighborhood channel, or nil.
--- Used by PositionBroadcaster to send messages without doing a fresh lookup.
--- @return number|nil channelNumber
function Position.GetActiveChannelNumber()
	return activeChannelNumber
end

--- Return just the currently active neighborhood GUID (or nil).
--- Used by Core.lua zone-change handler to detect neighborhood transitions.
--- @return string|nil neighborhoodGUID
function Position.GetActiveNeighborhoodGUID()
	return activeNeighborhoodGUID
end
