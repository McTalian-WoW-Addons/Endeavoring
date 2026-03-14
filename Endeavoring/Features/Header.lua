---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local Header = {}
ns.Header = Header
local L = ns.L

function Header.Create(parent)
	local constants = ns.Constants
	local header = CreateFrame("Frame", nil, parent)
	header:SetPoint("TOPLEFT", 12, -58)
	header:SetPoint("TOPRIGHT", -12, -58)
	header:SetHeight(constants.HEADER_HEIGHT)

	-- Title with description tooltip support
	header.title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	header.title:SetPoint("TOPLEFT", 6, -4)
	header.title:SetText("Endeavoring")

	-- Info icon for endeavor description tooltip
	header.infoIcon = CreateFrame("Button", nil, header)
	header.infoIcon:SetSize(16, 16)
	header.infoIcon:SetPoint("LEFT", header.title, "RIGHT", 4, 0)
	header.infoIcon:SetNormalAtlas("poi-workorders")
	header.infoIcon:SetHighlightAtlas("poi-workorders")
	header.infoIcon:SetAlpha(0.7)
	header.infoIcon:SetScript("OnEnter", function(self)
		local initiativeInfo = ns.API.GetInitiativeInfo()
		if initiativeInfo and initiativeInfo.description and initiativeInfo.description ~= "" then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip_SetTitle(GameTooltip, initiativeInfo.title or "Endeavor")
			GameTooltip_AddNormalLine(GameTooltip, initiativeInfo.description, true)
			GameTooltip:Show()
		end
	end)
	header.infoIcon:SetScript("OnLeave", GameTooltip_Hide)
	header.infoIcon:Hide() -- Hidden until we have an active endeavor

	header.timeRemaining = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	header.timeRemaining:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -6)
	header.timeRemaining:SetText(constants.TIME_REMAINING_FALLBACK)

	-- Progress bar with gradient color
	header.progress = CreateFrame("StatusBar", nil, header, "TextStatusBar")
	--header.progress:SetPoint("BOTTOM", header, "TOP", 0, 4)
	header.progress:SetPoint("TOPLEFT", header.timeRemaining, "BOTTOMLEFT", 0, -8)
	
	header.progress:SetSize(constants.HEADER_PROGRESS_WIDTH, constants.HEADER_PROGRESS_HEIGHT)
	header.progress:SetMinMaxValues(0, 100)
	header.progress:SetValue(0)
	
	-- Use smooth gradient texture
	local progressTexture = header.progress:CreateTexture(nil, "ARTWORK")
	progressTexture:SetAtlas("housing-dashboard-fillbar-fill")
	header.progress:SetStatusBarTexture(progressTexture)
	
	-- Green gradient (similar to experience bar)
	progressTexture:SetVertexColor(0.2, 0.8, 0.2) -- Green tint
	
	-- Background texture
	header.progress.bg = header.progress:CreateTexture(nil, "BACKGROUND")
	header.progress.bg:SetAllPoints(header.progress)
	header.progress.bg:SetAtlas("housing-dashboard-fillbar-bar-bg")
	header.progress.bg:SetVertexColor(0.1, 0.1, 0.1, 0.5)
	
	-- Progress text
	header.progress.text = header.progress:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	header.progress.text:SetPoint("CENTER")
	header.progress.text:SetText("0%")

	-- Value Text
	header.progress.valueText = header.progress:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	header.progress.valueText:SetPoint("RIGHT", header.progress, "RIGHT", -4, 0)
	header.progress.valueText:SetText("0 / 0")
	
	-- Milestone list on the right side (single column with overflow to second column)
	header.milestoneList = CreateFrame("Frame", nil, header)
	header.milestoneList:SetPoint("TOPRIGHT", header, "TOPRIGHT", -10, -4)
	header.milestoneList:SetSize(260, 90) -- Wide enough for overflow column if needed

	-- Chest ready indicator (experimental feature)
	-- Shows when endeavor is complete and chest hasn't been looted
	-- Use Button instead of Frame so we can handle right-click to dismiss
	local chestIndicator = CreateFrame("Button", nil, header)
	header.chestIndicator = chestIndicator
	chestIndicator:SetSize(24, 24)
	chestIndicator:SetPoint("LEFT", header.infoIcon, "RIGHT", 0, 0)
	
	-- Chest icon
	chestIndicator.icon = chestIndicator:CreateTexture(nil, "ARTWORK")
	chestIndicator.icon:SetAllPoints()
	chestIndicator.icon:SetAtlas("BonusLoot-Chest")
	
	-- Glow animation group
	local animGroup = chestIndicator:CreateAnimationGroup()
	animGroup:SetLooping("REPEAT")
	
	-- Pulse alpha animation
	local alpha = animGroup:CreateAnimation("Alpha")
	alpha:SetFromAlpha(1.0)
	alpha:SetToAlpha(0.3)
	alpha:SetDuration(1.0)
	alpha:SetSmoothing("IN_OUT")
	
	chestIndicator.animGroup = animGroup
	
	-- Tooltip and click-to-dismiss
	chestIndicator:EnableMouse(true)
	chestIndicator:RegisterForClicks("RightButtonUp")
	chestIndicator:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip_SetTitle(GameTooltip, L["Endeavor Chest Ready!"])
		GameTooltip_AddNormalLine(GameTooltip, L["TIP_ChestIndicator"])
		GameTooltip_AddBlankLineToTooltip(GameTooltip)
		GameTooltip_AddNormalLine(GameTooltip, L["TIP_ChestAutoDismiss"])
		GameTooltip_AddColoredLine(GameTooltip, L["TIP_ChestRightClick"], GREEN_FONT_COLOR)
		GameTooltip:Show()
	end)
	chestIndicator:SetScript("OnLeave", GameTooltip_Hide)
	chestIndicator:SetScript("OnClick", function()
		-- Filtered by RegisterForClicks to only respond to right-clicks
		Header.MarkChestClaimed(header)
	end)
	
	chestIndicator:Hide() -- Hidden until chest is ready
	
	-- Milestone entries (created dynamically during refresh)
	header.milestones = {}

	return header
