--- Tests for Sync/Coordinator.lua
---
--- Covers: SendCharsUpdate (chunking), SendManifest (guards + message building),
--- OnGuildRosterUpdate (time-based sampling), GetSyncStats.

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

describe("Coordinator", function()
	local ns

	before_each(function()
		ns = nsMocks.CreateNS()

		-- Track calls
		ns._sentMessages = {}
		ns.AddonMessages.BuildMessage = function(msgType, data)
			return "encoded_" .. msgType
		end
		ns.AddonMessages.SendMessage = function(message, channel, target)
			table.insert(ns._sentMessages, {
				message = message,
				channel = channel,
				target = target,
			})
			return true
		end

		ns.DB.GetMyProfile = function()
			return {
				battleTag = "TestPlayer#1234",
				alias = "TestAlias",
				charsUpdatedAt = 1700000000,
				aliasUpdatedAt = 1700000000,
				characters = {
					Thrall = { name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
				},
			}
		end
		ns.DB.GetCharacterCount = function(profile)
			local count = 0
			if profile and profile.characters then
				for _ in pairs(profile.characters) do
					count = count + 1
				end
			end
			return count
		end

		ns.PlayerInfo.IsInGuild = function()
			return true
		end

		-- Load Coordinator with our mocked ns
		nsMocks.LoadAddonFile("Endeavoring/Sync/Coordinator.lua", ns)
	end)

	-- ========================================
	-- SendCharsUpdate (chunking)
	-- ========================================
	describe("SendCharsUpdate", function()
		it("returns true for empty character list", function()
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", {}, 1700000000, "WHISPER", "SomePlayer")
			assert.is_true(result)
			assert.equals(0, #ns._sentMessages)
		end)

		it("sends single message for small character list", function()
			local chars = {
				{ name = "Char1", realm = "Realm1", addedAt = 100 },
				{ name = "Char2", realm = "Realm1", addedAt = 200 },
			}
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "WHISPER", "SomePlayer")
			assert.is_true(result)
			assert.equals(1, #ns._sentMessages)
			assert.equals("WHISPER", ns._sentMessages[1].channel)
			assert.equals("SomePlayer", ns._sentMessages[1].target)
		end)

		it("chunks characters into groups of 4", function()
			local chars = {}
			for i = 1, 10 do
				table.insert(chars, { name = "Char" .. i, realm = "Realm1", addedAt = i * 100 })
			end
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "GUILD")
			assert.is_true(result)
			-- 10 chars / 4 per message = 3 messages (4 + 4 + 2)
			assert.equals(3, #ns._sentMessages)
		end)

		it("sends exactly 1 message for exactly 4 characters", function()
			local chars = {}
			for i = 1, 4 do
				table.insert(chars, { name = "Char" .. i, realm = "Realm1", addedAt = i * 100 })
			end
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "GUILD")
			assert.is_true(result)
			assert.equals(1, #ns._sentMessages)
		end)

		it("sends 2 messages for 5 characters", function()
			local chars = {}
			for i = 1, 5 do
				table.insert(chars, { name = "Char" .. i, realm = "Realm1", addedAt = i * 100 })
			end
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "GUILD")
			assert.is_true(result)
			assert.equals(2, #ns._sentMessages)
		end)

		it("returns false if BuildMessage fails", function()
			ns.AddonMessages.BuildMessage = function()
				return nil
			end
			local chars = {
				{ name = "Char1", realm = "Realm1", addedAt = 100 },
			}
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "GUILD")
			assert.is_false(result)
		end)

		it("returns false if SendMessage fails on first chunk", function()
			ns.AddonMessages.SendMessage = function()
				return false
			end
			local chars = {}
			for i = 1, 5 do
				table.insert(chars, { name = "Char" .. i, realm = "Realm1", addedAt = i * 100 })
			end
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "GUILD")
			assert.is_false(result)
		end)

		it("stops sending on first failed chunk", function()
			local callCount = 0
			ns.AddonMessages.SendMessage = function()
				callCount = callCount + 1
				if callCount == 2 then
					return false
				end
				return true
			end
			local chars = {}
			for i = 1, 12 do
				table.insert(chars, { name = "Char" .. i, realm = "Realm1", addedAt = i * 100 })
			end
			local result = ns.Coordinator.SendCharsUpdate("Player#1234", chars, 1700000000, "GUILD")
			assert.is_false(result)
			-- Should have tried 2 sends (first succeeded, second failed, third never attempted)
			assert.equals(2, callCount)
		end)
	end)

	-- ========================================
	-- SendManifest
	-- ========================================
	describe("SendManifest", function()
		it("sends manifest to guild", function()
			ns.Coordinator.SendManifest()
			assert.equals(1, #ns._sentMessages)
			assert.equals("GUILD", ns._sentMessages[1].channel)
		end)

		it("does not send if no profile exists", function()
			ns.DB.GetMyProfile = function()
				return nil
			end
			ns.Coordinator.SendManifest()
			assert.equals(0, #ns._sentMessages)
		end)

		it("does not send if not in a guild", function()
			ns.PlayerInfo.IsInGuild = function()
				return false
			end
			ns.Coordinator.SendManifest()
			assert.equals(0, #ns._sentMessages)
		end)

		it("does not send if BuildMessage fails", function()
			ns.AddonMessages.BuildMessage = function()
				return nil
			end
			ns.Coordinator.SendManifest()
			assert.equals(0, #ns._sentMessages)
		end)

		it("builds message with correct type", function()
			local capturedType
			ns.AddonMessages.BuildMessage = function(msgType, data)
				capturedType = msgType
				return "encoded"
			end
			ns.Coordinator.SendManifest()
			assert.equals("M", capturedType)
		end)

		it("includes profile data in manifest", function()
			local capturedData
			ns.AddonMessages.BuildMessage = function(msgType, data)
				capturedData = data
				return "encoded"
			end
			ns.Coordinator.SendManifest()
			assert.is_not_nil(capturedData)
			assert.equals("TestPlayer#1234", capturedData[ns.SK.battleTag])
			assert.equals("TestAlias", capturedData[ns.SK.alias])
			assert.equals(1700000000, capturedData[ns.SK.charsUpdatedAt])
			assert.equals(1700000000, capturedData[ns.SK.aliasUpdatedAt])
			assert.equals(1, capturedData[ns.SK.charsCount])
		end)
	end)

	-- ========================================
	-- GetSyncStats
	-- ========================================
	describe("GetSyncStats", function()
		it("returns timing statistics", function()
			local stats = ns.Coordinator.GetSyncStats()
			assert.is_table(stats)
			assert.is_number(stats.timeSinceLastManifest)
			assert.is_number(stats.timeSinceLastRosterManifest)
			assert.is_number(stats.rosterMinInterval)
			assert.is_number(stats.heartbeatInterval)
			assert.is_number(stats.nextHeartbeatIn)
			assert.is_number(stats.nextRosterWindowIn)
		end)

		it("shows shorter time since last manifest after sending one", function()
			local statsBefore = ns.Coordinator.GetSyncStats()
			ns.Coordinator.SendManifest()
			local statsAfter = ns.Coordinator.GetSyncStats()
			assert.is_true(statsAfter.timeSinceLastManifest <= statsBefore.timeSinceLastManifest)
		end)

		it("nextHeartbeatIn is non-negative", function()
			local stats = ns.Coordinator.GetSyncStats()
			assert.is_true(stats.nextHeartbeatIn >= 0)
		end)

		it("nextRosterWindowIn is non-negative", function()
			local stats = ns.Coordinator.GetSyncStats()
			assert.is_true(stats.nextRosterWindowIn >= 0)
		end)
	end)
end)
