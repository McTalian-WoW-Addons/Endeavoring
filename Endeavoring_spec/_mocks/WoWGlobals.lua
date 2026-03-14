--- Core WoW global stubs for the test environment.
---
--- Provides minimal stubs for WoW globals that addon source files
--- reference at load time or at runtime. Specs can override/spy on
--- these as needed.

-- Suppress addon print output during tests.
-- Busted uses io.write for its own output, so overriding print is safe.
-- The original is saved so specs can restore it if needed (e.g., debugging).
_G._originalPrint = _G._originalPrint or print
_G.print = function() end

-- issecretvalue: WoW API that checks if a value is a "secret" (hardware-protected).
-- In tests, nothing is ever a secret value.
_G.issecretvalue = _G.issecretvalue or function()
	return false
end

-- time(): WoW inherits Lua's os.time but exposes it as a global.
-- Already available in standard Lua, but ensure it's in _G explicitly.
_G.time = _G.time or os.time

-- UnitName: returns the player's character name
_G.UnitName = _G.UnitName or function()
	return "TestPlayer"
end

-- C_ChatInfo stub (minimal — specs that test messaging will flesh this out)
_G.C_ChatInfo = _G.C_ChatInfo or {}
_G.C_ChatInfo.RegisterAddonMessagePrefix = _G.C_ChatInfo.RegisterAddonMessagePrefix or function()
	return true
end
_G.C_ChatInfo.SendAddonMessage = _G.C_ChatInfo.SendAddonMessage or function()
	return 0  -- Success
end
_G.C_ChatInfo.InChatMessagingLockdown = _G.C_ChatInfo.InChatMessagingLockdown or function()
	return false
end

-- CopyTable: deep-copy a table (WoW utility)
_G.CopyTable = _G.CopyTable or function(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do
		if type(v) == "table" then
			copy[k] = _G.CopyTable(v)
		else
			copy[k] = v
		end
	end
	return copy
end

-- tContains: check if a value exists in a list-like table (WoW utility)
_G.tContains = _G.tContains or function(tbl, item)
	for _, v in ipairs(tbl) do
		if v == item then return true end
	end
	return false
end

-- GetLocale: returns the client locale string (e.g. "enUS", "deDE")
-- In tests, default to US English so non-English locale files skip their translations.
_G.GetLocale = _G.GetLocale or function()
	return "enUS"
end

-- C_Timer stub
_G.C_Timer = _G.C_Timer or {}
_G.C_Timer.NewTimer = _G.C_Timer.NewTimer or function(_, callback)
	return { Cancel = function() end }
end
_G.C_Timer.NewTicker = _G.C_Timer.NewTicker or function(_, callback)
	return { Cancel = function() end }
end
