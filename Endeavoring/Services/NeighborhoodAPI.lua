---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local API = {}
ns.API = API

local L = ns.L
local DebugPrint = ns.DebugPrint

function API.GetInitiativeInfo()
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo then
		return C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo()
	end

	return nil
end

function API.IsInitiativeActive()
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.IsInitiativeEnabled then
		return C_NeighborhoodInitiative.IsInitiativeEnabled()
	end

	return false
end

function API.IsInitiativeCompleted()
	local info = API.GetInitiativeInfo()

	if info and info.currentProgress >= info.progressRequired then
		return true
	end

	return false
end

function API.GetActiveNeighborhoodGUID()
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.GetActiveNeighborhood then
		return C_NeighborhoodInitiative.GetActiveNeighborhood()
	end

	return nil
end

function API.RequestInitiativeInfo()
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.RequestNeighborhoodInitiativeInfo then
		C_NeighborhoodInitiative.RequestNeighborhoodInitiativeInfo()
	end
end

function API.GetQuestRewardHouseXp(rewardQuestID)
	if not rewardQuestID or rewardQuestID == 0 then
		return nil
	end

	if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestLogRewardFavor then
		local ok, favor = pcall(C_QuestInfoSystem.GetQuestLogRewardFavor, rewardQuestID, 1)
		if ok and favor then
			return favor
		end
		ok, favor = pcall(C_QuestInfoSystem.GetQuestLogRewardFavor, rewardQuestID)
		if ok and favor then
			return favor
		end
	end

	return nil
end

function API.FormatTimeRemaining(durationSeconds)
	local fallback = ns.Constants.TIME_REMAINING_FALLBACK or "Time Remaining: --"
	if durationSeconds and durationSeconds > 0 then
		local timeLeftStr = SecondsToTime(durationSeconds, false, true, 1)
		if HOUSING_DASHBOARD_TIME_REMAINING then
			return HOUSING_DASHBOARD_TIME_REMAINING:format(timeLeftStr)
		end
		return "Time Remaining: " .. timeLeftStr
	end

	return fallback
end

function API.GetActivityLogInfo()
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.GetInitiativeActivityLogInfo then
		return C_NeighborhoodInitiative.GetInitiativeActivityLogInfo()
	end

	return nil
end

function API.RequestActivityLog()
	-- Follow Blizzard's pattern: no throttling, just request and trust the event system
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.RequestInitiativeActivityLog then
		C_NeighborhoodInitiative.RequestInitiativeActivityLog()
	end
end

--- Request player's owned houses list (required to initialize housing system)
function API.RequestPlayerHouses()
	if C_Housing and C_Housing.GetPlayerOwnedHouses then
		C_Housing.GetPlayerOwnedHouses()
	end
end

function API.ViewActiveNeighborhood()
	if C_NeighborhoodInitiative and C_NeighborhoodInitiative.SetViewingNeighborhood then
		if C_NeighborhoodInitiative.IsViewingActiveNeighborhood and C_NeighborhoodInitiative.IsViewingActiveNeighborhood() then
			return true
		end

		DebugPrint(L["DBG_SettingViewingNeighborhood"])

		if C_NeighborhoodInitiative.GetActiveNeighborhood then
			local activeNeighborhood = C_NeighborhoodInitiative.GetActiveNeighborhood()
			if activeNeighborhood then
				C_NeighborhoodInitiative.SetViewingNeighborhood(activeNeighborhood)
				return true
			end

			DebugPrint(L["DBG_NoActiveNeighborhood"])

			if C_Housing and C_Housing.GetCurrentNeighborhoodGUID then
				-- Fallback: try to find a neighborhood matching the player's current location
				local currentNeighborhood = C_Housing.GetCurrentNeighborhoodGUID()
				if currentNeighborhood then
					C_NeighborhoodInitiative.SetActiveNeighborhood(currentNeighborhood)
					C_NeighborhoodInitiative.SetViewingNeighborhood(currentNeighborhood)
					return true
				end

				DebugPrint(L["DBG_NoCurrentNeighborhood"])
			end
		end
	end

	return false
end

