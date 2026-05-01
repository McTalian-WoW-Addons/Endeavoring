--- Tests for Sync/Position.lua — privacy opt-out behavior
---
--- Covers:
--- - JoinNeighborhood returns early and does NOT call C_ChatInfo when opted out
--- - DebugPrint log message is emitted when opt-out skips JoinNeighborhood
--- - JoinNeighborhood proceeds normally when opt-out is false (default)
--- - GetActiveChannel remains nil after opt-out skip (no state mutation)
--- - LeaveNeighborhood is NOT gated by opt-out (cleanup always runs)
--- - When Settings stub is absent, JoinNeighborhood works normally
--- - When JoinChannelByName returns nil, join fails and state is not updated

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Build a namespace and load Position.lua into it.
--- Accepts an optional joinChannelByNameResult to control the stub's return value.
--- Returns (ns, Position, joinCallCount-getter, leaveCallCount-getter, debugLines).
local function Setup(settingsOptOut, joinChannelByNameResult)
	local ns = nsMocks.CreateNS()

	-- Track DebugPrint calls so we can assert on log output
	local debugLines = {}
	ns.DebugPrint = function(msg)
		table.insert(debugLines, msg)
	end

	-- Optionally install a Settings stub
	if settingsOptOut ~= nil then
		ns.Settings = {
			GetPositionOptOut = function() return settingsOptOut end,
		}
	end
	-- If settingsOptOut is nil we leave ns.Settings = nil to test absent-stub path

	-- Create a stub DEFAULT_CHAT_FRAME for the test
	_G.DEFAULT_CHAT_FRAME = {
		GetID = function() return 1 end
	}

	-- Track JoinChannelByName global function calls
	local joinCallCount = 0
	local lastJoinArgs = {}
	_G.JoinChannelByName = function(channelName, password, frameID, hasVoice)
		joinCallCount = joinCallCount + 1
		lastJoinArgs = {channelName = channelName, password = password, frameID = frameID, hasVoice = hasVoice}
		-- Allow test to control return value; default is success
		if joinChannelByNameResult == "fail" then
			return nil  -- simulate failure
		end
		return 3, channelName  -- simulate success (non-zero channel type, return the channel name)
	end

	-- Track LeaveChannelByName global function calls
	local leaveCallCount = 0
	_G.LeaveChannelByName = function(channelName)
		leaveCallCount = leaveCallCount + 1
	end

	-- Stub GetChannelList to simulate joined channels (needed for GetActiveChannelNumber)
	-- Returns (id1, name1, disabled1, id2, name2, disabled2, ...)
	-- The channel name must match what ChannelName(GUID) produces
	_G.GetChannelList = function()
		return 5, "NdvrngGUID001", false  -- Channel 5 for GUID "GUID-001" (dashes stripped)
	end

	nsMocks.LoadAddonFile("Endeavoring/Sync/Position.lua", ns)

	return ns, ns.Position, function() return joinCallCount end, function() return leaveCallCount end, debugLines, lastJoinArgs
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("Position.JoinNeighborhood", function()

	-- =========================================================================
	-- Opt-out = true
	-- =========================================================================
	describe("when privacy opt-out is enabled", function()

		it("returns early without calling JoinChannelByName", function()
			local _, Position, getJoinCount = Setup(true)
			Position.JoinNeighborhood("GUID-001")
			assert.are.equal(0, getJoinCount())
		end)

		it("emits a DebugPrint log message naming the skipped GUID", function()
			local _, Position, _, _, debugLines = Setup(true)
			Position.JoinNeighborhood("GUID-999")
			-- At least one debug line should mention the GUID
			-- Use plain=true for string.find because "-" is a Lua pattern metacharacter
			local found = false
			for _, line in ipairs(debugLines) do
				if line:find("GUID-999", 1, true) then found = true end
			end
			assert.is_true(found, "Expected a DebugPrint line containing 'GUID-999'")
		end)

		it("does not update GetActiveChannel state", function()
			local _, Position = Setup(true)
			Position.JoinNeighborhood("GUID-001")
			local guid, name = Position.GetActiveChannel()
			assert.is_nil(guid)
			assert.is_nil(name)
		end)

	end)

	-- =========================================================================
	-- Opt-out = false (default)
	-- =========================================================================
	describe("when privacy opt-out is disabled", function()

		it("calls JoinChannelByName exactly once", function()
			local _, Position, getJoinCount = Setup(false)
			Position.JoinNeighborhood("GUID-001")
			assert.are.equal(1, getJoinCount())
		end)

		it("updates GetActiveChannel state after a successful join", function()
			local _, Position = Setup(false)
			Position.JoinNeighborhood("GUID-001")
			local guid = Position.GetActiveChannel()
			assert.are.equal("GUID-001", guid)
		end)

		it("does not update state when JoinChannelByName returns nil", function()
			local _, Position, getJoinCount = Setup(false, "fail")
			Position.JoinNeighborhood("GUID-001")
			-- Verify JoinChannelByName was called despite the failure
			assert.are.equal(1, getJoinCount())
			-- Verify state was NOT updated (GetActiveChannel should be nil)
			local guid, name = Position.GetActiveChannel()
			assert.is_nil(guid)
			assert.is_nil(name)
		end)

	end)

	-- =========================================================================
	-- Settings stub absent (nil)
	-- =========================================================================
	describe("when ns.Settings is nil (load-order safety)", function()

		it("calls JoinChannelByName normally (no crash)", function()
			local _, Position, getJoinCount = Setup(nil)  -- no Settings stub
			assert.has_no_errors(function()
				Position.JoinNeighborhood("GUID-002")
			end)
			assert.are.equal(1, getJoinCount())
		end)

	end)

end)

describe("Position.GetActiveChannelNumber", function()

	it("returns nil when no neighborhood is joined", function()
		local _, Position = Setup(false)
		local channelNum = Position.GetActiveChannelNumber()
		assert.is_nil(channelNum)
	end)

	it("returns the cached channel number after a successful join", function()
		local _, Position = Setup(false)
		Position.JoinNeighborhood("GUID-001")
		local channelNum = Position.GetActiveChannelNumber()
		-- GetChannelList stub returns 5 as the channel ID
		assert.are.equal(5, channelNum)
	end)

	it("clears the channel number when leaving the neighborhood", function()
		local _, Position = Setup(false)
		Position.JoinNeighborhood("GUID-001")
		assert.are.equal(5, Position.GetActiveChannelNumber())
		
		Position.LeaveNeighborhood("GUID-001")
		local channelNum = Position.GetActiveChannelNumber()
		assert.is_nil(channelNum)
	end)

end)
