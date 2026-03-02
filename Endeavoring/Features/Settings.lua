---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

-- Capture WoW's Settings API before shadowing it with our module
local WoWSettings = Settings

local Settings = {}
ns.Settings = Settings

-- Shortcuts
local INFO = ns.Constants.PREFIX_INFO
local ERROR = ns.Constants.PREFIX_ERROR
local DB = ns.DB

--- Settings variable name for WoW Settings system
local SETTINGS_VARIABLE_PREFIX = "ENDEAVORING_"

--- Tab options for dropdown
local TAB_OPTIONS = {
	{ value = 1, label = "Tasks" },
	{ value = 2, label = "Leaderboard" }, 
	{ value = 3, label = "Activity" }
}

--- Initialize settings with defaults if needed
local function InitializeDefaults()
	local defaults = DB.GetSettings()
	if not defaults then
		DB.SetSettings({
			defaultTab = 1,  -- Tasks
			rememberLastTab = true,
			debugMode = false
		})
	end
end

--- Get current settings
--- @return table Settings table
function Settings.Get()
	return DB.GetSettings() or {}
end

--- Get the tab that should be shown on open
--- @return number Tab ID (1=Tasks, 2=Leaderboard, 3=Activity)
function Settings.GetStartupTab()
	local settings = Settings.Get()
	
	-- If remember last tab is enabled, check for saved tab
	if settings.rememberLastTab then
		local lastTab = DB.GetLastSelectedTab()
		if lastTab then
			return lastTab
		end
	end
	
	-- Fall back to default tab
	return settings.defaultTab or 1
end

--- Save the currently selected tab
--- @param tabID number The tab ID to remember
function Settings.SaveLastTab(tabID)
	local settings = Settings.Get()
	if settings.rememberLastTab then
		DB.SetLastSelectedTab(tabID)
	end
end

--- Register the settings panel with WoW's Settings system
function Settings.Register()
	-- Wait for addon to fully load
	EventUtil.ContinueOnAddOnLoaded(addonName, function()
		InitializeDefaults()
		
		-- Create main settings category
		local category, layout = WoWSettings.RegisterVerticalLayoutCategory("Endeavoring")
		
		-- Add section header
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("General"))
		
		-- Remember Last Tab checkbox (first, as it affects the Default Tab behavior)
		do
			local variable = SETTINGS_VARIABLE_PREFIX .. "REMEMBER_LAST_TAB"
			local name = "Remember Last Tab"
			local tooltip = "Resume where you left off, even after /reload or logout. When enabled, this overrides the Default Tab setting below."
			
			local function GetValue()
				return Settings.Get().rememberLastTab
			end
			
			local function SetValue(value)
				local settings = Settings.Get()
				settings.rememberLastTab = value
				DB.SetSettings(settings)
				
				-- If disabling, clear the saved tab
				if not value then
					DB.SetLastSelectedTab(nil)
				end
			end
			
			local defaultValue = true
			local setting = WoWSettings.RegisterProxySetting(category, variable,
				WoWSettings.VarType.Boolean, name, defaultValue, GetValue, SetValue)
			WoWSettings.CreateCheckbox(category, setting, tooltip)
		end
		
		-- Default Tab dropdown (only used when Remember Last Tab is disabled)
		do
			local variable = SETTINGS_VARIABLE_PREFIX .. "DEFAULT_TAB"
			local name = "Default Tab"
			local tooltip = "Which tab to open when 'Remember Last Tab' is disabled. This setting is ignored when remembering your last tab."
			
			local function GetValue()
				return Settings.Get().defaultTab or 1
			end
			
			local function SetValue(value)
				local settings = Settings.Get()
				settings.defaultTab = value
				DB.SetSettings(settings)
			end
			
			local function GetOptions()
				local container = WoWSettings.CreateControlTextContainer()
				for _, option in ipairs(TAB_OPTIONS) do
					container:Add(option.value, option.label)
				end
				return container:GetData()
			end
			
			local defaultValue = 1
			local setting = WoWSettings.RegisterProxySetting(category, variable,
				WoWSettings.VarType.Number, name, defaultValue, GetValue, SetValue)
			WoWSettings.CreateDropdown(category, setting, GetOptions, tooltip)
		end
		
		-- Player Alias section
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Player Alias"))
		
		-- Show Current Alias button
		do
			local name = "Change Player Alias"
			local tooltip = "Set a custom display name for leaderboards and activity logs"
			
			local function OnButtonClick()
				local currentAlias = DB.GetPlayerAlias() or ""
				local displayAlias = currentAlias ~= "" and currentAlias or "None"
				-- Pass displayAlias as text_arg1 for the %s placeholder, and currentAlias as data
				StaticPopup_Show("ENDEAVORING_SET_ALIAS", displayAlias, nil, currentAlias)
			end
			
			local addSearchTags = true
			local initializer = CreateSettingsButtonInitializer("", name, OnButtonClick, tooltip, addSearchTags)
			layout:AddInitializer(initializer)
		end
		
		-- Debug section
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Debug"))
		
