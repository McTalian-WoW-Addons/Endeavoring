---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local AddonMessages = {}
ns.AddonMessages = AddonMessages

--[[
Addon Messages - WoW API Abstraction Layer

PURPOSE:
Pure abstraction layer for WoW's addon communication API. Handles only the
low-level mechanics of registering prefixes, building messages, and sending
through WoW channels. Contains NO business logic or protocol knowledge.

RESPONSIBILITIES:
- Register addon message prefix with WoW
- Build CBOR-encoded messages for transmission
- Send messages via C_ChatInfo.SendAddonMessage
- Message size validation and lockdown checks
- Error handling and result code interpretation

PUBLIC API:
- AddonMessages.Init() - Register prefix and initialize coordinator
- AddonMessages.BuildMessage(messageType, data) - Encode message for transmission
- AddonMessages.SendMessage(message, channel, target) - Transmit to WoW
- AddonMessages.RegisterListener() - Set up CHAT_MSG_ADDON event handler

LAYERING:
Services/AddonMessages (this file) → WoW API only
Sync/Protocol → Message parsing and routing
Sync/Coordinator → Timing and orchestration
Sync/Gossip → Profile propagation logic

MESSAGE TYPES:
Defined in Bootstrap.lua as ns.MSG_TYPE enum for type safety and reuse.
--]]

-- Shortcuts
local ERROR = ns.Constants.PREFIX_ERROR
local DebugPrint = ns.DebugPrint

-- Constants
local ADDON_PREFIX = "Ndvrng"
---@enum Channels
AddonMessages.ChatType = {
	Party = "PARTY",
	Raid = "RAID",
	Instance = "INSTANCE_CHAT",
	Guild = "GUILD",
	Office = "OFFICER",
	Whisper = "WHISPER",
	Channel = "CHANNEL",
}
local ChatType = AddonMessages.ChatType
local MESSAGE_SIZE_LIMIT = 255 -- WoW API hard limit for addon messages

-- State
local initialized = false

--- Initialize the addon message service
function AddonMessages.Init()
	if initialized then
		return
	end

	-- Register addon message prefix
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		local success = C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
		if not success then
			print(ERROR .. " Failed to register addon message prefix")
			return
		end
	end

	-- Initialize coordinator for timing and orchestration
	ns.Coordinator.Init()

	initialized = true
end

--- Build a message with CBOR-encoded payload
--- Message type is included in the CBOR payload to avoid string+binary mixing
--- @param messageType MessageType The message type
--- @param data table The message data
--- @return string|nil encoded The encoded message or nil on failure
function AddonMessages.BuildMessage(messageType, data)
	-- Include message type in the payload (short key; callers construct fresh tables)
	data[ns.SK.type] = messageType

	local encoded, err = ns.MessageCodec.Encode(data)
	if not encoded then
		DebugPrint(string.format("Failed to encode message: %s", err or "unknown error"), "ff0000")
		return nil
	end

	-- Warn if message is approaching or exceeding size limit
	if #encoded > MESSAGE_SIZE_LIMIT then
		DebugPrint(
			string.format(
				"WARNING: Built message size (%d bytes) exceeds limit (%d bytes)!",
				#encoded,
				MESSAGE_SIZE_LIMIT
			),
			"ff0000"
		)
	elseif #encoded > (MESSAGE_SIZE_LIMIT * 0.9) then
		-- Warn if within 10% of limit
		DebugPrint(
			string.format(
				"WARNING: Built message size (%d bytes) is close to limit (%d bytes)",
				#encoded,
				MESSAGE_SIZE_LIMIT
			),
			"ff8800"
		)
	end

	return encoded
end

