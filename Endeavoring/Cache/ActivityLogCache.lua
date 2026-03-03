---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local ActivityLogCache = {}
ns.ActivityLogCache = ActivityLogCache

--[[
Activity Log Cache

PURPOSE:
- Provides cached access to initiative activity log data
- Improves UX by showing last-known data immediately while fetching updates
- Mitigates Blizzard API flakiness (especially after zone changes)

ARCHITECTURE:
- Sits between Features (Activity, Leaderboard) and Services (NeighborhoodAPI)
- Reads from Database for persistence, writes back on updates
- Orchestrates background refresh strategy

USAGE:
- Call ActivityLogCache.Get() instead of ns.API.GetActivityLogInfo()
- Cache automatically handles background updates and staleness checks

INVALIDATION:
- Cache respects Blizzard's nextUpdateTime field
- Updates on INITIATIVE_ACTIVITY_LOG_UPDATED event
- Clears on INITIATIVE_COMPLETED
--]]

local DebugPrint = ns.DebugPrint

-- Guard to prevent re-entrant stale cache refresh requests.
-- When stale data triggers RequestInitiativeInfo, the event response can
-- synchronously fire NEIGHBORHOOD_INITIATIVE_UPDATED → RequestActivityLog →
-- INITIATIVE_ACTIVITY_LOG_UPDATED → Get() again, creating an infinite cycle.
local staleRefreshPending = false

--- Get activity log info with caching support
--- Returns cached data immediately if available, schedules background update
--- @return table|nil activityLogInfo The activity log info (cached or live)
function ActivityLogCache.Get()
	-- Try to get live data first
	local liveData = ns.API.GetActivityLogInfo()
	
	-- Get active neighborhood GUID
	local neighborhoodGUID = ns.API.GetActiveNeighborhoodGUID()
	
	if not neighborhoodGUID then
		-- No active neighborhood, return live data (or nil)
		return liveData
	end
	
	-- Check if live data is loaded
	if liveData and liveData.isLoaded and #liveData.taskActivity > 0 then
		-- Live data is loaded, update cache and return it
		ns.DB.SetActivityLogCache(neighborhoodGUID, liveData)
		staleRefreshPending = false
		return liveData
	end
	
	-- Live data not loaded yet, try to return cached data
	local cachedData, isStale = ns.DB.GetActivityLogCache(neighborhoodGUID)
	if cachedData then
		if isStale and not staleRefreshPending then
			-- Defer the request to next frame to break any synchronous event cycle
			staleRefreshPending = true
			C_Timer.After(0, function()
				ns.API.RequestInitiativeInfo()
			end)
		end
		
		return cachedData
	end
	
	-- No cache available, return live data (even if not loaded)
	return liveData
end

--- Refresh tabs that use activity log data, but only if visible
function ActivityLogCache.RefreshVisibleTabs()
	if not ns.ui.mainFrame or not ns.ui.mainFrame:IsShown() then
		return
	end
	
	local selectedTab = ns.ui.mainFrame:GetTab()
	if selectedTab == ns.ui.mainFrame.activityTabID and ns.Activity then
		ns.Activity.Refresh()
	elseif selectedTab == ns.ui.mainFrame.leaderboardTabID and ns.Leaderboard then
		ns.Leaderboard.Refresh()
	end
end

--- Handle INITIATIVE_ACTIVITY_LOG_UPDATED event
--- Updates cache and refreshes visible tabs
function ActivityLogCache.OnActivityLogUpdated()
	local activityLogInfo = ns.API.GetActivityLogInfo()
	if not activityLogInfo or not activityLogInfo.isLoaded or #activityLogInfo.taskActivity == 0 then
		DebugPrint("Activity log updated event received, but data is not loaded or empty. Ignoring.")
		return
	end
	
	-- Get active neighborhood GUID to update cache
	local neighborhoodGUID = ns.API.GetActiveNeighborhoodGUID()
	
	if not neighborhoodGUID then
		return
	end
	
	-- Update cache
	ns.DB.SetActivityLogCache(neighborhoodGUID, activityLogInfo)
	
	-- Refresh visible tabs
	ActivityLogCache.RefreshVisibleTabs()
end
