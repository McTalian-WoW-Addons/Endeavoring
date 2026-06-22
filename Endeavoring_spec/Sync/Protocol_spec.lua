--- Tests for Sync/Protocol.lua
---
--- Covers:
--- - NormalizeKeys forward compatibility (short keys → verbose keys)
--- - Verbose keys pass through unchanged
--- - Mixed/unknown keys are preserved
--- - Integration with OnAddonMessage for each message type

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

--- Load Protocol.lua into a fresh namespace and return both
local function SetupProtocol()
	local ns = nsMocks.CreateNS()

	-- Make sender different from "our" BattleTag so messages aren't ignored
	ns.DB.GetMyBattleTag = function()
		return "TestPlayer#1234"
	end

	nsMocks.LoadAddonFile("Endeavoring/Sync/Protocol.lua", ns)
	return ns, ns.Protocol
end

--- Simulate receiving an addon message.
--- Stubs MessageCodec.Decode to return the given decoded payload, then
--- calls Protocol.OnAddonMessage with the correct prefix.
--- @param ns table The addon namespace
--- @param decodedPayload table What Decode should return
--- @param sender string|nil Sender name (default "OtherPlayer")
local function SimulateMessage(ns, decodedPayload, sender)
	sender = sender or "OtherPlayer"
	-- Stub Decode to return our crafted payload
	ns.MessageCodec.Decode = function()
		return decodedPayload, nil
	end
	ns.Protocol.OnAddonMessage("Ndvrng", "fake_encoded_data", "GUILD", sender)
end

-- Tests ------------------------------------------------------------------