end

function Header.Refresh()
	local constants = ns.Constants
	local mainFrame = ns.ui and ns.ui.mainFrame
	if not mainFrame or not mainFrame.header then
		return
	end

	local header = mainFrame.header
	local isInitiativeActive = ns.API.IsInitiativeActive()
	
	if not isInitiativeActive then
		header.title:SetText(constants.NO_ACTIVE_ENDEAVOR)
		header.timeRemaining:SetText(constants.TIME_REMAINING_FALLBACK)
		header.progress:SetMinMaxValues(0, 100)
		header.progress:SetValue(0)
		header.progress.text:SetText("0%")
		header.infoIcon:Hide()
		-- Hide all milestone markers
		for _, milestone in pairs(header.milestones) do
			milestone:Hide()
		end
		Header.UpdateChestIndicator(header, nil)
		return
	end

	local initiativeInfo = ns.API.GetInitiativeInfo()

	if initiativeInfo and initiativeInfo.isLoaded and initiativeInfo.initiativeID ~= 0 then
		header.title:SetText(initiativeInfo.title or "???")
		header.timeRemaining:SetText(ns.API.FormatTimeRemaining(initiativeInfo.duration))

		-- Show info icon if we have a description
		if initiativeInfo.description and initiativeInfo.description ~= "" then
			header.infoIcon:Show()
		else
			header.infoIcon:Hide()
		end

		local maxProgress = initiativeInfo.progressRequired or 0
		if maxProgress <= 0 then
			maxProgress = 1
		end
		local currentProgress = initiativeInfo.currentProgress or 0
		header.progress:SetMinMaxValues(0, maxProgress)
		header.progress:SetValue(currentProgress)
		local percent = math.min((currentProgress / maxProgress), 1)
		header.progress.text:SetText(FormatPercentage(percent))
		header.progress.valueText:SetText(string.format("%.1f / %d", currentProgress, maxProgress))
		
		-- Update milestone markers
		if initiativeInfo.milestones and #initiativeInfo.milestones > 0 then
			Header.UpdateMilestones(header, initiativeInfo.milestones, currentProgress, maxProgress)
		else
			-- Hide all milestones if none exist
			for _, milestone in pairs(header.milestones) do
				milestone:Hide()
			end
		end
		
		-- Update chest indicator (experimental)
		Header.UpdateChestIndicator(header, initiativeInfo)
	else
		header.title:SetText(constants.NO_TASK_DATA)
		header.timeRemaining:SetText(constants.TIME_REMAINING_FALLBACK)
		header.progress:SetMinMaxValues(0, 100)
		header.progress:SetValue(0)
		header.progress.text:SetText("0%")
		header.infoIcon:Hide()
		for _, milestone in pairs(header.milestones) do
			milestone:Hide()
		end
		Header.UpdateChestIndicator(header, nil)
	end
