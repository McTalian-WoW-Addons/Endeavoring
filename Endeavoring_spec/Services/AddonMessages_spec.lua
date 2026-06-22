--- Tests for Services/AddonMessages.lua
---
--- Covers: Init (prefix registration, idempotence), BuildMessage (encoding,
--- size warnings), SendMessage (validation, lockdown, error codes),
--- ChatType enum, RegisterListener.

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- AddonMessages needs CreateFrame for RegisterListener
require("Endeavoring_spec._mocks.WoWGlobals.FrameAPI")

describe("AddonMessages", function()
	local ns

	before_each(function()
		ns = nsMocks.CreateNS()

		-- Reset C_ChatInfo for each test
		_G.C_ChatInfo = {
			RegisterAddonMessagePrefix = function()
				return true
			end,
			SendAddonMessage = function()
				return Enum.SendAddonMessageResult.Success
			end,
			InChatMessagingLockdown = function()
				return false
			end,
		}

		ns.Coordinator.Init = function() end

		-- Default: encoding returns a short string
		ns.MessageCodec.Encode = function(data)
			return "encoded_payload", nil
		end

		ns.PlayerInfo.IsInGuild = function()
			return true
		end
		ns.PlayerInfo.IsInHomeGroup = function()
			return false
		end
		ns.PlayerInfo.IsInInstanceGroup = function()
			return false
		end
		ns.PlayerInfo.IsGuildOfficer = function()
			return false
		end

		nsMocks.LoadAddonFile("Endeavoring/Services/AddonMessages.lua", ns)
	end)

	-- ========================================
	-- ChatType enum
	-- ========================================
	describe("ChatType", function()
		it("defines all channel types", function()
			assert.equals("PARTY", ns.AddonMessages.ChatType.Party)
			assert.equals("RAID", ns.AddonMessages.ChatType.Raid)
			assert.equals("INSTANCE_CHAT", ns.AddonMessages.ChatType.Instance)
			assert.equals("GUILD", ns.AddonMessages.ChatType.Guild)
			assert.equals("OFFICER", ns.AddonMessages.ChatType.Office)
			assert.equals("WHISPER", ns.AddonMessages.ChatType.Whisper)
			assert.equals("CHANNEL", ns.AddonMessages.ChatType.Channel)
		end)
	end)

	-- ========================================
	-- Init
	-- ========================================
	describe("Init", function()
		it("registers addon message prefix", function()
			local registered = false
			_G.C_ChatInfo.RegisterAddonMessagePrefix = function(prefix)
				registered = true
				assert.equals("Ndvrng", prefix)
				return true
			end
			ns.AddonMessages.Init()
			assert.is_true(registered)
		end)

		it("initializes coordinator", function()
			local coordInitCalled = false
			ns.Coordinator.Init = function()
				coordInitCalled = true
			end
			ns.AddonMessages.Init()
			assert.is_true(coordInitCalled)
		end)
	end)

	-- ========================================
	-- BuildMessage
	-- ========================================
	describe("BuildMessage", function()
		before_each(function()
			-- Init required before BuildMessage works (sets initialized = true)
			ns.AddonMessages.Init()
		end)

		it("encodes message with type in payload", function()
			local capturedData
			ns.MessageCodec.Encode = function(data)
				capturedData = data
				return "encoded", nil
			end
			local result = ns.AddonMessages.BuildMessage("M", { [ns.SK.battleTag] = "Test#1234" })
			assert.equals("encoded", result)
			assert.equals("M", capturedData[ns.SK.type])
			assert.equals("Test#1234", capturedData[ns.SK.battleTag])
		end)

		it("returns nil when encoding fails", function()
			ns.MessageCodec.Encode = function()
				return nil, "encode error"
			end
			local result = ns.AddonMessages.BuildMessage("M", {})
			assert.is_nil(result)
		end)
	end)

	-- ========================================
	-- SendMessage
	-- ========================================
	describe("SendMessage", function()
		before_each(function()
			ns.AddonMessages.Init()
		end)

		it("sends guild message successfully", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "GUILD")
			assert.is_true(result)
		end)

		it("rejects guild message when not in guild", function()
			ns.PlayerInfo.IsInGuild = function()
				return false
			end
			local result = ns.AddonMessages.SendMessage("test_msg", "GUILD")
			assert.is_false(result)
		end)

		it("rejects whisper without target", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "WHISPER", nil)
			assert.is_false(result)
		end)

		it("rejects whisper with empty target", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "WHISPER", "")
			assert.is_false(result)
		end)

		it("sends whisper with valid target", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "WHISPER", "Player")
			assert.is_true(result)
		end)

		it("rejects party message when not in home group", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "PARTY")
			assert.is_false(result)
		end)

		it("sends party message when in home group", function()
			ns.PlayerInfo.IsInHomeGroup = function()
				return true
			end
			local result = ns.AddonMessages.SendMessage("test_msg", "PARTY")
			assert.is_true(result)
		end)

		it("rejects instance message when not in instance group", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "INSTANCE_CHAT")
			assert.is_false(result)
		end)

		it("rejects officer message when not an officer", function()
			local result = ns.AddonMessages.SendMessage("test_msg", "OFFICER")
			assert.is_false(result)
		end)

		it("sends officer message when officer", function()
			ns.PlayerInfo.IsGuildOfficer = function()
				return true
			end
			local result = ns.AddonMessages.SendMessage("test_msg", "OFFICER")
			assert.is_true(result)
		end)

		it("rejects when chat messaging lockdown is active", function()
			_G.C_ChatInfo.InChatMessagingLockdown = function()
				return true, "restricted"
			end
			local result = ns.AddonMessages.SendMessage("test_msg", "GUILD")
			assert.is_false(result)
		end)

		it("rejects oversized messages", function()
			local bigMsg = string.rep("x", 256)
			local result = ns.AddonMessages.SendMessage(bigMsg, "GUILD")
			assert.is_false(result)
		end)

		it("accepts messages at exactly 255 bytes", function()
			local exactMsg = string.rep("x", 255)
			local result = ns.AddonMessages.SendMessage(exactMsg, "GUILD")
			assert.is_true(result)
		end)

		it("returns false on SendAddonMessage error", function()
			_G.C_ChatInfo.SendAddonMessage = function()
				return Enum.SendAddonMessageResult.NotInGuild
			end
			local result = ns.AddonMessages.SendMessage("test_msg", "GUILD")
			assert.is_false(result)
		end)

		it("returns false when not initialized", function()
			-- Create a fresh ns without calling Init
			local ns2 = nsMocks.CreateNS()
			ns2.Coordinator.Init = function() end
			ns2.MessageCodec.Encode = function()
				return "encoded"
			end
			nsMocks.LoadAddonFile("Endeavoring/Services/AddonMessages.lua", ns2)
			-- Don't call Init — SendMessage should fail
			local result = ns2.AddonMessages.SendMessage("test_msg", "GUILD")
			assert.is_false(result)
		end)
	end)

	-- ========================================
	-- RegisterListener
	-- ========================================
	describe("RegisterListener", function()
		it("creates event frame and registers CHAT_MSG_ADDON", function()
			local frameCreated = false
			local eventsRegistered = {}
			local originalCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				frameCreated = true
				local frame = originalCreateFrame(...)
				local origRegister = frame.RegisterEvent
				frame.RegisterEvent = function(self, event)
					table.insert(eventsRegistered, event)
					origRegister(self, event)
				end
				return frame
			end

			ns.AddonMessages.Init()
			ns.AddonMessages.RegisterListener()

			assert.is_true(frameCreated)
			assert.is_true(#eventsRegistered > 0)

			_G.CreateFrame = originalCreateFrame
		end)

		it("registers CHAT_MSG_ADDON and routes to Protocol.OnAddonMessage", function()
			-- Capture the frame created by RegisterListener
			local capturedFrame
			local originalCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				capturedFrame = originalCreateFrame(...)
				return capturedFrame
			end

			local routedArgs
			ns.Protocol = {
				OnAddonMessage = function(prefix, message, channel, sender)
					routedArgs = { prefix, message, channel, sender }
				end,
			}

			ns.AddonMessages.Init()
			ns.AddonMessages.RegisterListener()

			-- Simulate the event being fired
			local onEvent = capturedFrame:GetScript("OnEvent")
			assert.is_function(onEvent)
			onEvent(capturedFrame, "CHAT_MSG_ADDON", "Ndvrng", "payload", "GUILD", "Someone")

			assert.is_table(routedArgs)
			assert.equals("Ndvrng", routedArgs[1])
			assert.equals("payload", routedArgs[2])
			assert.equals("GUILD", routedArgs[3])
			assert.equals("Someone", routedArgs[4])

			_G.CreateFrame = originalCreateFrame
		end)
	end)
end)
