--- Tests for Services/QuestRewards.lua
---
--- Covers:
--- - GetCurrencyReward (valid, nil/zero questID, missing API, pcall safety)
--- - GetCouponAmount (delegation, fallback)
--- - GetHouseXP (delegation to NeighborhoodAPI)

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

local function SetupQuestRewards()
	local ns = nsMocks.CreateNS()

	-- Stub C_QuestLog
	_G.C_QuestLog = {
		GetQuestRewardCurrencyInfo = function(questID, index, _)
			if questID == 1001 then
				return { totalRewardAmount = 50, currencyID = 123 }
			elseif questID == 1002 then
				return { totalRewardAmount = 0, currencyID = 456 }
			end
			return nil
		end,
	}

	ns.API.GetQuestRewardHouseXp = function(questID)
		if questID == 1001 then
			return 250
		end
		return nil
	end

	nsMocks.LoadAddonFile("Endeavoring/Services/QuestRewards.lua", ns)
	return ns, ns.QuestRewards
end

-- Tests ------------------------------------------------------------------

describe("QuestRewards", function()
	-- ================================================================
	-- GetCurrencyReward
	-- ================================================================

	describe("GetCurrencyReward", function()
		it("should return currency info for valid quest", function()
			local _, QR = SetupQuestRewards()

			local result = QR.GetCurrencyReward(1001, 1)
			assert.is_not_nil(result)
			assert.are.equal(50, result.totalRewardAmount)
		end)

		it("should default index to 1", function()
			local _, QR = SetupQuestRewards()

			local result = QR.GetCurrencyReward(1001)
			assert.is_not_nil(result)
			assert.are.equal(50, result.totalRewardAmount)
		end)

		it("should return nil for nil questID", function()
			local _, QR = SetupQuestRewards()

			assert.is_nil(QR.GetCurrencyReward(nil))
		end)

		it("should return nil for zero questID", function()
			local _, QR = SetupQuestRewards()

			assert.is_nil(QR.GetCurrencyReward(0))
		end)

		it("should return nil when API is missing", function()
			local _, QR = SetupQuestRewards()

			_G.C_QuestLog = nil

			assert.is_nil(QR.GetCurrencyReward(1001))
		end)

		it("should return nil when API function errors (pcall safety)", function()
			local _, QR = SetupQuestRewards()

			_G.C_QuestLog.GetQuestRewardCurrencyInfo = function()
				error("API not available in this context")
			end

			-- Should not throw, should return nil
			assert.is_nil(QR.GetCurrencyReward(1001))
		end)

		it("should return nil for unknown quest", function()
			local _, QR = SetupQuestRewards()

			assert.is_nil(QR.GetCurrencyReward(9999))
		end)
	end)

	-- ================================================================
	-- GetCouponAmount
	-- ================================================================

	describe("GetCouponAmount", function()
		it("should return totalRewardAmount for valid quest", function()
			local _, QR = SetupQuestRewards()

			assert.are.equal(50, QR.GetCouponAmount(1001))
		end)

		it("should return 0 for quest with no currency reward", function()
			local _, QR = SetupQuestRewards()

			assert.are.equal(0, QR.GetCouponAmount(9999))
		end)

		it("should return 0 when totalRewardAmount is missing", function()
			local _, QR = SetupQuestRewards()

			_G.C_QuestLog.GetQuestRewardCurrencyInfo = function()
				return { currencyID = 123 } -- no totalRewardAmount
			end

			assert.are.equal(0, QR.GetCouponAmount(1001))
		end)
	end)

	-- ================================================================
	-- GetHouseXP
	-- ================================================================

	describe("GetHouseXP", function()
		it("should delegate to NeighborhoodAPI", function()
			local _, QR = SetupQuestRewards()

			assert.are.equal(250, QR.GetHouseXP(1001))
		end)

		it("should return nil for unknown quest", function()
			local _, QR = SetupQuestRewards()

			assert.is_nil(QR.GetHouseXP(9999))
		end)
	end)
end)