end

function Header.UpdateMilestones(header, milestones, currentProgress, maxProgress)
	local milestoneList = header.milestoneList
	local lineHeight = 18
	local columnWidth = 130
	local leftColumnX = 0
	local rightColumnX = columnWidth
	
	-- Create or update milestone list entries
	for i, milestoneInfo in ipairs(milestones) do
		local entry = header.milestones[i]
		
		-- Create entry if it doesn't exist
		if not entry then
			entry = CreateFrame("Frame", nil, milestoneList)
			entry:SetSize(columnWidth, lineHeight)
			
			-- Checkmark icon
			entry.checkmark = entry:CreateTexture(nil, "ARTWORK")
			entry.checkmark:SetAtlas("checkmark-minimal")
			entry.checkmark:SetSize(14, 14)
			entry.checkmark:SetPoint("LEFT", entry, "LEFT", 0, 0)
			
			-- Milestone text (name and percentage)
			entry.text = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			entry.text:SetPoint("LEFT", entry.checkmark, "RIGHT", 4, 0)
			entry.text:SetJustifyH("LEFT")
			
			-- Make it hoverable for tooltip
			entry:EnableMouse(true)
			entry:SetScript("OnEnter", function(self)
				if not self.milestoneData then
					return
				end
				
				GameTooltip:SetOwner(self, "ANCHOR_LEFT", -10, 0)
				GameTooltip_SetTitle(GameTooltip, string.format(L["FMT_MilestoneTooltipTitle"], self.index))
				GameTooltip_AddNormalLine(GameTooltip, string.format(L["FMT_MilestoneProgressRequired"], self.milestoneData.requiredContributionAmount))
				
				if self.milestoneData.rewards and #self.milestoneData.rewards > 0 then
					GameTooltip_AddBlankLineToTooltip(GameTooltip)
					GameTooltip_AddHighlightLine(GameTooltip, L["Rewards:"])
					for _, reward in ipairs(self.milestoneData.rewards) do
						if reward.title and reward.title ~= "" then
							local rewardText = reward.title
							if reward.description and reward.description ~= "" then
								rewardText = rewardText .. ": " .. reward.description
							end
							GameTooltip_AddColoredLine(GameTooltip, rewardText, GREEN_FONT_COLOR)
						end
					end
				end
				
				GameTooltip:Show()
			end)
			entry:SetScript("OnLeave", GameTooltip_Hide)
			
			header.milestones[i] = entry
		end
		
		-- Stack first 4 milestones in left column, overflow to right column
		local maxLeftColumn = 4
		local isLeftColumn = (i <= maxLeftColumn)
		local xPos, yPos
		
		if isLeftColumn then
			-- Left column: items 1-4
			xPos = leftColumnX
			yPos = -(i - 1) * lineHeight
		else
			-- Right column (overflow): items 5+
			xPos = rightColumnX
			yPos = -(i - maxLeftColumn - 1) * lineHeight
		end
		
		-- Position entry in appropriate column
		entry:ClearAllPoints()
		entry:SetPoint("TOPLEFT", milestoneList, "TOPLEFT", xPos, yPos)
		
		-- Calculate percentage threshold
		local percentThreshold = math.floor((milestoneInfo.requiredContributionAmount / maxProgress) * 100)
		
		-- Check if milestone completed
		local isCompleted = currentProgress >= milestoneInfo.requiredContributionAmount
		
		-- Update text and appearance
		entry.text:SetText(string.format(L["FMT_MilestoneLabel"], i, percentThreshold))
		
		if isCompleted then
			entry.checkmark:Show()
			entry.checkmark:SetDesaturated(false)
			entry.checkmark:SetVertexColor(0.2, 1.0, 0.2) -- Green
			entry.text:SetTextColor(0.2, 1.0, 0.2) -- Green text
		else
			entry.checkmark:Show()
			entry.checkmark:SetDesaturated(true)
			entry.checkmark:SetVertexColor(0.5, 0.5, 0.5) -- Gray
			entry.text:SetTextColor(0.8, 0.8, 0.8) -- Light gray text
		end
		
		-- Store milestone data for tooltip
		entry.milestoneData = milestoneInfo
		entry.index = i
		entry:Show()
	end
	
	-- Hide unused entries
	for i = #milestones + 1, #header.milestones do
		header.milestones[i]:Hide()
	end
