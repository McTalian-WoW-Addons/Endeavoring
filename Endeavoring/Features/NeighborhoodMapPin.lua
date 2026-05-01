---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

--[[
EndeavoringNeighborPinMixin

Pin mixin for world map neighbor dots. Inherits MapCanvasPinMixin behavior
via the XML template. SetScalingLimits keeps dots a consistent screen size
regardless of zoom level (Blizzard's pin system handles this automatically
via ApplyCurrentScale → OnCanvasScaleChanged).
--]]

EndeavoringNeighborPinMixin = CreateFromMixins(MapCanvasPinMixin)

function EndeavoringNeighborPinMixin:OnLoad()
	-- Keep a consistent screen size at all zoom levels.
	-- scaleFactor=1, startScale=1, endScale=1 means no zoom-based scaling.
	-- The 1/canvasScale factor is applied automatically by ApplyCurrentScale.
	self:SetScalingLimits(1, 1.0, 1.0)
	self:UseFrameLevelType("PIN_FRAME_LEVEL_TOPMOST")
end

function EndeavoringNeighborPinMixin:OnAcquired()
	-- Called when the pin is acquired from the pool.
	-- SetupDot is called separately by the data provider.
end

function EndeavoringNeighborPinMixin:OnReleased()
	MapCanvasPinMixin.OnReleased(self)
end

--- Configure the dot color and tooltip. Called by the data provider after AcquirePin.
--- @param battleTag string
--- @param label string Tooltip label (character name or battleTag)
--- @param r number red (0-1)
--- @param g number green (0-1)
--- @param b number blue (0-1)
function EndeavoringNeighborPinMixin:SetupDot(battleTag, label, r, g, b)
	self.battleTag    = battleTag
	self.tooltipLabel = label
	if self.Dot then
		self.Dot:SetVertexColor(r, g, b, 1)
	end
end

function EndeavoringNeighborPinMixin:OnMouseEnter()
	if self.tooltipLabel then
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(self.tooltipLabel, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end
end

function EndeavoringNeighborPinMixin:OnMouseLeave()
	if GameTooltip:GetOwner() == self then
		GameTooltip:Hide()
	end
end
