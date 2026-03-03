---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local Leaderboard = {}
ns.Leaderboard = Leaderboard

local DebugPrint = ns.DebugPrint

-- Time range constants (in seconds)
local TIME_RANGE = {
	CURRENT_ENDEAVOR = 0,  -- Entire duration of active endeavor
	TODAY = 86400,         -- 24 hours
	THIS_WEEK = 604800,    -- 7 days
}

-- Current filter state
local state = {
	timeRange = TIME_RANGE.CURRENT_ENDEAVOR,
	sortKey = ns.Constants.LEADERBOARD_SORT_RANK,  -- Default sort by rank ascending
	sortAsc = true,
}

--- Build leaderboard from activity log
--- @param activityLog table The activity log from GetInitiativeActivityLogInfo()
--- @param timeRange number|nil Filter entries within this many seconds (nil = current endeavor)
--- @return table leaderboard Sorted array of {player, total, entries}
function Leaderboard.BuildFromActivityLog(activityLog, timeRange)
	if not activityLog or not activityLog.taskActivity then
		return {}
	end

	local now = time()
	local cutoffTime
	if timeRange and timeRange > 0 then
		cutoffTime = now - timeRange
	else
		cutoffTime = 0
	end
	local playerSum = {}

	-- Aggregate by player name
	for _, entry in ipairs(activityLog.taskActivity) do
		-- Filter by time range if specified
		if not timeRange or entry.completionTime >= cutoffTime then
			if not playerSum[entry.playerName] then
				playerSum[entry.playerName] = {
					player = entry.playerName,
					total = 0,
					entries = 0,
				}
			end
			
			playerSum[entry.playerName].total = playerSum[entry.playerName].total + entry.amount
			playerSum[entry.playerName].entries = playerSum[entry.playerName].entries + 1
		end
	end

	-- Convert to array for sorting
	local leaderboard = {}
	for _, data in pairs(playerSum) do
		table.insert(leaderboard, data)
	end

	-- Sort by total contribution (descending)
	table.sort(leaderboard, function(a, b)
		if a.total == b.total then
			if a.entries == b.entries then
				-- Tie-breaker: alphabetical by player name
				return a.player < b.player
			end
			-- Tie-breaker: more entries ranks higher
			return a.entries > b.entries
		end
		return a.total > b.total
	end)

	return leaderboard
end

--- Get enriched leaderboard with BattleTag/Alias mapping
--- @param activityLog table The activity log from GetInitiativeActivityLogInfo()
--- @param timeRange number|nil Filter entries within this many seconds (nil = current endeavor)
--- @return table leaderboard Sorted array with alias field added
function Leaderboard.BuildEnriched(activityLog, timeRange)
	local leaderboard = Leaderboard.BuildFromActivityLog(activityLog, timeRange)

	local myBattleTag = ns.PlayerInfo.GetBattleTag()

	local battleTagLeaderboard = {}
	local enrichedLeaderboard = {}
	for _, entry in ipairs(leaderboard) do
		local battleTag = ns.CharacterCache.FindBattleTag(entry.player)
		if battleTag then
			local profile = ns.DB.GetProfile(battleTag)
			local displayName = profile and profile.alias or battleTag
			battleTagLeaderboard[battleTag] = battleTagLeaderboard[battleTag] or {
				displayName = displayName,
				total = 0,
				entries = 0,
				charNames = {},
				isLocalPlayer = (battleTag == myBattleTag),
				hasSyncedProfile = true,
			}
			battleTagLeaderboard[battleTag].total = battleTagLeaderboard[battleTag].total + entry.total
			battleTagLeaderboard[battleTag].entries = battleTagLeaderboard[battleTag].entries + entry.entries
			table.insert(battleTagLeaderboard[battleTag].charNames, entry.player)
		else
			table.insert(enrichedLeaderboard, {
				displayName = entry.player,
				total = entry.total,
				entries = entry.entries,
				charNames = {},
				isLocalPlayer = ns.PlayerInfo.IsLocalPlayer(entry.player),
				hasSyncedProfile = false,
			})
		end
	end

	-- Add BattleTag entries to enriched leaderboard
	for _, data in pairs(battleTagLeaderboard) do
		table.insert(enrichedLeaderboard, data)
	end

	-- Sort enriched leaderboard by total contribution (descending)
	table.sort(enrichedLeaderboard, function(a, b)
		if a.total == b.total then
			if a.entries == b.entries then
				-- Tie-breaker: alphabetical by display name
				return a.displayName < b.displayName
			end
			-- Tie-breaker: more entries ranks higher
			return a.entries > b.entries
		end
		return a.total > b.total
	end)

	-- Assign ranks based on default sort (total descending)
	for i, entry in ipairs(enrichedLeaderboard) do
		entry.rank = i
	end

	return enrichedLeaderboard