end

--- Update chest ready indicator (experimental feature)
--- Shows a glowing chest icon when the final milestone is complete but the chest hasn't been looted
--- @param header table The header frame (as returned by Header.Create)
--- @param initiativeInfo table|nil Initiative info from API, or nil if no active endeavor
function Header.UpdateChestIndicator(header, initiativeInfo)
	if not header or not header.chestIndicator then
		return
	end
	
	local chestIndicator = header.chestIndicator
	
	-- Early exit if no active initiative
	if not initiativeInfo or not initiativeInfo.milestones or #initiativeInfo.milestones == 0 then
		chestIndicator:Hide()
		chestIndicator.animGroup:Stop()
		return
	end
	
	-- Get final milestone (the chest reward)
	local finalMilestone = initiativeInfo.milestones[#initiativeInfo.milestones]
	if not finalMilestone or not finalMilestone.rewards or #finalMilestone.rewards == 0 then
		chestIndicator:Hide()
		chestIndicator.animGroup:Stop()
		return
	end
	
	-- Check if final milestone is complete
	local currentProgress = initiativeInfo.currentProgress or 0
	local isComplete = currentProgress >= finalMilestone.requiredContributionAmount
	
	if not isComplete then
		chestIndicator:Hide()
		chestIndicator.animGroup:Stop()
		return
	end
	
	-- WoW provides no reliable client-side API to detect chest loot for this
	-- reward type. We track claimed state ourselves in SavedVariables, keyed
	-- by (initiativeID, currentCycleID) so it resets automatically each cycle.
	local isClaimed = ns.DB.IsChestClaimed(initiativeInfo.initiativeID, initiativeInfo.currentCycleID)

	if not isClaimed then
		chestIndicator:Show()
		chestIndicator.animGroup:Play()
	else
		chestIndicator:Hide()
		chestIndicator.animGroup:Stop()
	end
end

--- Mark the current initiative cycle's chest as claimed and hide the indicator
--- @param header table The header frame (as returned by Header.Create)
function Header.MarkChestClaimed(header)
	local initiativeInfo = ns.API.GetInitiativeInfo()
	if not initiativeInfo then return end
	ns.DB.SetChestClaimed(initiativeInfo.initiativeID, initiativeInfo.currentCycleID)
	Header.UpdateChestIndicator(header, initiativeInfo)
end

--- Automatically claim the chest when the Endeavor Coffer spell succeeds.
--- Called from the UNIT_SPELLCAST_SUCCEEDED event handler; resolves the frame itself.
function Header.AutoClaimChest()
	local initiativeInfo = ns.API.GetInitiativeInfo()
	if not initiativeInfo then return end
	ns.DB.SetChestClaimed(initiativeInfo.initiativeID, initiativeInfo.currentCycleID)
	local mainFrame = ns.ui and ns.ui.mainFrame
	if mainFrame and mainFrame.header then
		Header.UpdateChestIndicator(mainFrame.header, initiativeInfo)
	end
end
