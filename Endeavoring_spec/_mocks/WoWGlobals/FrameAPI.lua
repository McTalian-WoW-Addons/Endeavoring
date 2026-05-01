--- WoW Frame API stubs for the test environment.
---
--- Provides CreateFrame and related UI stubs needed to load modules that create
--- frames at load time or define UI creation functions. These are heavier than
--- the core WoW global stubs, so they live in a separate file — only loaded by
--- specs that actually need frame creation (e.g., the load-order test).
---
--- Individual feature specs that test pure logic should NOT require this file;
--- they should mock CreateFrame locally if needed.

--- Minimal frame stub constructor.
--- Returns a table with enough methods to satisfy module-level code
--- that creates frames, registers events, sets scripts, etc.
---@param frameType string|nil The frame type (e.g., "Frame", "Button", "StatusBar")
---@param name string|nil Global name for the frame
---@param parent table|nil Parent frame
---@param template string|nil Template name
---@return table frame A stub frame object
_G.CreateFrame = _G.CreateFrame or function(frameType, name, parent, template)
	local frame = {
		_type = frameType or "Frame",
		_name = name,
		_parent = parent,
		_template = template,
		_scripts = {},
		_events = {},
		_points = {},
		_shown = true,
		_level = 1,
		_strata = "MEDIUM",
		_width = 0,
		_height = 0,
		_alpha = 1,
		_text = "",
	}

	-- Script management
	function frame:SetScript(event, handler) self._scripts[event] = handler end
	function frame:GetScript(event) return self._scripts[event] end
	function frame:HookScript(event, handler) self._scripts[event] = handler end

	-- Event management
	function frame:RegisterEvent(event) self._events[event] = true end
	function frame:UnregisterEvent(event) self._events[event] = nil end
	function frame:UnregisterAllEvents() self._events = {} end

	-- Positioning
	function frame:SetPoint(...) table.insert(self._points, {...}) end
	function frame:ClearAllPoints() self._points = {} end
	function frame:SetAllPoints() end
	function frame:GetPoint(index) return unpack(self._points[index or 1] or {}) end

	-- Sizing
	function frame:SetSize(w, h) self._width = w; self._height = h end
	function frame:SetWidth(w) self._width = w end
	function frame:SetHeight(h) self._height = h end
	function frame:GetWidth() return self._width end
	function frame:GetHeight() return self._height end

	-- Visibility
	function frame:Show() self._shown = true end
	function frame:Hide() self._shown = false end
	function frame:IsShown() return self._shown end
	function frame:IsVisible() return self._shown end
	function frame:SetShown(v) self._shown = v end

	-- Frame strata/level
	function frame:SetFrameStrata(s) self._strata = s end
	function frame:GetFrameStrata() return self._strata end
	function frame:SetFrameLevel(l) self._level = l end
	function frame:GetFrameLevel() return self._level or 0 end

	-- Mouse/interaction
	function frame:EnableMouse() end
	function frame:SetMovable() end
	function frame:RegisterForDrag() end
	function frame:SetClampedToScreen() end
	function frame:StartMoving() end
	function frame:StopMovingOrSizing() end

	-- Appearance
	function frame:SetAlpha(a) self._alpha = a end
	function frame:GetAlpha() return self._alpha end
	function frame:SetNormalAtlas() end
	function frame:SetHighlightAtlas() end
	function frame:SetPushedAtlas() end
	function frame:SetPortraitToAsset() end

	-- Text (for Button/FontString-like frames)
	function frame:SetText(t) self._text = t end
	function frame:GetText() return self._text end

	-- StatusBar methods
	function frame:SetMinMaxValues() end
	function frame:SetValue() end
	function frame:SetStatusBarTexture() end
	function frame:SetStatusBarColor() end
	function frame:GetStatusBarTexture() return {} end

	-- ScrollFrame methods
	function frame:SetScrollChild() end
	function frame:GetScrollChild() return frame end
	function frame:SetVerticalScroll() end
	function frame:GetVerticalScroll() return 0 end

	-- Texture/FontString creation
	function frame:CreateTexture(n, layer)
		local tex = {}
		function tex:SetAllPoints() end
		function tex:SetPoint() end
		function tex:SetSize() end
		function tex:SetAtlas() end
		function tex:SetTexture() end
		function tex:SetTexCoord() end
		function tex:SetVertexColor() end
		function tex:SetAlpha() end
		function tex:Show() end
		function tex:Hide() end
		return tex
	end

	function frame:CreateFontString(n, layer, tmpl)
		local fs = {}
		fs._text = ""
		function fs:SetPoint() end
		function fs:SetText(t) fs._text = t end
		function fs:GetText() return fs._text end
		function fs:SetTextColor() end
		function fs:SetJustifyH() end
		function fs:SetJustifyV() end
		function fs:SetWordWrap() end
		function fs:SetWidth() end
		function fs:SetHeight() end
		function fs:GetStringWidth() return 0 end
		function fs:Show() end
		function fs:Hide() end
		return fs
	end

	-- Button-specific
	function frame:SetEnabled() end
	function frame:IsEnabled() return true end
	function frame:SetNormalTexture() end
	function frame:SetHighlightTexture() end
	function frame:SetPushedTexture() end
	function frame:SetDisabledTexture() end

	-- PortraitFrameTemplate support
	if template == "PortraitFrameTemplate" then
		frame.TitleContainer = {
			TitleText = {
				SetText = function(self, t) self._text = t end,
				_text = "",
			},
		}
	end

	-- Store named frames in globals (WoW behavior)
	if name then
		_G[name] = frame
	end

	return frame