end

--- Re-sort leaderboard based on current sort state
--- @param leaderboard table The enriched leaderboard from BuildEnriched
--- @return table sorted Sorted copy of leaderboard
local function BuildSortedLeaderboard(leaderboard)
	if not leaderboard or #leaderboard == 0 then
		return {}
	end

	-- Create a copy to avoid mutating original
	local sorted = {}
	for _, entry in ipairs(leaderboard) do
		table.insert(sorted, entry)
	end

	local constants = ns.Constants
	local sortKey = state.sortKey or constants.LEADERBOARD_SORT_RANK
	local sortAsc = state.sortAsc ~= false

	local function Compare(a, b)
		if sortKey == constants.LEADERBOARD_SORT_NAME then
			local left = a.displayName or ""
			local right = b.displayName or ""
			if left == right then
				return (a.rank or 0) < (b.rank or 0)
			end
			if sortAsc then
				return left < right
			end
			return left > right
		elseif sortKey == constants.LEADERBOARD_SORT_TOTAL then
			local leftTotal = a.total or 0
			local rightTotal = b.total or 0
			if leftTotal == rightTotal then
				return (a.rank or 0) < (b.rank or 0)
			end
			if sortAsc then
				return leftTotal < rightTotal
			end
			return leftTotal > rightTotal
		elseif sortKey == constants.LEADERBOARD_SORT_ENTRIES then
			local leftEntries = a.entries or 0
			local rightEntries = b.entries or 0
			if leftEntries == rightEntries then
				return (a.rank or 0) < (b.rank or 0)
			end
			if sortAsc then
				return leftEntries < rightEntries
			end
			return leftEntries > rightEntries
		end

		-- Default: sort by rank ascending
		local leftRank = a.rank or 0
		local rightRank = b.rank or 0
		if sortAsc then
			return leftRank < rightRank
		end
		return leftRank > rightRank
	end

	table.sort(sorted, Compare)
	return sorted
end

--- Update sort header indicators
local function UpdateSortHeader()
	if not ns.ui.leaderboardUI then
		return
	end

	local rankSuffix = ""
	local nameSuffix = ""
	local totalSuffix = ""
	local entriesSuffix = ""
	local asc = CreateAtlasMarkup("editmode-up-arrow", 16, 11, 1, 4)
	local desc = CreateAtlasMarkup("editmode-down-arrow", 16, 11, 1, -4)
	local constants = ns.Constants

	if state.sortKey == constants.LEADERBOARD_SORT_RANK or not state.sortKey then
		rankSuffix = state.sortAsc and asc or desc
	elseif state.sortKey == constants.LEADERBOARD_SORT_NAME then
		nameSuffix = state.sortAsc and asc or desc
	elseif state.sortKey == constants.LEADERBOARD_SORT_TOTAL then
		totalSuffix = state.sortAsc and asc or desc
	elseif state.sortKey == constants.LEADERBOARD_SORT_ENTRIES then
		entriesSuffix = state.sortAsc and asc or desc
	end

	ns.ui.leaderboardUI.rankHeader:SetText("Rank" .. rankSuffix)
	ns.ui.leaderboardUI.nameHeader:SetText("Player" .. nameSuffix)
	ns.ui.leaderboardUI.totalHeader:SetText("Total" .. totalSuffix)
	ns.ui.leaderboardUI.entriesHeader:SetText("Tasks Completed" .. entriesSuffix)
