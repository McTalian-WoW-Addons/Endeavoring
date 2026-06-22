--- Tests for Sync/Gossip.lua
---
--- Covers:
--- - MarkCorrectionSent / HasSentCorrection (per-session anti-loop tracking)
--- - BuildDigest (candidate selection, sorting, size capping, tracking filtering)
--- - SendDigest (message building, sending, tracking update)
--- - SendProfile (alias + chars relay, delta filtering)
--- - CorrectStaleAlias / CorrectStaleChars (correction messages)
--- - GetStats (correction statistics)

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

--- Load Gossip into a fresh namespace and return both
local function SetupGossip()
	local ns = nsMocks.CreateNS()

	nsMocks.LoadAddonFile("Endeavoring/Sync/Gossip.lua", ns)
	return ns, ns.Gossip
end

--- Create a mock profile
local function MakeProfile(battleTag, alias, aliasUpdatedAt, characters, charsUpdatedAt)
	return {
		battleTag = battleTag,
		alias = alias or battleTag,
		aliasUpdatedAt = aliasUpdatedAt or 0,
		characters = characters or {},
		charsUpdatedAt = charsUpdatedAt or 0,
	}
end

-- Tests ------------------------------------------------------------------

describe("Gossip", function()
	-- ================================================================
	-- Correction Tracking
	-- ================================================================

	describe("MarkCorrectionSent / HasSentCorrection", function()
		it("should return false before any correction is marked", function()
			local _, Gossip = SetupGossip()

			assert.is_false(Gossip.HasSentCorrection("Target#1111", "Profile#2222"))
		end)

		it("should return true after marking a correction", function()
			local _, Gossip = SetupGossip()

			Gossip.MarkCorrectionSent("Target#1111", "Profile#2222")
			assert.is_true(Gossip.HasSentCorrection("Target#1111", "Profile#2222"))
		end)

		it("should track separately per target and per profile", function()
			local _, Gossip = SetupGossip()

			Gossip.MarkCorrectionSent("Target#1111", "Profile#2222")

			-- Different target, same profile
			assert.is_false(Gossip.HasSentCorrection("Target#3333", "Profile#2222"))
			-- Same target, different profile
			assert.is_false(Gossip.HasSentCorrection("Target#1111", "Profile#4444"))
		end)

		it("should handle multiple corrections for same target", function()
			local _, Gossip = SetupGossip()

			Gossip.MarkCorrectionSent("Target#1111", "Profile#AAA")
			Gossip.MarkCorrectionSent("Target#1111", "Profile#BBB")

			assert.is_true(Gossip.HasSentCorrection("Target#1111", "Profile#AAA"))
			assert.is_true(Gossip.HasSentCorrection("Target#1111", "Profile#BBB"))
		end)
	end)

	-- ================================================================
	-- BuildDigest
	-- ================================================================

	describe("BuildDigest", function()
		it("should return empty when no third-party profiles exist", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {}
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(0, #entries)
		end)

		it("should skip own profile and target's profile", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetMyBattleTag = function()
				return "Me#1234"
			end
			ns.DB.GetAllProfiles = function()
				return {
					["Me#1234"] = MakeProfile("Me#1234", "Me", 100, {}, 100),
					["Target#1111"] = MakeProfile("Target#1111", "Target", 100, {}, 100),
					["Third#5555"] = MakeProfile("Third#5555", "Third", 100, {}, 100),
				}
			end
			ns.DB.GetCharacterCount = function()
				return 0
			end

			local entries = Gossip.BuildDigest("Target#1111")
			-- Should only include Third#5555
			assert.are.equal(1, #entries)
			assert.are.equal("Third#5555", entries[1][ns.SK.battleTag])
		end)

		it("should include profiles not yet tracked for target", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 100),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {}
			end
			ns.DB.GetCharacterCount = function()
				return 2
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(1, #entries)
			assert.are.equal("ProfileA#1", entries[1][ns.SK.battleTag])
			assert.are.equal(100, entries[1][ns.SK.aliasUpdatedAt])
			assert.are.equal(100, entries[1][ns.SK.charsUpdatedAt])
			assert.are.equal(2, entries[1][ns.SK.charsCount])
		end)

		it("should include profiles with fresher alias data", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "NewAlias", 200, {}, 100),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {
					["ProfileA#1"] = { au = 100, cu = 100, cc = 0 },
				}
			end
			ns.DB.GetCharacterCount = function()
				return 0
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(1, #entries)
		end)

		it("should include profiles with fresher character data", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 200),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {
					["ProfileA#1"] = { au = 100, cu = 100, cc = 0 },
				}
			end
			ns.DB.GetCharacterCount = function()
				return 0
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(1, #entries)
		end)

		it("should include profiles with character count mismatch", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 100),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {
					["ProfileA#1"] = { au = 100, cu = 100, cc = 2 },
				}
			end
			-- Different count than tracked
			ns.DB.GetCharacterCount = function()
				return 3
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(1, #entries)
		end)

		it("should exclude profiles that match tracking exactly", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 200),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {
					["ProfileA#1"] = { au = 100, cu = 200, cc = 3 },
				}
			end
			ns.DB.GetCharacterCount = function()
				return 3
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(0, #entries)
		end)

		it("should sort candidates by most recently updated first", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["Old#1"] = MakeProfile("Old#1", "Old", 10, {}, 50),
					["Mid#2"] = MakeProfile("Mid#2", "Mid", 100, {}, 100),
					["New#3"] = MakeProfile("New#3", "New", 300, {}, 200),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {}
			end
			ns.DB.GetCharacterCount = function()
				return 0
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(3, #entries)
			-- Sorted by max(au, cu) descending
			assert.are.equal("New#3", entries[1][ns.SK.battleTag]) -- max(300,200) = 300
			assert.are.equal("Mid#2", entries[2][ns.SK.battleTag]) -- max(100,100) = 100
			assert.are.equal("Old#1", entries[3][ns.SK.battleTag]) -- max(10,50) = 50
		end)

		it("should dynamically trim entries when encoded message exceeds size limit", function()
			local ns, Gossip = SetupGossip()

			-- Create many candidates
			local profiles = {}
			for i = 1, 10 do
				local btag = string.format("Profile%d#%04d", i, i)
				profiles[btag] = MakeProfile(btag, "P" .. i, i * 100, {}, i * 100)
			end

			ns.DB.GetAllProfiles = function()
				return profiles
			end
			ns.DB.GetGossipTracking = function()
				return {}
			end
			ns.DB.GetCharacterCount = function()
				return 1
			end

			-- Simulate encoding that returns too large for 8+ entries
			local callCount = 0
			ns.AddonMessages.BuildMessage = function(_, data)
				callCount = callCount + 1
				local entryCount = data and data[ns.SK.entries] and #data[ns.SK.entries] or 0
				if entryCount > 5 then
					-- Simulate over 255 bytes for large entry counts
					return string.rep("x", 256)
				end
				-- Small enough
				return string.rep("x", 200)
			end

			local entries = Gossip.BuildDigest("Target#1111")
			-- Should have been trimmed to 5 or fewer
			assert.is_true(#entries <= 5)
			assert.is_true(#entries > 0)
		end)

		it("should return empty when even a single entry exceeds size limit", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 100),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {}
			end
			ns.DB.GetCharacterCount = function()
				return 0
			end

			-- Always over limit
			ns.AddonMessages.BuildMessage = function()
				return string.rep("x", 300)
			end

			local entries = Gossip.BuildDigest("Target#1111")
			assert.are.equal(0, #entries)
		end)
	end)

	-- ================================================================
	-- SendDigest
	-- ================================================================

	describe("SendDigest", function()
		it("should not send when digest is empty", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {}
			end

			local sent = false
			ns.AddonMessages.SendMessage = function()
				sent = true
				return true
			end

			Gossip.SendDigest("Target#1111", "TargetChar")
			assert.is_false(sent)
		end)

		it("should send digest and update tracking", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 200),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {}
			end
			ns.DB.GetCharacterCount = function()
				return 2
			end

			local sentChannel, sentTarget
			ns.AddonMessages.SendMessage = function(_, channel, target)
				sentChannel = channel
				sentTarget = target
				return true
			end

			local trackingUpdates = {}
			ns.DB.UpdateGossipTracking = function(target, profile, au, cu, cc)
				table.insert(trackingUpdates, { target = target, profile = profile, au = au, cu = cu, cc = cc })
			end

			Gossip.SendDigest("Target#1111", "TargetChar")

			assert.are.equal("WHISPER", sentChannel)
			assert.are.equal("TargetChar", sentTarget)
			assert.are.equal(1, #trackingUpdates)
			assert.are.equal("Target#1111", trackingUpdates[1].target)
			assert.are.equal("ProfileA#1", trackingUpdates[1].profile)
			assert.are.equal(100, trackingUpdates[1].au)
			assert.are.equal(200, trackingUpdates[1].cu)
			assert.are.equal(2, trackingUpdates[1].cc)
		end)

		it("should not send when BuildMessage fails", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetAllProfiles = function()
				return {
					["ProfileA#1"] = MakeProfile("ProfileA#1", "A", 100, {}, 200),
				}
			end
			ns.DB.GetGossipTracking = function()
				return {}
			end
			ns.DB.GetCharacterCount = function()
				return 0
			end

			-- BuildMessage succeeds during BuildDigest (size check) but fails during SendDigest
			local buildCallCount = 0
			ns.AddonMessages.BuildMessage = function()
				buildCallCount = buildCallCount + 1
				if buildCallCount <= 1 then
					return "valid" -- BuildDigest size check
				end
				return nil -- SendDigest actual build
			end

			local sent = false
			ns.AddonMessages.SendMessage = function()
				sent = true
				return true
			end

			Gossip.SendDigest("Target#1111", "TargetChar")
			assert.is_false(sent)
		end)
	end)

	-- ================================================================
	-- SendProfile
	-- ================================================================

	describe("SendProfile", function()
		it("should send alias and characters for a known profile", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetProfile = function(btag)
				if btag == "ProfileA#1" then
					return {
						battleTag = "ProfileA#1",
						alias = "AliasA",
						aliasUpdatedAt = 100,
						charsUpdatedAt = 200,
						characters = {
							["CharA"] = { name = "CharA", realm = "RealmA", addedAt = 150 },
							["CharB"] = { name = "CharB", realm = "RealmB", addedAt = 200 },
						},
					}
				end
				return nil
			end

			local messagesSent = {}
			ns.AddonMessages.SendMessage = function(msg, channel, target)
				table.insert(messagesSent, { channel = channel, target = target })
				return true
			end

			local charsUpdateCalled = false
			ns.Coordinator.SendCharsUpdate = function()
				charsUpdateCalled = true
				return true
			end

			Gossip.SendProfile("TargetChar", "ProfileA#1", 0)

			-- Should have sent alias message
			assert.are.equal(1, #messagesSent)
			assert.are.equal("WHISPER", messagesSent[1].channel)
			assert.are.equal("TargetChar", messagesSent[1].target)
			-- Should have sent chars update
			assert.is_true(charsUpdateCalled)
		end)

		it("should filter characters by afterTimestamp", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetProfile = function(btag)
				if btag == "ProfileA#1" then
					return {
						battleTag = "ProfileA#1",
						alias = "AliasA",
						aliasUpdatedAt = 100,
						charsUpdatedAt = 200,
						characters = {
							["OldChar"] = { name = "OldChar", realm = "R", addedAt = 100 },
							["NewChar"] = { name = "NewChar", realm = "R", addedAt = 200 },
						},
					}
				end
				return nil
			end

			local sentChars
			ns.Coordinator.SendCharsUpdate = function(btag, chars)
				sentChars = chars
				return true
			end

			-- Only chars added after 150
			Gossip.SendProfile("TargetChar", "ProfileA#1", 150)

			assert.is_not_nil(sentChars)
			assert.are.equal(1, #sentChars)
			assert.are.equal("NewChar", sentChars[1][ns.SK.name])
		end)

		it("should not send chars when none match afterTimestamp", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetProfile = function(btag)
				if btag == "ProfileA#1" then
					return {
						battleTag = "ProfileA#1",
						alias = "AliasA",
						aliasUpdatedAt = 100,
						charsUpdatedAt = 100,
						characters = {
							["OldChar"] = { name = "OldChar", realm = "R", addedAt = 50 },
						},
					}
				end
				return nil
			end

			local charsUpdateCalled = false
			ns.Coordinator.SendCharsUpdate = function()
				charsUpdateCalled = true
				return true
			end

			Gossip.SendProfile("TargetChar", "ProfileA#1", 999)
			assert.is_false(charsUpdateCalled)
		end)

		it("should handle unknown profile gracefully", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetProfile = function()
				return nil
			end

			-- Should not error
			local messagesSent = false
			ns.AddonMessages.SendMessage = function()
				messagesSent = true
				return true
			end

			Gossip.SendProfile("TargetChar", "Ghost#0000", 0)
			assert.is_false(messagesSent)
		end)
	end)

	-- ================================================================
	-- CorrectStaleAlias
	-- ================================================================

	describe("CorrectStaleAlias", function()
		it("should send ALIAS_UPDATE correction via whisper", function()
			local ns, Gossip = SetupGossip()

			local sentChannel, sentTarget
			ns.AddonMessages.SendMessage = function(msg, channel, target)
				sentChannel = channel
				sentTarget = target
				return true
			end

			local builtType
			ns.AddonMessages.BuildMessage = function(msgType)
				builtType = msgType
				return "encoded"
			end

			Gossip.CorrectStaleAlias("SenderChar", "Profile#1", "CorrectAlias", 999)

			assert.are.equal("A", builtType) -- ALIAS_UPDATE
			assert.are.equal("WHISPER", sentChannel)
			assert.are.equal("SenderChar", sentTarget)
		end)
	end)

	-- ================================================================
	-- CorrectStaleChars
	-- ================================================================

	describe("CorrectStaleChars", function()
		it("should send newer characters via Coordinator", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetProfileCharactersAddedAfter = function(btag, after)
				if btag == "Profile#1" and after == 100 then
					return {
						{ name = "NewChar", realm = "R", addedAt = 200 },
					}
				end
				return {}
			end

			local sentBtag, sentChars, sentTimestamp, sentChannel, sentTarget
			ns.Coordinator.SendCharsUpdate = function(btag, chars, ts, channel, target)
				sentBtag = btag
				sentChars = chars
				sentTimestamp = ts
				sentChannel = channel
				sentTarget = target
				return true
			end

			Gossip.CorrectStaleChars("SenderChar", "Profile#1", 200, 100)

			assert.are.equal("Profile#1", sentBtag)
			assert.are.equal(1, #sentChars)
			assert.are.equal(200, sentTimestamp)
			assert.are.equal("WHISPER", sentChannel)
			assert.are.equal("SenderChar", sentTarget)
		end)

		it("should not send when no newer characters exist", function()
			local ns, Gossip = SetupGossip()

			ns.DB.GetProfileCharactersAddedAfter = function()
				return {}
			end

			local charsUpdateCalled = false
			ns.Coordinator.SendCharsUpdate = function()
				charsUpdateCalled = true
				return true
			end

			Gossip.CorrectStaleChars("SenderChar", "Profile#1", 200, 200)
			assert.is_false(charsUpdateCalled)
		end)
	end)

	-- ================================================================
	-- GetStats
	-- ================================================================

	describe("GetStats", function()
		it("should return zero counts when no corrections sent", function()
			local _, Gossip = SetupGossip()

			local stats = Gossip.GetStats()
			assert.are.equal(0, stats.totalCorrections)
			assert.are.same({}, stats.correctionsByPlayer)
		end)

		it("should count corrections accurately", function()
			local _, Gossip = SetupGossip()

			Gossip.MarkCorrectionSent("Target#1", "Profile#A")
			Gossip.MarkCorrectionSent("Target#1", "Profile#B")
			Gossip.MarkCorrectionSent("Target#2", "Profile#C")

			local stats = Gossip.GetStats()
			assert.are.equal(3, stats.totalCorrections)
			assert.are.equal(2, stats.correctionsByPlayer["Target#1"])
			assert.are.equal(1, stats.correctionsByPlayer["Target#2"])
		end)
	end)
end)