end

-- Tooltip stubs
_G.GameTooltip = _G.GameTooltip or {
	_owner = nil,
	SetOwner = function(self, owner) self._owner = owner end,
	GetOwner = function(self) return self._owner end,
	SetText  = function() end,
	Show     = function() end,
	Hide     = function() end,
	AddLine  = function() end,
	ClearLines = function() end,
}
_G.GameTooltip_SetTitle = _G.GameTooltip_SetTitle or function() end
_G.GameTooltip_AddNormalLine = _G.GameTooltip_AddNormalLine or function() end
_G.GameTooltip_Hide = _G.GameTooltip_Hide or function() end

-- UI parent and frame list
_G.UIParent = _G.UIParent or {}
_G.UISpecialFrames = _G.UISpecialFrames or {}

-- Mixin utility (copies methods from mixins into target table)
_G.Mixin = _G.Mixin or function(target, ...)
	for i = 1, select("#", ...) do
		local mixin = select(i, ...)
		if mixin then
			for k, v in pairs(mixin) do
				target[k] = v
			end
		end
	end
	return target
end

-- CreateFromMixins: creates a new table from one or more mixins
_G.CreateFromMixins = _G.CreateFromMixins or function(...)
	return Mixin({}, ...)
end

-- MapCanvas base mixins (stubbed for load-order safety)
_G.MapCanvasDataProviderMixin = _G.MapCanvasDataProviderMixin or {
	OnAdded = function() end,
	OnRemoved = function() end,
	RefreshAllData = function() end,
	RemoveAllData = function() end,
	GetMap = function(self) return self.owningMap end,
}
_G.MapCanvasPinMixin = _G.MapCanvasPinMixin or {
	OnReleased = function() end,
	SetScalingLimits = function() end,
	UseFrameLevelType = function() end,
	SetPosition = function() end,
}

-- Tab system mixins (used by Core.lua's InitializeTabSystem)
_G.TabSystemOwnerMixin = _G.TabSystemOwnerMixin or {
	OnLoad = function() end,
	SetTabSystem = function() end,
	AddNamedTab = function() return 1 end,
	SetTab = function() end,
}
_G.TabSystemMixin = _G.TabSystemMixin or {
	OnLoad = function() end,
}

-- Sound constants
_G.SOUNDKIT = _G.SOUNDKIT or { IG_CHARACTER_INFO_TAB = 1 }

-- Static popup support (Settings.lua registers dialogs at load time)
_G.StaticPopupDialogs = _G.StaticPopupDialogs or {}
_G.StaticPopup_Show = _G.StaticPopup_Show or function() end
_G.StaticPopup_OnClick = _G.StaticPopup_OnClick or function() end