end

--- Set the sort key and direction
--- @param sortKey string One of LEADERBOARD_SORT_* constants
local function SetSort(sortKey)
	local constants = ns.Constants
	if state.sortKey == sortKey then
		state.sortAsc = not state.sortAsc
	else
		state.sortKey = sortKey
		-- Default sort direction per column
		if sortKey == constants.LEADERBOARD_SORT_RANK then
			state.sortAsc = true  -- Rank 1 first
		elseif sortKey == constants.LEADERBOARD_SORT_NAME then
			state.sortAsc = true  -- A-Z
		elseif sortKey == constants.LEADERBOARD_SORT_TOTAL then
			state.sortAsc = false -- Highest first
		elseif sortKey == constants.LEADERBOARD_SORT_ENTRIES then
			state.sortAsc = false -- Most first
		end
	end

	UpdateSortHeader()
	Leaderboard.Refresh()
end

--- Set the current time range filter
--- @param range number One of TIME_RANGE constants
function Leaderboard.SetTimeRange(range)
	state.timeRange = range
end

--- Get the current time range filter
--- @return number timeRange Current time range filter
function Leaderboard.GetTimeRange()
	return state.timeRange
end

--- Get time range name for display
--- @param range number One of TIME_RANGE constants
--- @return string name Display name for the time range
function Leaderboard.GetTimeRangeName(range)
	if range == TIME_RANGE.TODAY then
		return "24 Hours"
	elseif range == TIME_RANGE.THIS_WEEK then
		return "7 Days"
	else
		return "Current Endeavor"
	end
end

--- Create a single leaderboard row
--- @param parent Frame The parent frame (scrollChild)
--- @param index number The row index
--- @return Frame row The created row
local function CreateLeaderboardRow(parent, index)
	local constants = ns.Constants
	parent["row" .. index] = CreateFrame("Frame", nil, parent)
	local row = parent["row" .. index]
	row:SetHeight(constants.LEADERBOARD_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * constants.LEADERBOARD_ROW_HEIGHT))
	row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * constants.LEADERBOARD_ROW_HEIGHT))
	
	-- Enable mouse events for tooltips
	row:EnableMouse(true)

	-- Rank number
	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.rank:SetPoint("LEFT", 6, 0)
	row.rank:SetWidth(constants.LEADERBOARD_RANK_WIDTH)
	row.rank:SetJustifyH("LEFT")

	-- Display name
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", row.rank, "RIGHT", 0, 0)
	row.name:SetWidth(constants.LEADERBOARD_NAME_WIDTH)
	row.name:SetJustifyH("LEFT")

	-- Addon indicator icon (shows if player is using Endeavoring)
	row.addonIcon = row:CreateTexture(nil, "OVERLAY")
	row.addonIcon:SetSize(16, 16)
	row.addonIcon:SetPoint("RIGHT", row.name, "LEFT", -4, 0)
	row.addonIcon:SetTexture("Interface/AddOns/Endeavoring/Icons/endeavoring.png")
	row.addonIcon:Hide() -- Hidden by default, shown for synced profiles

	-- Total contribution
	row.total = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.total:SetWidth(constants.LEADERBOARD_TOTAL_WIDTH)
	row.total:SetJustifyH("RIGHT")
	row.total:SetPoint("LEFT", row.name, "RIGHT", 0, 0)

	-- Number of entries
	row.entries = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.entries:SetWidth(constants.LEADERBOARD_ENTRIES_WIDTH)
	row.entries:SetJustifyH("RIGHT")
	row.entries:SetPoint("LEFT", row.total, "RIGHT", 0, 0)
	
	-- Tooltip handlers
	row:SetScript("OnEnter", function(self)
		if not self.data or not self.data.charNames or #self.data.charNames == 0 then
			return
		end
		
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT", 4, 0)
		GameTooltip:SetText(self.data.displayName, 1, 1, 1, 1, true)
		GameTooltip:AddLine("<Endeavoring User>", 86/255, 130/255, 3/255)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Contributing Characters:", 0.5, 0.5, 0.5)
		
		for _, charName in ipairs(self.data.charNames) do
			GameTooltip:AddLine(charName, 1, 0.82, 0)
		end
		
		GameTooltip:Show()
	end)
	
	row:SetScript("OnLeave", function(self)
		GameTooltip:Hide()
	end)

	return row
