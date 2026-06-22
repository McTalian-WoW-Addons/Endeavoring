--- Lua runtime compatibility shims for the test environment.
---
--- WoW runs on Lua 5.1, but the test runner (Lua 5.4) may be missing
--- a handful of Lua 5.1 globals or expose them under different names.

-- Lua 5.2+ moved `unpack` into the `table` namespace.
---@diagnostic disable-next-line: undefined-field
_G.unpack = _G.unpack or table.unpack

-- WoW exposes `format` as a global alias for `string.format`.
_G.format = _G.format or string.format

-- WoW exposes `strtrim` as a global.
_G.strtrim = _G.strtrim
	or function(str, chars)
		if not str then
			return str
		end
		chars = chars or " \t\r\n"
		local pattern_chars = chars:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
		return str:gsub("^[" .. pattern_chars .. "]*", ""):gsub("[" .. pattern_chars .. "]*$", "")
	end
