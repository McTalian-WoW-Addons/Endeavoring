--- Tests for Features/Leaderboard.lua
---
--- Covers: BuildFromActivityLog (aggregation, time filtering, sorting),
--- BuildEnriched (BattleTag merging, alias display, rank assignment),
--- GetTimeRangeName, SetTimeRange/GetTimeRange.

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

describe("Leaderboard", function()
	local ns

	before_each(function()
		ns = nsMocks.CreateNS()

		ns.PlayerInfo.GetBattleTag = function()
			return "Me#1234"
		end
		ns.PlayerInfo.IsLocalPlayer = function(name)
			return name == "MyChar"
		end

		ns.CharacterCache.FindBattleTag = function(name)
			local map = {
				MyChar = "Me#1234",
				FriendChar = "Friend#5678",
				FriendAlt = "Friend#5678",
			}
			return map[name]
		end

		ns.DB.GetProfile = function(battleTag)
			local profiles = {
				["Me#1234"] = { alias = "McTalian", battleTag = "Me#1234" },
				["Friend#5678"] = { alias = "Buddy", battleTag = "Friend#5678" },
			}
			return profiles[battleTag]
		end

		ns.DB.GetMyProfile = function()
			return {
				battleTag = "Me#1234",
				alias = "McTalian",
				characters = { MyChar = true },
			}
		end

		nsMocks.LoadAddonFile("Endeavoring/Features/Leaderboard.lua", ns)
	end)

	-- ========================================
	-- BuildFromActivityLog
	-- ========================================
	describe("BuildFromActivityLog", function()
		it("returns empty table for nil input", function()
			assert.same({}, ns.Leaderboard.BuildFromActivityLog(nil))
		end)

		it("returns empty table for missing taskActivity", function()
			assert.same({}, ns.Leaderboard.BuildFromActivityLog({ isLoaded = true }))
		end)

		it("returns empty table for empty taskActivity", function()
			assert.same({}, ns.Leaderboard.BuildFromActivityLog({ taskActivity = {} }))
		end)

		it("aggregates contributions by player name", function()
			local log = {
				taskActivity = {
					{ playerName = "Alice", amount = 10, completionTime = 100 },
					{ playerName = "Alice", amount = 20, completionTime = 200 },
					{ playerName = "Bob", amount = 15, completionTime = 150 },
				},
			}
			local result = ns.Leaderboard.BuildFromActivityLog(log)
			assert.equals(2, #result)
			-- Alice (30 total) should be ranked above Bob (15 total)
			assert.equals("Alice", result[1].player)
			assert.equals(30, result[1].total)
			assert.equals(2, result[1].entries)
			assert.equals("Bob", result[2].player)
			assert.equals(15, result[2].total)
			assert.equals(1, result[2].entries)
		end)

		it("sorts by total contribution descending", function()
			local log = {
				taskActivity = {
					{ playerName = "Low", amount = 5, completionTime = 100 },
					{ playerName = "High", amount = 50, completionTime = 100 },
					{ playerName = "Mid", amount = 25, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildFromActivityLog(log)
			assert.equals("High", result[1].player)
			assert.equals("Mid", result[2].player)
			assert.equals("Low", result[3].player)
		end)

		it("breaks ties by entry count (more entries ranks higher)", function()
			local log = {
				taskActivity = {
					{ playerName = "ManyTasks", amount = 10, completionTime = 100 },
					{ playerName = "ManyTasks", amount = 10, completionTime = 200 },
					{ playerName = "FewTasks", amount = 20, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildFromActivityLog(log)
			-- Both have total=20, but ManyTasks has 2 entries vs FewTasks's 1
			assert.equals("ManyTasks", result[1].player)
			assert.equals("FewTasks", result[2].player)
		end)

		it("breaks ties by alphabetical name when total and entries match", function()
			local log = {
				taskActivity = {
					{ playerName = "Zara", amount = 10, completionTime = 100 },
					{ playerName = "Alice", amount = 10, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildFromActivityLog(log)
			assert.equals("Alice", result[1].player)
			assert.equals("Zara", result[2].player)
		end)

		it("filters by time range", function()
			local now = time()
			local log = {
				taskActivity = {
					{ playerName = "Recent", amount = 10, completionTime = now - 100 },
					{ playerName = "Old", amount = 50, completionTime = now - 200000 },
				},
			}
			-- Filter to last 24 hours (86400 seconds)
			local result = ns.Leaderboard.BuildFromActivityLog(log, 86400)
			assert.equals(1, #result)
			assert.equals("Recent", result[1].player)
		end)

		it("includes all entries when timeRange is nil", function()
			local now = time()
			local log = {
				taskActivity = {
					{ playerName = "Recent", amount = 10, completionTime = now - 100 },
					{ playerName = "Old", amount = 50, completionTime = now - 999999 },
				},
			}
			local result = ns.Leaderboard.BuildFromActivityLog(log, nil)
			assert.equals(2, #result)
		end)

		it("includes all entries when timeRange is 0 (current endeavor)", function()
			local log = {
				taskActivity = {
					{ playerName = "One", amount = 10, completionTime = 100 },
					{ playerName = "Two", amount = 20, completionTime = 1 },
				},
			}
			local result = ns.Leaderboard.BuildFromActivityLog(log, 0)
			assert.equals(2, #result)
		end)
	end)

	-- ========================================
	-- BuildEnriched
	-- ========================================
	describe("BuildEnriched", function()
		it("returns empty table for nil input", function()
			assert.same({}, ns.Leaderboard.BuildEnriched(nil))
		end)

		it("merges characters under same BattleTag", function()
			local log = {
				taskActivity = {
					{ playerName = "FriendChar", amount = 10, completionTime = 100 },
					{ playerName = "FriendAlt", amount = 20, completionTime = 200 },
				},
			}
			local result = ns.Leaderboard.BuildEnriched(log)
			-- Both map to Friend#5678, so should be merged
			assert.equals(1, #result)
			assert.equals("Buddy", result[1].displayName)
			assert.equals(30, result[1].total)
			assert.equals(2, result[1].entries)
			assert.equals(2, #result[1].charNames)
			assert.is_true(result[1].hasSyncedProfile)
		end)

		it("marks local player entries", function()
			local log = {
				taskActivity = {
					{ playerName = "MyChar", amount = 10, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildEnriched(log)
			assert.equals(1, #result)
			assert.is_true(result[1].isLocalPlayer)
		end)

		it("uses player name as display for unsynced profiles", function()
			local log = {
				taskActivity = {
					{ playerName = "Stranger", amount = 10, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildEnriched(log)
			assert.equals(1, #result)
			assert.equals("Stranger", result[1].displayName)
			assert.is_false(result[1].hasSyncedProfile)
		end)

		it("assigns sequential ranks", function()
			local log = {
				taskActivity = {
					{ playerName = "MyChar", amount = 50, completionTime = 100 },
					{ playerName = "Stranger", amount = 30, completionTime = 100 },
					{ playerName = "FriendChar", amount = 10, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildEnriched(log)
			-- MyChar (50) > Stranger (30) > FriendChar (10)
			for i, entry in ipairs(result) do
				assert.equals(i, entry.rank)
			end
		end)

		it("handles mix of synced and unsynced players", function()
			local log = {
				taskActivity = {
					{ playerName = "MyChar", amount = 50, completionTime = 100 },
					{ playerName = "Stranger", amount = 30, completionTime = 100 },
					{ playerName = "FriendChar", amount = 10, completionTime = 100 },
				},
			}
			local result = ns.Leaderboard.BuildEnriched(log)
			assert.equals(3, #result)

			-- Find synced vs unsynced
			local syncedCount = 0
			local unsyncedCount = 0
			for _, entry in ipairs(result) do
				if entry.hasSyncedProfile then
					syncedCount = syncedCount + 1
				else
					unsyncedCount = unsyncedCount + 1
				end
			end
			assert.equals(2, syncedCount) -- MyChar + FriendChar
			assert.equals(1, unsyncedCount) -- Stranger
		end)
	end)

	-- ========================================
	-- GetTimeRangeName
	-- ========================================
	describe("GetTimeRangeName", function()
		it("returns '24 Hours' for TODAY range", function()
			assert.equals("24 Hours", ns.Leaderboard.GetTimeRangeName(86400))
		end)

		it("returns '7 Days' for THIS_WEEK range", function()
			assert.equals("7 Days", ns.Leaderboard.GetTimeRangeName(604800))
		end)

		it("returns 'Current Endeavor' for 0 (all time)", function()
			assert.equals("Current Endeavor", ns.Leaderboard.GetTimeRangeName(0))
		end)

		it("returns 'Current Endeavor' for nil", function()
			assert.equals("Current Endeavor", ns.Leaderboard.GetTimeRangeName(nil))
		end)
	end)

	-- ========================================
	-- SetTimeRange / GetTimeRange
	-- ========================================
	describe("SetTimeRange / GetTimeRange", function()
		it("defaults to current endeavor (0)", function()
			assert.equals(0, ns.Leaderboard.GetTimeRange())
		end)

		it("sets and returns time range", function()
			ns.Leaderboard.SetTimeRange(86400)
			assert.equals(86400, ns.Leaderboard.GetTimeRange())
		end)
	end)

	-- ========================================
	-- TIME_RANGE constants
	-- ========================================
	describe("TIME_RANGE", function()
		it("exports TIME_RANGE constants", function()
			assert.is_table(ns.Leaderboard.TIME_RANGE)
			assert.equals(0, ns.Leaderboard.TIME_RANGE.CURRENT_ENDEAVOR)
			assert.equals(86400, ns.Leaderboard.TIME_RANGE.TODAY)
			assert.equals(604800, ns.Leaderboard.TIME_RANGE.THIS_WEEK)
		end)
	end)
end)
