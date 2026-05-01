---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local constants = ns.Constants
local L = ns.L

local DebugPrint = ns.DebugPrint

local function InitializeTabSystem(frame)
	-- Apply TabSystemOwnerMixin to main frame
	Mixin(frame, TabSystemOwnerMixin)
	TabSystemOwnerMixin.OnLoad(frame)

	-- Create TabSystem child frame programmatically
	local tabSystem = CreateFrame("Frame", nil, frame, "HorizontalLayoutFrame")
	Mixin(tabSystem, TabSystemMixin)

	-- Configure TabSystem properties BEFORE OnLoad (used during initialization)
	tabSystem.minTabWidth = 100
	tabSystem.maxTabWidth = 150
	tabSystem.tabTemplate = "TabSystemTopButtonTemplate"
	tabSystem.spacing = 1
	tabSystem.tabSelectSound = SOUNDKIT.IG_CHARACTER_INFO_TAB

	-- Initialize TabSystem (creates frame pool with tabTemplate)
	tabSystem:OnLoad()

	-- Position TabSystem below header (hanging off top)
	tabSystem:SetPoint("BOTTOMLEFT", frame.header, "BOTTOMLEFT", 8, -2)

	-- Link TabSystem to frame
	frame.TabSystem = tabSystem
	frame:SetTabSystem(tabSystem)

	-- Register tabs with their content frames
	frame.tasksTabID = frame:AddNamedTab(L["Tasks"], ns.Tasks.CreateTab(frame))
	frame.leaderboardTabID = frame:AddNamedTab(L["Leaderboard"], ns.Leaderboard.CreateTab(frame))
	frame.activityTabID = frame:AddNamedTab(L["Activity"], ns.Activity.CreateTab(frame))

	-- Hook tab selection to save preference
	local originalSetTab = frame.SetTab
	frame.SetTab = function(self, tabID, ...)
		originalSetTab(self, tabID, ...)
		if ns.Settings then
			ns.Settings.SaveLastTab(tabID)
		end
	end

	-- Set initial tab based on user preference
	local startupTab = frame.tasksTabID  -- Default to Tasks
	if ns.Settings then
		local startupTabID = ns.Settings.GetStartupTab()
		if startupTabID == 1 then
			startupTab = frame.tasksTabID
		elseif startupTabID == 2 then
			startupTab = frame.leaderboardTabID
		elseif startupTabID == 3 then
			startupTab = frame.activityTabID
		end
	end
	frame:SetTab(startupTab, false)
end

local function RefreshInitiativeUI()
	ns.Header.Refresh()
	ns.Tasks.Refresh()
end

local function CreateMainFrame()
	local frame = CreateFrame("Frame", "EndeavoringFrame", UIParent, "PortraitFrameTemplate")
	frame.TitleContainer.TitleText:SetText(addonName)
	frame:SetPortraitToAsset("Interface/AddOns/Endeavoring/Icons/endeavoring_panel_portrait.png")
	frame:SetSize(constants.FRAME_WIDTH, constants.FRAME_HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)

	-- Register with UISpecialFrames to allow ESC key to close
	tinsert(UISpecialFrames, "EndeavoringFrame")

	-- Settings gear button next to close button
	local settingsButton = CreateFrame("Button", nil, frame)
	settingsButton:SetFrameLevel(EndeavoringFrameCloseButton:GetFrameLevel())
	settingsButton:SetSize(24, 24)
	settingsButton:SetPoint("RIGHT", EndeavoringFrameCloseButton, "LEFT", 0, -2)
	settingsButton:SetNormalAtlas("common-dropdown-a-button-settings-open-shadowless")
	settingsButton:SetPushedAtlas("common-dropdown-a-button-settings-pressedhover-shadowless")
	settingsButton:SetHighlightAtlas("common-dropdown-a-button-settings-hover-shadowless", "ADD")
	settingsButton:SetScript("OnClick", function()
		if ns.Settings and ns.Settings.Open then
			ns.Settings.Open()
		end
	end)
	settingsButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, L["Settings"])
		GameTooltip_AddNormalLine(GameTooltip, L["Open Endeavoring settings panel"])
		GameTooltip:Show()
	end)
	settingsButton:SetScript("OnLeave", GameTooltip_Hide)
	settingsButton:Show()
	frame.settingsButton = settingsButton

	frame.header = ns.Header.Create(frame)
	InitializeTabSystem(frame)
	frame:SetScript("OnShow", function()
		ns.API.RequestInitiativeInfo()
		-- Note: RequestActivityLog() is intentionally NOT called here directly.
		-- The NEIGHBORHOOD_INITIATIVE_UPDATED handler calls it after the initiative
		-- info response arrives. This sequential pattern (matching Blizzard's own
		-- Housing Dashboard) gives the server time to fully aggregate the activity
		-- log before we request it, avoiding partial responses.
		RefreshInitiativeUI()
	end)

	frame:Hide()
	ns.ui.mainFrame = frame
	return frame
