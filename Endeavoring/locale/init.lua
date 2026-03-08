---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

-- Simple locale table.
-- __index falls back to returning the key itself, so untranslated strings
-- gracefully display their English text (which is usually the same as the key).
---@class Ndvrng_Locale
ns.L = setmetatable({}, {
  __index = function(_, k) return k end,
})