describe("Protocol", function()
	describe("NormalizeKeys", function()
		describe("MANIFEST with verbose keys", function()
			it("should process a manifest with standard verbose keys", function()
				local ns, Protocol = SetupProtocol()

				-- Manifest from a different player
				local senderBTag = "Neighbor#5678"
				local payload = {
					type = "M",
					battleTag = senderBTag,
					alias = "NeighborAlias",
					charsUpdatedAt = 1700000000,
					aliasUpdatedAt = 1700000000,
				}

				-- The sender is new, so we expect:
				-- 1. UpdateProfileAlias to be called
				-- 2. A REQUEST_CHARS message to be built and sent
				local aliasUpdated = false
				ns.DB.UpdateProfileAlias = function(bt, alias, ts)
					aliasUpdated = true
					assert.are.equal(senderBTag, bt)
					assert.are.equal("NeighborAlias", alias)
					assert.are.equal(1700000000, ts)
					return true
				end

				local requestSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "R" then
						assert.are.equal(senderBTag, data.b)
						requestSent = true
						return "encoded_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_true(aliasUpdated, "UpdateProfileAlias should have been called")
				assert.is_true(requestSent, "REQUEST_CHARS should have been sent")
			end)
		end)

		describe("MANIFEST with short keys", function()
			it("should normalize short keys and process a manifest correctly", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				-- Same manifest but with future short keys
				local payload = {
					t = "M",
					b = senderBTag,
					a = "NeighborAlias",
					cu = 1700000000,
					au = 1700000000,
				}

				local aliasUpdated = false
				ns.DB.UpdateProfileAlias = function(bt, alias, ts)
					aliasUpdated = true
					assert.are.equal(senderBTag, bt)
					assert.are.equal("NeighborAlias", alias)
					assert.are.equal(1700000000, ts)
					return true
				end

				local requestSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "R" then
						assert.are.equal(senderBTag, data.b)
						requestSent = true
						return "encoded_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_true(aliasUpdated, "UpdateProfileAlias should have been called with short keys")
				assert.is_true(requestSent, "REQUEST_CHARS should have been sent with short keys")
			end)
		end)

		describe("CHARS_UPDATE with verbose keys", function()
			it("should add characters from verbose-key payload", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				local payload = {
					type = "C",
					battleTag = senderBTag,
					charsUpdatedAt = 1700000000,
					characters = {
						{ name = "Char1", realm = "Stormrage", addedAt = 1700000000 },
						{ name = "Char2", realm = "Proudmoore", addedAt = 1700000001 },
					},
				}

				local addedChars = nil
				ns.DB.AddCharactersToProfile = function(bt, chars)
					assert.are.equal(senderBTag, bt)
					addedChars = chars
					return true
				end

				local cacheInvalidated = false
				ns.CharacterCache.Invalidate = function(bt)
					assert.are.equal(senderBTag, bt)
					cacheInvalidated = true
				end

				SimulateMessage(ns, payload)

				assert.is_not_nil(addedChars, "AddCharactersToProfile should have been called")
				assert.are.equal(2, #addedChars)
				assert.are.equal("Char1", addedChars[1].name)
				assert.are.equal("Stormrage", addedChars[1].realm)
				assert.are.equal(1700000000, addedChars[1].addedAt)
				assert.are.equal("Char2", addedChars[2].name)
				assert.is_true(cacheInvalidated)
			end)
		end)

		describe("CHARS_UPDATE with short keys", function()
			it("should normalize short keys in both envelope and nested character objects", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				-- Short keys at every level
				local payload = {
					t = "C",
					b = senderBTag,
					cu = 1700000000,
					c = {
						{ n = "Char1", r = "Stormrage", d = 1700000000 },
						{ n = "Char2", r = "Proudmoore", d = 1700000001 },
					},
				}

				local addedChars = nil
				ns.DB.AddCharactersToProfile = function(bt, chars)
					assert.are.equal(senderBTag, bt)
					addedChars = chars
					return true
				end

				local cacheInvalidated = false
				ns.CharacterCache.Invalidate = function(bt)
					cacheInvalidated = true
				end

				SimulateMessage(ns, payload)

				assert.is_not_nil(addedChars, "AddCharactersToProfile should have been called with short keys")
				assert.are.equal(2, #addedChars)
				assert.are.equal("Char1", addedChars[1].name)
				assert.are.equal("Stormrage", addedChars[1].realm)
				assert.are.equal(1700000000, addedChars[1].addedAt)
				assert.are.equal("Char2", addedChars[2].name)
				assert.are.equal("Proudmoore", addedChars[2].realm)
				assert.is_true(cacheInvalidated)
			end)
		end)

		describe("ALIAS_UPDATE with verbose keys", function()
			it("should update alias from verbose-key payload", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				local payload = {
					type = "A",
					battleTag = senderBTag,
					alias = "NewAlias",
					aliasUpdatedAt = 1700000100,
				}

				local aliasUpdated = false
				ns.DB.UpdateProfileAlias = function(bt, alias, ts)
					aliasUpdated = true
					assert.are.equal(senderBTag, bt)
					assert.are.equal("NewAlias", alias)
					assert.are.equal(1700000100, ts)
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_true(aliasUpdated, "UpdateProfileAlias should have been called")
			end)
		end)

		describe("ALIAS_UPDATE with short keys", function()
			it("should normalize short keys and update alias", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				local payload = {
					t = "A",
					b = senderBTag,
					a = "NewAlias",
					au = 1700000100,
				}

				local aliasUpdated = false
				ns.DB.UpdateProfileAlias = function(bt, alias, ts)
					aliasUpdated = true
					assert.are.equal(senderBTag, bt)
					assert.are.equal("NewAlias", alias)
					assert.are.equal(1700000100, ts)
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_true(aliasUpdated, "UpdateProfileAlias should have been called with short keys")
			end)
		end)

		describe("REQUEST_CHARS with verbose keys", function()
			it("should respond with CHARS_UPDATE when requested about us", function()
				local ns, Protocol = SetupProtocol()

				local myBTag = "TestPlayer#1234"
				local payload = {
					type = "R",
					battleTag = myBTag,
					afterTimestamp = 0,
				}

				-- Set up our profile to have characters to send
				ns.DB.GetCharactersAddedAfter = function(afterTs)
					assert.are.equal(0, afterTs)
					return {
						{ name = "MyChar", realm = "Stormrage", addedAt = 1700000000 },
					}
				end

				local charsUpdateSent = false
				ns.Coordinator.SendCharsUpdate = function(bt, chars, ts, channel, target)
					charsUpdateSent = true
					assert.are.equal(myBTag, bt)
					assert.are.equal(1, #chars)
					assert.are.equal("MyChar", chars[1].n)
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_true(charsUpdateSent, "SendCharsUpdate should have been called")
			end)
		end)

		describe("REQUEST_CHARS with short keys", function()
			it("should normalize short keys and respond correctly", function()
				local ns, Protocol = SetupProtocol()

				local myBTag = "TestPlayer#1234"
				local payload = {
					t = "R",
					b = myBTag,
					af = 0,
				}

				ns.DB.GetCharactersAddedAfter = function(afterTs)
					assert.are.equal(0, afterTs)
					return {
						{ name = "MyChar", realm = "Stormrage", addedAt = 1700000000 },
					}
				end

				local charsUpdateSent = false
				ns.Coordinator.SendCharsUpdate = function(bt, chars, ts, channel, target)
					charsUpdateSent = true
					assert.are.equal(myBTag, bt)
					assert.are.equal(1, #chars)
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_true(charsUpdateSent, "SendCharsUpdate should have been called with short keys")
			end)
		end)

		describe("GOSSIP_DIGEST", function()
			it("should request full data for unknown profiles", function()
				local ns, Protocol = SetupProtocol()

				-- Sender is identifiable via CharacterCache
				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				-- Profile from digest is unknown to us
				local profileBTag = "Unknown#1111"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return nil
					end
					return nil
				end

				local requestSent = false
				local requestedBTag, requestedAf
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						requestSent = true
						requestedBTag = data.b
						requestedAf = data.af
						return "encoded_gossip_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(requestSent, "GOSSIP_REQUEST should be sent for unknown profile")
				assert.are.equal(profileBTag, requestedBTag)
				assert.are.equal(0, requestedAf, "afterTimestamp should be 0 for full request")
			end)

			it("should request delta chars when digest cu > local cu", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "ProfileAlias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000100,
							characters = { { name = "Char1", realm = "Realm", addedAt = 1700000100 } },
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function(profile)
					if profile and profile.characters then
						return #profile.characters
					end
					return 0
				end

				local requestSent = false
				local requestedAf
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						requestSent = true
						requestedAf = data.af
						return "encoded_gossip_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(requestSent, "GOSSIP_REQUEST should be sent for newer chars")
				assert.are.equal(1700000100, requestedAf, "afterTimestamp should be our local cu for delta")
			end)

			it("should request full data when digest au > local au", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "OldAlias",
							aliasUpdatedAt = 1700000050,
							charsUpdatedAt = 1700000200,
							characters = {},
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 0
				end

				local requestSent = false
				local requestedAf
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						requestSent = true
						requestedAf = data.af
						return "encoded_gossip_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 0 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(requestSent, "GOSSIP_REQUEST should be sent for newer alias")
				assert.are.equal(0, requestedAf, "afterTimestamp should be 0 for full request")
			end)

			it("should request full data when same cu but digest cc > local cc", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "Alias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000200,
							characters = { { name = "C1", realm = "R", addedAt = 1700000200 } },
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 1
				end

				local requestSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						requestSent = true
						return "encoded_gossip_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				-- Same cu (1700000200) but digest has 3 chars vs our 1
				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(requestSent, "GOSSIP_REQUEST should be sent when they have more chars")
			end)

			it("should send alias correction when local au > digest au", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "FreshAlias",
							aliasUpdatedAt = 1700000300,
							charsUpdatedAt = 1700000200,
							characters = { { name = "C1", realm = "R", addedAt = 1700000200 } },
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 1
				end

				local aliasCorrected = false
				ns.Gossip.CorrectStaleAlias = function(sender, bt, alias, ts)
					aliasCorrected = true
					assert.are.equal("OtherPlayer", sender)
					assert.are.equal(profileBTag, bt)
					assert.are.equal("FreshAlias", alias)
					assert.are.equal(1700000300, ts)
				end

				local correctionMarked = false
				ns.Gossip.MarkCorrectionSent = function(targetBt, profileBt)
					correctionMarked = true
					assert.are.equal(senderBTag, targetBt)
					assert.are.equal(profileBTag, profileBt)
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 1 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(aliasCorrected, "Alias correction should be sent")
				assert.is_true(correctionMarked, "Correction should be marked to prevent ping-pong")
			end)

			it("should send chars correction when local cu > digest cu", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "Alias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000300,
							characters = {},
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 2
				end

				local charsCorrected = false
				ns.Gossip.CorrectStaleChars = function(sender, bt, correctTs, senderTs)
					charsCorrected = true
					assert.are.equal("OtherPlayer", sender)
					assert.are.equal(profileBTag, bt)
					assert.are.equal(1700000300, correctTs)
					assert.are.equal(1700000100, senderTs)
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000100, cc = 2 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(charsCorrected, "Chars correction should be sent")
			end)

			it("should send full chars correction when same cu but local cc > digest cc", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "Alias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000200,
							characters = {},
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 5
				end

				local charsCorrected = false
				ns.Gossip.CorrectStaleChars = function(sender, bt, correctTs, senderTs)
					charsCorrected = true
					assert.are.equal(profileBTag, bt)
					assert.are.equal(1700000200, correctTs)
					assert.are.equal(0, senderTs, "senderTs should be 0 to send all chars")
				end

				-- Same cu but we have 5 chars vs their 2
				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 2 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(charsCorrected, "Full chars correction should be sent when we have more chars")
			end)

			it("should take no action when timestamps and count match", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "Alias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000200,
							characters = {},
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 3
				end

				local messageSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						messageSent = true
					end
					return "encoded_message"
				end
				ns.Gossip.CorrectStaleAlias = function()
					messageSent = true
				end
				ns.Gossip.CorrectStaleChars = function()
					messageSent = true
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_false(messageSent, "No request or correction should be sent when data matches")
			end)

			it("should skip entries about our own BattleTag", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local myBTag = "TestPlayer#1234"

				local messageSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						messageSent = true
					end
					return "encoded_message"
				end

				local payload = {
					t = "G",
					b = "Sender#9999",
					e = {
						{ b = myBTag, au = 1700000100, cu = 1700000200, cc = 5 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_false(messageSent, "Should not request or correct data about ourselves")
			end)

			it("should still process digest when BattleTag is in payload but CharacterCache returns nil", function()
				local ns, Protocol = SetupProtocol()

				-- FindBattleTag returns nil — but payload includes sender BTag
				ns.CharacterCache.FindBattleTag = function()
					return nil
				end

				-- Profile from digest is unknown to us
				local profileBTag = "Unknown#1111"
				ns.DB.GetProfile = function()
					return nil
				end

				local requestSent = false
				local requestedBTag
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						requestSent = true
						requestedBTag = data.b
						return "encoded_gossip_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				local payload = {
					t = "G",
					b = "Sender#9999",
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(requestSent, "GOSSIP_REQUEST should be sent even when CharacterCache returns nil")
				assert.are.equal(profileBTag, requestedBTag)
			end)

			it("should ignore digest when BattleTag is not in payload and CharacterCache returns nil", function()
				local ns, Protocol = SetupProtocol()

				-- FindBattleTag returns nil and payload has no sender BTag
				ns.CharacterCache.FindBattleTag = function()
					return nil
				end

				local messageSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						messageSent = true
					end
					return "encoded_message"
				end

				local payload = {
					t = "G",
					e = {
						{ b = "Unknown#1111", au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_false(messageSent, "Should not process digest from unidentifiable sender")
			end)

			it("should ignore digest with empty entries", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function()
					return senderBTag
				end

				local messageSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						messageSent = true
					end
					return "encoded_message"
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {},
				}

				SimulateMessage(ns, payload)

				assert.is_false(messageSent, "Should not process empty digest")
			end)

			it("should update gossip tracking with sender's knowledge state", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				-- Both sides have same data — no action needed, but tracking should update
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "Alias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000200,
							characters = {},
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 3
				end

				local trackingUpdated = false
				local trackedTarget, trackedProfile, trackedAu, trackedCu, trackedCc
				ns.DB.UpdateGossipTracking = function(target, profile, au, cu, cc)
					trackingUpdated = true
					trackedTarget = target
					trackedProfile = profile
					trackedAu = au
					trackedCu = cu
					trackedCc = cc
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 3 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_true(trackingUpdated, "Gossip tracking should be updated with sender's state")
				assert.are.equal(senderBTag, trackedTarget)
				assert.are.equal(profileBTag, trackedProfile)
				assert.are.equal(1700000100, trackedAu)
				assert.are.equal(1700000200, trackedCu)
				assert.are.equal(3, trackedCc)
			end)

			it("should not send correction if already sent this session", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profileBTag = "Profile#2222"
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "FreshAlias",
							aliasUpdatedAt = 1700000300,
							charsUpdatedAt = 1700000200,
							characters = {},
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 1
				end

				-- Simulate that correction was already sent this session
				ns.Gossip.HasSentCorrection = function(targetBt, profileBt)
					return targetBt == senderBTag and profileBt == profileBTag
				end

				local aliasCorrected = false
				ns.Gossip.CorrectStaleAlias = function()
					aliasCorrected = true
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profileBTag, au = 1700000100, cu = 1700000200, cc = 1 },
					},
				}

				SimulateMessage(ns, payload)

				assert.is_false(aliasCorrected, "Should not re-correct when already corrected this session")
			end)

			it("should handle multiple entries in a single digest", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Sender#9999"
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				local profile1 = "Known#1111"
				local profile2 = "Unknown#2222"

				ns.DB.GetProfile = function(bt)
					if bt == profile1 then
						return {
							alias = "Alias1",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000200,
							characters = {},
						}
					end
					return nil -- profile2 is unknown
				end
				ns.DB.GetCharacterCount = function()
					return 3
				end

				local requestedBTags = {}
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "GR" then
						table.insert(requestedBTags, data.b)
						return "encoded_gossip_request"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end

				local payload = {
					t = "G",
					b = senderBTag,
					e = {
						{ b = profile1, au = 1700000100, cu = 1700000200, cc = 3 }, -- match, no action
						{ b = profile2, au = 1700000050, cu = 1700000050, cc = 1 }, -- unknown, request
					},
				}

				SimulateMessage(ns, payload)

				-- Only profile2 should have been requested (profile1 timestamps match)
				assert.are.equal(1, #requestedBTags)
				assert.are.equal(profile2, requestedBTags[1])
			end)
		end)

		describe("GOSSIP_REQUEST", function()
			it("should send cached third-party profile via Gossip.SendProfile", function()
				local ns, Protocol = SetupProtocol()

				local profileBTag = "Profile#2222"
				local profileSent = false
				local sentTo, sentBTag, sentAfter
				ns.Gossip.SendProfile = function(target, bt, af)
					profileSent = true
					sentTo = target
					sentBTag = bt
					sentAfter = af
				end

				-- Required for the post-send tracking update
				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return "Sender#9999"
					end
					return nil
				end
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return { aliasUpdatedAt = 1700000100, charsUpdatedAt = 1700000200, characters = {} }
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 0
				end

				local payload = {
					t = "GR",
					b = profileBTag,
					af = 0,
				}

				SimulateMessage(ns, payload)

				assert.is_true(profileSent, "Gossip.SendProfile should be called for third-party profile")
				assert.are.equal("OtherPlayer", sentTo)
				assert.are.equal(profileBTag, sentBTag)
				assert.are.equal(0, sentAfter)
			end)

			it("should send own profile data when requested about ourselves", function()
				local ns, Protocol = SetupProtocol()

				local myBTag = "TestPlayer#1234"

				-- Set up our own characters
				ns.DB.GetCharactersAddedAfter = function(afterTs)
					return {
						{ name = "MyChar1", realm = "Stormrage", addedAt = 1700000000 },
					}
				end

				local aliasSent = false
				local charsSent = false
				ns.AddonMessages.BuildMessage = function(msgType, data)
					if msgType == "A" then
						aliasSent = true
						assert.are.equal(myBTag, data.b)
						assert.are.equal("TestAlias", data.a)
						return "encoded_alias"
					end
					return "encoded_message"
				end
				ns.AddonMessages.SendMessage = function()
					return true
				end
				ns.Coordinator.SendCharsUpdate = function(bt, chars, ts, channel, target)
					charsSent = true
					assert.are.equal(myBTag, bt)
					assert.are.equal(1, #chars)
					return true
				end

				local payload = {
					t = "GR",
					b = myBTag,
					af = 0,
				}

				SimulateMessage(ns, payload)

				assert.is_true(aliasSent, "ALIAS_UPDATE should be sent for our own profile")
				assert.is_true(charsSent, "CHARS_UPDATE should be sent for our own profile")
			end)

			it("should support delta request with afterTimestamp > 0", function()
				local ns, Protocol = SetupProtocol()

				local profileBTag = "Profile#2222"
				local sentAfter
				ns.Gossip.SendProfile = function(target, bt, af)
					sentAfter = af
				end

				ns.CharacterCache.FindBattleTag = function()
					return "Sender#9999"
				end
				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return { aliasUpdatedAt = 1700000100, charsUpdatedAt = 1700000200, characters = {} }
					end
					return nil
				end
				ns.DB.GetCharacterCount = function()
					return 0
				end

				local payload = {
					t = "GR",
					b = profileBTag,
					af = 1700000100,
				}

				SimulateMessage(ns, payload)

				assert.are.equal(1700000100, sentAfter, "afterTimestamp should be passed through for delta request")
			end)

			it("should handle invalid battleTag gracefully", function()
				local ns, Protocol = SetupProtocol()

				local profileSent = false
				ns.Gossip.SendProfile = function()
					profileSent = true
				end

				local payload = {
					t = "GR",
					b = "", -- invalid
					af = 0,
				}

				SimulateMessage(ns, payload)

				assert.is_false(profileSent, "Should not send profile for invalid battleTag")
			end)

			it("should update gossip tracking after responding", function()
				local ns, Protocol = SetupProtocol()

				local profileBTag = "Profile#2222"
				local senderBTag = "Sender#9999"

				ns.CharacterCache.FindBattleTag = function(name)
					if name == "OtherPlayer" then
						return senderBTag
					end
					return nil
				end

				ns.DB.GetProfile = function(bt)
					if bt == profileBTag then
						return {
							alias = "Alias",
							aliasUpdatedAt = 1700000100,
							charsUpdatedAt = 1700000200,
							characters = { { name = "C1", realm = "R", addedAt = 1700000200 } },
						}
					end
					return nil
				end
				ns.DB.GetCharacterCount = function(profile)
					if profile and profile.characters then
						return #profile.characters
					end
					return 0
				end
				ns.Gossip.SendProfile = function() end

				local trackingUpdated = false
				local trackedTarget, trackedProfile, trackedAu, trackedCu, trackedCc
				ns.DB.UpdateGossipTracking = function(target, profile, au, cu, cc)
					trackingUpdated = true
					trackedTarget = target
					trackedProfile = profile
					trackedAu = au
					trackedCu = cu
					trackedCc = cc
				end

				local payload = {
					t = "GR",
					b = profileBTag,
					af = 0,
				}

				SimulateMessage(ns, payload)

				assert.is_true(trackingUpdated, "Gossip tracking should be updated after responding to request")
				assert.are.equal(senderBTag, trackedTarget)
				assert.are.equal(profileBTag, trackedProfile)
				assert.are.equal(1700000100, trackedAu)
				assert.are.equal(1700000200, trackedCu)
				assert.are.equal(1, trackedCc)
			end)

			it("should handle missing profile gracefully", function()
				local ns, Protocol = SetupProtocol()

				local profileBTag = "Gone#9999"
				ns.DB.GetProfile = function()
					return nil
				end

				local profileSent = false
				ns.Gossip.SendProfile = function()
					profileSent = true
				end

				ns.CharacterCache.FindBattleTag = function()
					return "Sender#9999"
				end

				local payload = {
					t = "GR",
					b = profileBTag,
					af = 0,
				}

				-- Should not error, SendProfile handles nil profile internally
				SimulateMessage(ns, payload)

				-- SendProfile is still called — it handles "not found" internally
				assert.is_true(profileSent, "SendProfile should be called (it handles nil profile)")
			end)
		end)

		describe("edge cases", function()
			it("should preserve unknown keys that aren't in the short key map", function()
				local ns, Protocol = SetupProtocol()

				-- A MANIFEST with an extra unknown field
				local senderBTag = "Neighbor#5678"
				local payload = {
					type = "M",
					battleTag = senderBTag,
					alias = "Alias",
					charsUpdatedAt = 1700000000,
					aliasUpdatedAt = 1700000000,
					unknownField = "should survive",
				}

				-- We just need it to not error; the unknown field is ignored by handlers
				-- but shouldn't cause a crash
				SimulateMessage(ns, payload)
			end)

			it("should handle numeric table keys (arrays) without mangling them", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				-- characters is a numerically-indexed array - indices must survive
				local payload = {
					t = "C",
					b = senderBTag,
					cu = 1700000000,
					c = {
						[1] = { n = "Char1", r = "Stormrage", d = 1700000000 },
						[2] = { n = "Char2", r = "Proudmoore", d = 1700000001 },
					},
				}

				local addedChars = nil
				ns.DB.AddCharactersToProfile = function(bt, chars)
					addedChars = chars
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_not_nil(addedChars)
				assert.are.equal(2, #addedChars)
			end)

			it("should handle mixed verbose and short keys in the same message", function()
				local ns, Protocol = SetupProtocol()

				local senderBTag = "Neighbor#5678"
				-- Mix: short 't' for type, verbose 'battleTag', short 'cu'
				local payload = {
					t = "C",
					battleTag = senderBTag,
					cu = 1700000000,
					characters = {
						-- Mix: short 'n' but verbose 'realm'
						{ n = "Char1", realm = "Stormrage", d = 1700000000 },
					},
				}

				local addedChars = nil
				ns.DB.AddCharactersToProfile = function(bt, chars)
					assert.are.equal(senderBTag, bt)
					addedChars = chars
					return true
				end

				SimulateMessage(ns, payload)

				assert.is_not_nil(addedChars, "Mixed keys should work")
				assert.are.equal(1, #addedChars)
				assert.are.equal("Char1", addedChars[1].name)
				assert.are.equal("Stormrage", addedChars[1].realm)
			end)

			it("should reject messages with wrong prefix", function()
				local ns, Protocol = SetupProtocol()

				local called = false
				ns.MessageCodec.Decode = function()
					called = true
					return { type = "M" }, nil
				end

				ns.Protocol.OnAddonMessage("WrongPrefix", "data", "GUILD", "OtherPlayer")

				assert.is_false(called, "Decode should not be called for wrong prefix")
			end)

			it("should reject empty/nil messages", function()
				local ns, Protocol = SetupProtocol()

				-- These should not error
				ns.Protocol.OnAddonMessage("Ndvrng", "", "GUILD", "OtherPlayer")
				ns.Protocol.OnAddonMessage("Ndvrng", nil, "GUILD", "OtherPlayer")
			end)
		end)
	end)
end)
