--- WoW Enum stubs for the test environment.

_G.Enum = _G.Enum or {}

-- Compression enums used by MessageCodec
_G.Enum.CompressionMethod = _G.Enum.CompressionMethod or {
	Deflate = 0,
}

_G.Enum.CompressionLevel = _G.Enum.CompressionLevel or {
	OptimizeForSize = 0,
	OptimizeForSpeed = 1,
}

-- SendAddonMessageResult used by AddonMessages
_G.Enum.SendAddonMessageResult = _G.Enum.SendAddonMessageResult
	or {
		Success = 0,
		InvalidPrefix = 1,
		InvalidMessage = 2,
		AddonMessageThrottle = 3,
		InvalidChatType = 4,
		NotInGroup = 5,
		TargetRequired = 6,
		InvalidChannel = 7,
		ChannelThrottle = 8,
		GeneralError = 9,
		NotInGuild = 10,
		AddOnMessageLockdown = 11,
		TargetOffline = 12,
	}