end

local function ToggleMainFrame()
	if not ns.ui.mainFrame then
		ns.ui.mainFrame = CreateMainFrame()
	end

	if ns.ui.mainFrame:IsShown() then
		ns.ui.mainFrame:Hide()
	else
		ns.ui.mainFrame:Show()
	end
end

ns.ToggleMainFrame = ToggleMainFrame
ns.RefreshInitiativeUI = RefreshInitiativeUI

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_HOUSE_LIST_UPDATED")
eventFrame:RegisterEvent("NEIGHBORHOOD_INITIATIVE_UPDATED")
eventFrame:RegisterEvent("INITIATIVE_COMPLETED")
eventFrame:RegisterEvent("INITIATIVE_TASK_COMPLETED")
eventFrame:RegisterEvent("INITIATIVE_ACTIVITY_LOG_UPDATED")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_ENTERING_WORLD" then
		local isLogin, isReload = ...

		-- Initialize database
		ns.DB.Init()

		-- Initialize sync service
		ns.AddonMessages.Init()
		ns.AddonMessages.RegisterListener()
		
		-- Register current character
		local success = ns.DB.RegisterCurrentCharacter()
		if success then
			-- Broadcast manifest on true login (not reload)
			if isLogin then
				ns.Coordinator.SendManifestDebounced()
			end
		end
		
		ns.Commands.Register()

		ns.API.ViewActiveNeighborhood()
		RunNextFrame(function() ns.API.RequestPlayerHouses() end)

		-- Join neighborhood position channel and initialize neighborhood-scoped services (if in a neighborhood zone)
		RunNextFrame(function()
			-- Use C_Housing.GetCurrentNeighborhoodGUID() to check if player is actually IN a neighborhood zone
			-- (not just if a neighborhood is "active" via the Initiative system)
			local currentZoneGuid = C_Housing and C_Housing.GetCurrentNeighborhoodGUID and C_Housing.GetCurrentNeighborhoodGUID()
			if currentZoneGuid then
				DebugPrint(string.format("[Core] PLAYER_ENTERING_WORLD — in neighborhood zone GUID=%s, initializing position services", tostring(currentZoneGuid)))

				-- Initialize position cache service (starts cleanup timer)
				if ns.PositionService and ns.PositionService.Init then
					ns.PositionService.Init()
				end

				-- Initialize NeighborhoodMap overlay (creates frame, hooks WorldMapFrame show/hide,
				-- registers PositionService change listener for on-demand re-render).
				if ns.NeighborhoodMap and ns.NeighborhoodMap.Init then
					ns.NeighborhoodMap.Init()
				end

				-- Initialize NeighborhoodMinimap overlay (creates frame anchored to Minimap,
				-- registers PositionService change listener for real-time re-render).
				if ns.NeighborhoodMinimap and ns.NeighborhoodMinimap.Init then
					ns.NeighborhoodMinimap.Init()
				end

				-- Initialize position broadcaster (registers PLAYER_STARTED_MOVING handler internally;
				-- debounce is handled inside PositionBroadcaster — Core just calls Init here.
				-- Event flow: PLAYER_STARTED_MOVING → PositionBroadcaster.OnPlayerMoving (debounce)
				--             → PositionBroadcaster.BroadcastPosition fires ~1.5s after last move)
				if ns.PositionBroadcaster and ns.PositionBroadcaster.Init then
					ns.PositionBroadcaster.Init()
				end

				-- Join neighborhood position channel
				if ns.Position and ns.Position.JoinNeighborhood then
					ns.Position.JoinNeighborhood(currentZoneGuid)
				end
			else
				DebugPrint("[Core] PLAYER_ENTERING_WORLD — not in a neighborhood zone; skipping position services initialization")
			end
		end)

		return
	end

	if event == "ZONE_CHANGED_NEW_AREA" then
		-- Use C_Housing.GetCurrentNeighborhoodGUID() to check if player is actually IN a neighborhood zone
		local newZoneGuid = C_Housing and C_Housing.GetCurrentNeighborhoodGUID and C_Housing.GetCurrentNeighborhoodGUID()
		local oldGuid = ns.Position.GetActiveNeighborhoodGUID()

		if newZoneGuid ~= oldGuid then
			DebugPrint(string.format(
				"[Core] ZONE_CHANGED_NEW_AREA — neighborhood zone changed: old=%s new=%s",
				tostring(oldGuid), tostring(newZoneGuid)
			))
			if oldGuid then
				-- Leaving a neighborhood: shutdown position services
				if ns.PositionBroadcaster and ns.PositionBroadcaster.Shutdown then
					ns.PositionBroadcaster.Shutdown()
				end
				if ns.NeighborhoodMap and ns.NeighborhoodMap.Shutdown then
					ns.NeighborhoodMap.Shutdown()
				end
				if ns.NeighborhoodMinimap and ns.NeighborhoodMinimap.Shutdown then
					ns.NeighborhoodMinimap.Shutdown()
				end
				if ns.PositionService and ns.PositionService.Shutdown then
					ns.PositionService.Shutdown()
				end
				if ns.Position and ns.Position.LeaveNeighborhood then
					ns.Position.LeaveNeighborhood(oldGuid)
				end
			end
			if newZoneGuid then
				-- Entering a neighborhood: initialize position services
				if ns.PositionService and ns.PositionService.Init then
					ns.PositionService.Init()
				end
				if ns.NeighborhoodMap and ns.NeighborhoodMap.Init then
					ns.NeighborhoodMap.Init()
				end
				if ns.NeighborhoodMinimap and ns.NeighborhoodMinimap.Init then
					ns.NeighborhoodMinimap.Init()
				end
				if ns.PositionBroadcaster and ns.PositionBroadcaster.Init then
					ns.PositionBroadcaster.Init()
				end
				if ns.Position and ns.Position.JoinNeighborhood then
					ns.Position.JoinNeighborhood(newZoneGuid)
				end
			end
		else
			DebugPrint(string.format(
				"[Core] ZONE_CHANGED_NEW_AREA — same neighborhood zone GUID=%s; no channel change",
				tostring(newZoneGuid)
			))
		end
		return
	end

	if event == "ADDON_LOADED" then
		local housingDash = ns.Integrations.HousingDashboard
		local addonNameLoaded = ...
		if addonNameLoaded == housingDash.GetAddonName() and housingDash.EnsureLoaded() then
			housingDash.RegisterButtonHook()
		end
		return
	end

	if event == "PLAYER_HOUSE_LIST_UPDATED" then
		-- House list loaded, now request initiative info
		ns.API.RequestInitiativeInfo()
		return
	end

	if event == "NEIGHBORHOOD_INITIATIVE_UPDATED" then
		-- Initiative data has loaded/updated, refresh UI
		RefreshInitiativeUI()
		-- Also request activity log to ensure it's up to date
		ns.API.RequestActivityLog()
		return
	end

	if event == "INITIATIVE_COMPLETED" or event == "INITIATIVE_TASK_COMPLETED" then
		RefreshInitiativeUI()
	end

	if event == "INITIATIVE_ACTIVITY_LOG_UPDATED" then
		-- Activity log has been loaded/updated
		ns.ActivityLogCache.OnActivityLogUpdated()
	end

	if event == "GUILD_ROSTER_UPDATE" then
		-- Debounced broadcast on guild roster changes (with random delay)
		ns.Coordinator.OnGuildRosterUpdate()
	end

	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit == "player" and spellID == ns.Constants.ENDEAVOR_COFFER_SPELL_ID then
			-- Player just opened the Endeavor Coffer - auto-mark as claimed
			local ok, err = pcall(ns.Header.AutoClaimChest)
			if not ok then
				DebugPrint(string.format(L["FMT_DBG_AutoClaimChestFailed"], tostring(err)))
			end
		end
	end
end)

--@alpha@
if not NDVRNG then
	NDVRNG = ns
else
	error("Namespace conflict: NDVRNG is already defined. Please ensure only one addon is using the NDVRNG namespace.")
end
--@end-alpha@