end

--- Update the time range filter button highlights
local function UpdateFilterButtons()
	if not ns.ui.leaderboardUI then
		return
	end

	local leaderboardUI = ns.ui.leaderboardUI
	local currentRange = state.timeRange

	for range, button in pairs(leaderboardUI.filterButtons) do
		if range == currentRange then
			button:Disable()
			button:SetAlpha(1.0)
		else
			button:Enable()
			button:SetAlpha(0.7)
		end
	end
end

--- Set the time range filter and refresh
--- @param range number One of TIME_RANGE constants
local function SetTimeRangeFilter(range)
	Leaderboard.SetTimeRange(range)
	ns.API.RequestActivityLog() -- Trigger refresh with new time range
	UpdateFilterButtons()
end

--- Internal function to update leaderboard display with current data
local function UpdateLeaderboardDisplay()
	if not ns.ui.leaderboardUI then
		return
	end

	local leaderboardUI = ns.ui.leaderboardUI
	local constants = ns.Constants
	local activityLog = ns.ActivityLogCache.Get()

	-- Check if activity log is loaded (follows Blizzard's pattern)
	if not activityLog or not activityLog.isLoaded then
		leaderboardUI.emptyText:SetText("Loading activity data...")
		leaderboardUI.emptyText:Show()
		for _, row in ipairs(leaderboardUI.rows) do
			row:Hide()
		end
		return
	end

	if not activityLog.taskActivity or #activityLog.taskActivity == 0 then
		leaderboardUI.emptyText:SetText(constants.NO_LEADERBOARD_DATA)
		leaderboardUI.emptyText:Show()
		for _, row in ipairs(leaderboardUI.rows) do
			row:Hide()
		end
		return
	end

	local leaderboard = Leaderboard.BuildEnriched(activityLog, state.timeRange)
	if #leaderboard == 0 then
		leaderboardUI.emptyText:SetText(constants.NO_LEADERBOARD_DATA)
		leaderboardUI.emptyText:Show()
		for _, row in ipairs(leaderboardUI.rows) do
			row:Hide()
		end
		return
	end

	-- Apply custom sorting
	leaderboard = BuildSortedLeaderboard(leaderboard)

	leaderboardUI.emptyText:Hide()
	local totalHeight = #leaderboard * constants.LEADERBOARD_ROW_HEIGHT
	leaderboardUI.scrollChild:SetHeight(totalHeight)
	local scrollWidth = leaderboardUI.scrollFrame and leaderboardUI.scrollFrame:GetWidth() or 1
	if scrollWidth and scrollWidth > 0 then
		leaderboardUI.scrollChild:SetWidth(scrollWidth)
	end

	for index, entry in ipairs(leaderboard) do
		local row = leaderboardUI.rows[index]
		if not row then
			row = CreateLeaderboardRow(leaderboardUI.scrollChild, index)
			leaderboardUI.rows[index] = row
		end

		row.data = entry
		row.rank:SetText(tostring(entry.rank or index))
		row.name:SetText(entry.displayName or "Unknown")
		row.total:SetText(string.format("%.3f", entry.total or 0))
		row.entries:SetText(tostring(entry.entries or 0))
		
		-- Show addon icon for synced profiles
		if entry.hasSyncedProfile then
			row.addonIcon:Show()
		else
			row.addonIcon:Hide()
		end

		-- Highlight local player
		if entry.isLocalPlayer then
			row.rank:SetTextColor(0.1, 1.0, 0.1)
			row.name:SetTextColor(0.1, 1.0, 0.1)
			row.total:SetTextColor(0.1, 1.0, 0.1)
			row.entries:SetTextColor(0.1, 1.0, 0.1)
		else
			row.rank:SetTextColor(1, 0.82, 0)
			row.name:SetTextColor(1, 1, 1)
			row.total:SetTextColor(1, 1, 1)
			row.entries:SetTextColor(1, 1, 1)
		end

		row:Show()
	end

	-- Hide unused rows
	for index = #leaderboard + 1, #leaderboardUI.rows do
		leaderboardUI.rows[index]:Hide()
	end
end

--- Refresh the leaderboard display
function Leaderboard.Refresh()
	UpdateLeaderboardDisplay()
end

--- Create the leaderboard tab UI
--- @param parent Frame The parent frame
--- @return Frame content The leaderboard tab content
function Leaderboard.CreateTab(parent)
	local constants = ns.Constants
	parent.leaderboard = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
	local content = parent.leaderboard
	content:SetPoint("TOPLEFT", parent.TabSystem, "BOTTOMLEFT", -2, 0)
	content:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -12, 12)

	-- Time range filter buttons
	content.filterContainer = CreateFrame("Frame", nil, content)
	local filterContainer = content.filterContainer
	filterContainer:SetPoint("TOPLEFT", 4, -4)
	filterContainer:SetPoint("TOPRIGHT", -4, -4)
	filterContainer:SetHeight(constants.LEADERBOARD_FILTER_HEIGHT)

	local filterButtons = {}
	local filterOrder = {TIME_RANGE.CURRENT_ENDEAVOR, TIME_RANGE.THIS_WEEK, TIME_RANGE.TODAY}
	for i, range in ipairs(filterOrder) do
		local button = CreateFrame("Button", nil, filterContainer, "UIPanelButtonTemplate")
		button:SetSize(constants.LEADERBOARD_FILTER_BUTTON_WIDTH, constants.LEADERBOARD_FILTER_BUTTON_HEIGHT)
		button:SetText(Leaderboard.GetTimeRangeName(range))
		button:SetScript("OnClick", function()
			SetTimeRangeFilter(range)
		end)

		if i == 1 then
			button:SetPoint("LEFT", 4, 0)
		else
			button:SetPoint("LEFT", filterButtons[filterOrder[i-1]], "RIGHT", 4, 0)
		end

		filterButtons[range] = button
	end

	-- Header row
	local header = CreateFrame("Frame", nil, content)
	header:SetPoint("TOPLEFT", filterContainer, "BOTTOMLEFT", 0, -8)
	header:SetPoint("TOPRIGHT", filterContainer, "BOTTOMRIGHT", 0, -8)
	header:SetHeight(constants.LEADERBOARD_HEADER_HEIGHT)

	local rankHeader = CreateFrame("Button", nil, header)
	rankHeader:SetPoint("LEFT", 6, 0)
	rankHeader:SetSize(constants.LEADERBOARD_RANK_WIDTH, constants.LEADERBOARD_HEADER_HEIGHT)
	rankHeader:SetScript("OnClick", function()
		SetSort(constants.LEADERBOARD_SORT_RANK)
	end)
	rankHeader.text = rankHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	rankHeader.text:SetAllPoints()
	rankHeader.text:SetJustifyH("LEFT")
	rankHeader.text:SetText("Rank")

	local nameHeader = CreateFrame("Button", nil, header)
	nameHeader:SetPoint("LEFT", rankHeader, "RIGHT", 0, 0)
	nameHeader:SetSize(constants.LEADERBOARD_NAME_WIDTH, constants.LEADERBOARD_HEADER_HEIGHT)
	nameHeader:SetScript("OnClick", function()
		SetSort(constants.LEADERBOARD_SORT_NAME)
	end)
	nameHeader.text = nameHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	nameHeader.text:SetAllPoints()
	nameHeader.text:SetJustifyH("LEFT")
	nameHeader.text:SetText("Player")

	-- Account for scrollbar width from UIPanelScrollFrameTemplate
	local scrollbarOffset = constants.SCROLLBAR_WIDTH
	
	local totalHeader = CreateFrame("Button", nil, header)
	totalHeader:SetPoint("LEFT", nameHeader, "RIGHT", 0, 0)
	totalHeader:SetSize(constants.LEADERBOARD_TOTAL_WIDTH, constants.LEADERBOARD_HEADER_HEIGHT)
	totalHeader:SetScript("OnClick", function()
		SetSort(constants.LEADERBOARD_SORT_TOTAL)
	end)
	totalHeader.text = totalHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	totalHeader.text:SetAllPoints()
	totalHeader.text:SetJustifyH("RIGHT")
	totalHeader.text:SetText("Total")

	local entriesHeader = CreateFrame("Button", nil, header)
	entriesHeader:SetPoint("LEFT", totalHeader, "RIGHT", 0, 0)
	entriesHeader:SetSize(constants.LEADERBOARD_ENTRIES_WIDTH, constants.LEADERBOARD_HEADER_HEIGHT)
	entriesHeader:SetScript("OnClick", function()
		SetSort(constants.LEADERBOARD_SORT_ENTRIES)
	end)
	entriesHeader.text = entriesHeader:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	entriesHeader.text:SetAllPoints()
	entriesHeader.text:SetJustifyH("RIGHT")
	entriesHeader.text:SetText("Tasks Completed")

	-- Scroll frame
	local scrollFrame = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
	scrollFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -26, 5)

	scrollFrame.scrollChild = CreateFrame("Frame", nil, scrollFrame)
	local scrollChild = scrollFrame.scrollChild
	scrollChild:SetPoint("TOPLEFT")
	scrollChild:SetPoint("TOPRIGHT")
	scrollChild:SetHeight(1)
	scrollChild:SetWidth(1)
	scrollFrame:SetScrollChild(scrollChild)
	scrollFrame:HookScript("OnSizeChanged", function(_, width)
		scrollChild:SetWidth(width)
	end)

	-- Empty state text
	local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("CENTER", scrollFrame, "CENTER")
	emptyText:SetText(constants.NO_LEADERBOARD_DATA)
	emptyText:Hide()

	-- Register event handler for activity log updates (only refresh when visible)
	content:RegisterEvent("INITIATIVE_ACTIVITY_LOG_UPDATED")
	content:SetScript("OnEvent", function(self, event)
		if event == "INITIATIVE_ACTIVITY_LOG_UPDATED" and self:IsVisible() then
			UpdateLeaderboardDisplay()
		end
	end)

	-- Store references
	content.filterButtons = filterButtons
	content.header = header
	content.rankHeader = rankHeader.text
	content.nameHeader = nameHeader.text
	content.totalHeader = totalHeader.text
	content.entriesHeader = entriesHeader.text
	content.scrollFrame = scrollFrame
	content.scrollChild = scrollChild
	content.emptyText = emptyText
	content.rows = {}

	ns.ui.leaderboardUI = content
	UpdateFilterButtons()
	UpdateSortHeader()  -- Initialize sort indicators

	content:Hide()
	return content
end

-- Export constants
Leaderboard.TIME_RANGE = TIME_RANGE
