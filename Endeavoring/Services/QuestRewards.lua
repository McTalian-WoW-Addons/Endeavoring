---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local QuestRewards = {}
ns.QuestRewards = QuestRewards

--- Get currency reward information for a quest
--- @param questID number The quest reward ID
--- @param index number|nil The currency index (default: 1)
--- @return table|nil currencyInfo Currency info table or nil if not available
function QuestRewards.GetCurrencyReward(questID, index)
	if not questID or questID == 0 then
		return nil
	end

	if not C_QuestLog or not C_QuestLog.GetQuestRewardCurrencyInfo then
		return nil
	end

	local currencyIndex = index or 1
	local ok, currencyInfo = pcall(C_QuestLog.GetQuestRewardCurrencyInfo, questID, currencyIndex, false)
	if ok and currencyInfo then
		return currencyInfo
	end

	return nil
end

--- Get the coupon amount for a quest reward
--- @param questID number The quest reward ID
--- @return number The coupon amount, or 0 if not available
function QuestRewards.GetCouponAmount(questID)
	local currencyInfo = QuestRewards.GetCurrencyReward(questID, 1)
	if currencyInfo and currencyInfo.totalRewardAmount then
		return currencyInfo.totalRewardAmount
	end
	return 0
end

--- Get House XP reward for a quest (delegates to NeighborhoodAPI)
--- @param questID number The quest reward ID
--- @return number|nil The House XP amount or nil if not available
function QuestRewards.GetHouseXP(questID)
	return ns.API.GetQuestRewardHouseXp(questID)
end

--- Request that quest reward data be loaded into the client cache.
--- Reward APIs (GetQuestRewardCurrencyInfo, GetQuestLogRewardFavor) only return
--- valid data after the quest has been loaded. Call this when those APIs return
--- nil/0, then listen for QUEST_DATA_LOAD_RESULT to re-read the values.
--- @param questID number The quest ID to load
function QuestRewards.RequestLoad(questID)
	if not questID or questID == 0 then return end
	if C_QuestLog and C_QuestLog.RequestLoadQuestByID then
		C_QuestLog.RequestLoadQuestByID(questID)
	end
end