local function isValidDestination(channel, target)
	if channel == ChatType.Guild and not ns.PlayerInfo.IsInGuild() then
		DebugPrint("Cannot send guild message - not in a guild", "ff0000")
		return false
	end

	if channel == ChatType.Whisper and (not target or target == "") then
		DebugPrint("Cannot send whisper message - target player name is required", "ff0000")
		return false
	end

	if (channel == ChatType.Party or channel == ChatType.Raid) and not ns.PlayerInfo.IsInHomeGroup() then
		DebugPrint('Cannot send party or raid message - not in a "non-instance" group', "ff0000")
		return false
	end

	if channel == ChatType.Instance and not ns.PlayerInfo.IsInInstanceGroup() then
		DebugPrint("Cannot send instance message - not in an instance group", "ff0000")
		return false
	end

	if channel == ChatType.Office and not ns.PlayerInfo.IsGuildOfficer() then
		DebugPrint("Cannot send officer message - not a guild officer", "ff0000")
		return false
	end

	return true
end

--- Send a message via addon communication
--- @param message string The message to send
--- @param channel Channels The channel to send on (default: ChatType.Party)
--- @param target string|nil The target player for whisper messages
--- @return boolean success Whether the message was sent successfully
function AddonMessages.SendMessage(message, channel, target)
	if not initialized then
		return false
	end

	channel = channel or ChatType.Party

	if not isValidDestination(channel, target) then
		return false
	end

	-- Pre-flight validation: check for chat messaging lockdown (instances, restricted zones)
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
		local isRestricted, reason = C_ChatInfo.InChatMessagingLockdown()
		if isRestricted then
			DebugPrint(
				string.format(
					"Skipping message send - chat messaging lockdown active (reason: %s)",
					tostring(reason or "unknown")
				),
				"ff8800"
			)
			return false
		end
	end

	-- Pre-flight validation: check message size
	if #message > MESSAGE_SIZE_LIMIT then
		print(
			ERROR
				.. string.format(
					" Message size (%d bytes) exceeds API limit (%d bytes)! Message NOT sent.",
					#message,
					MESSAGE_SIZE_LIMIT
				)
		)
		print(ERROR .. " This likely means you have too many characters. Please report this issue!")
		return false
	end

	if C_ChatInfo and C_ChatInfo.SendAddonMessage then
		-- Send and check return code
		local result = C_ChatInfo.SendAddonMessage(ADDON_PREFIX, message, channel, target)

		-- Check for errors (Enum.SendAddonMessageResult)
		if result ~= Enum.SendAddonMessageResult.Success then
			local errorNames = {
				[Enum.SendAddonMessageResult.InvalidPrefix] = "InvalidPrefix",
				[Enum.SendAddonMessageResult.InvalidMessage] = "InvalidMessage",
				[Enum.SendAddonMessageResult.AddonMessageThrottle] = "AddonMessageThrottle",
				[Enum.SendAddonMessageResult.InvalidChatType] = "InvalidChatType",
				[Enum.SendAddonMessageResult.NotInGroup] = "NotInGroup",
				[Enum.SendAddonMessageResult.TargetRequired] = "TargetRequired",
				[Enum.SendAddonMessageResult.InvalidChannel] = "InvalidChannel",
				[Enum.SendAddonMessageResult.ChannelThrottle] = "ChannelThrottle",
				[Enum.SendAddonMessageResult.GeneralError] = "GeneralError",
				[Enum.SendAddonMessageResult.NotInGuild] = "NotInGuild",
				[Enum.SendAddonMessageResult.AddOnMessageLockdown] = "AddOnMessageLockdown",
				[Enum.SendAddonMessageResult.TargetOffline] = "TargetOffline",
			}
			local errorName = errorNames[result] or "Unknown"

			print(ERROR .. string.format(" Failed to send message: %s (code %d)", errorName, result or -1))
			print(ERROR .. string.format(" Channel: %s, Size: %d bytes", channel, #message))
			if target then
				print(ERROR .. string.format(" Target: %s", target))
			end
			return false
		end

		return true
	end

	return false
end

--- Register event listener for addon messages
function AddonMessages.RegisterListener()
	if not initialized then
		AddonMessages.Init()
	end

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("CHAT_MSG_ADDON")
	frame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
		if event == "CHAT_MSG_ADDON" then
			ns.Protocol.OnAddonMessage(prefix, message, channel, sender)
		end
	end)
end