-- Enable Debug Logs checkbox
	do
		local variable = SETTINGS_VARIABLE_PREFIX .. "DEBUG_MODE"
		local name = "Enable Debug Logs"
		local tooltip = "Show detailed debug information in chat to help troubleshoot issues"
			
			local function GetValue()
				return DB.IsVerboseDebug()
			end
			
			local function SetValue(value)
				DB.SetVerboseDebug(value)
				local settings = Settings.Get()
				settings.debugMode = value
				DB.SetSettings(settings)
				
				if value then
					print(INFO .. " Debug mode enabled. Use /chatlog to stream logs to a file.")
				else
					print(INFO .. " Debug mode disabled.")
				end
			end
			
			local defaultValue = false
			local setting = WoWSettings.RegisterProxySetting(category, variable,
				WoWSettings.VarType.Boolean, name, defaultValue, GetValue, SetValue)
			WoWSettings.CreateCheckbox(category, setting, tooltip)
		end
		
		-- About section
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("About"))
		
		-- Version and Author info
		do
			local name = "View Addon Info"
			local tooltip = "View version, author, and attribution information"
			
			local function OnButtonClick()
				StaticPopup_Show("ENDEAVORING_ABOUT")
			end
			
			local addSearchTags = true
			local initializer = CreateSettingsButtonInitializer("", name, OnButtonClick, tooltip, addSearchTags)
			layout:AddInitializer(initializer)
		end
		
		-- Register the category
		WoWSettings.RegisterAddOnCategory(category)
		
		-- Store category ID for easy access
		ns.settingsCategoryID = category:GetID()
	end)
end

--- Open the settings panel
function Settings.Open()
	if ns.settingsCategoryID then
		WoWSettings.OpenToCategory(ns.settingsCategoryID)
	else
		print(INFO .. " Settings not yet initialized. Please try again in a moment.")
	end
end

-- Register dialog for setting player alias
StaticPopupDialogs["ENDEAVORING_SET_ALIAS"] = {
	text = "Set your player alias for Endeavoring.\n\nThis name will appear in leaderboards and activity logs instead of your BattleTag.\n\nCurrent alias: %s",
	button1 = "Set Alias",
	button2 = "Cancel",
	hasEditBox = 1,
	maxLetters = 20,
	OnShow = function(dialog, data)
		-- data contains the current alias
		local currentAlias = data or ""
		dialog.EditBox:SetText(currentAlias)
		dialog.EditBox:SetFocus()
		dialog.EditBox:HighlightText()
	end,
	OnAccept = function(dialog)
		local newAlias = dialog.EditBox:GetText()
		if newAlias and newAlias ~= "" then
			if DB.SetPlayerAlias(newAlias) then
				print(INFO .. " Alias set to: " .. newAlias)
				-- Broadcast updated manifest
				if ns.Coordinator then
					ns.Coordinator.SendManifestDebounced()
				end
				if ns.API then
					ns.API.RequestActivityLog()
				end
			else
				print(ERROR .. " Failed to set alias. Make sure you're logged in.")
			end
		end
	end,
	EditBoxOnEnterPressed = function(editBox)
		local dialog = editBox:GetParent()
		if dialog.button1:IsEnabled() then
			StaticPopup_OnClick(dialog, 1)
		end
	end,
	EditBoxOnEscapePressed = function(editBox)
		editBox:GetParent():Hide()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Register about/attribution dialog
StaticPopupDialogs["ENDEAVORING_ABOUT"] = {
	text = "|cFFFFD700Endeavoring|r\n\n" ..
	       "|cFFFFFFFFVersion:|r @project-version@\n" ..
	       "|cFFFFFFFFAuthor:|r McTalian\n\n" ..
	       "|cFF00FF00Attributions:|r\n" ..
	       "Addon icon by Delapouite (delapouite.com)\n" ..
	       "Licensed under CC BY 3.0\n" ..
	       "Modified and downloaded via game-icons.net\n\n" ..
	       "|cFF888888GitHub:|r github.com/McTalian-WoW-Addons/Endeavoring\n" ..
	       "|cFF888888Discord:|r discord.gg/czRYVWhe33",
	button1 = "Close",
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Auto-register settings on load
Settings.Register()
