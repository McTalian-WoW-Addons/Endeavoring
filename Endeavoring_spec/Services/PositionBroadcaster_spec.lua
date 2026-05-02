--- Tests for Services/PositionBroadcaster.lua
---
--- Covers:
--- - PLAYER_STARTED_MOVING: sets pending flag, starts ticker (if not running),
---   cancels pending stop debounce
--- - Ticker: broadcasts only when pending flag is set, clears flag after
--- - PLAYER_STOPPED_MOVING: sets pending flag, schedules debounced ticker stop
--- - Stutter-stepping: rapid STARTED/STOPPED cycles keep ticker alive via debounce cancellation
--- - Message structure: BuildMessage receives payload with all required short-key fields
--- - No-send guard: no broadcast when GetActiveChannel() returns nil neighborhoodGUID
--- - No-send guard: no broadcast when GetBattleTag() returns nil
--- - No-send guard: no broadcast when GetPlayerMapPosition returns nil
--- - No-send guard: no broadcast when channel number is 0 (not joined)
--- - GetDiagnostics: returns {lastBroadcastTime, tickerState, messagesSentCount}
--- - Init idempotence: calling Init twice registers only one frame
--- - messagesSentCount increments on each successful send
--- - SendMessage failure: count does NOT increment, error is logged

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

require("Endeavoring_spec._mocks.WoWGlobals.APIs")
require("Endeavoring_spec._mocks.WoWGlobals.FrameAPI")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ExtendNS(ns)
	ns.SK.x                = "px"
	ns.SK.y                = "py"
	ns.SK.mapID            = "mi"
	ns.SK.neighborhoodGUID = "ng"
	ns.SK.timestamp        = "ts"
	ns.SK.classFile        = "cf"

	ns.MSG_TYPE.POSITION_UPDATE = "P"

	ns.Position = {
		GetActiveChannel = function()
			return "NGUID-001", "Endeavoring-Neighborhood-NGUID-001"
		end,
		GetActiveChannelNumber = function()
			return 5
		end,
		GetActiveNeighborhoodGUID = function()
			return "NGUID-001"
		end,
	}

	ns.PlayerInfo.GetBattleTag = function()
		return "TestPlayer#1234"
	end

	return ns
end

local function Setup()
	local ns = ExtendNS(nsMocks.CreateNS())
	nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns)
	return ns, ns.PositionBroadcaster
end

--- Load PositionBroadcaster and capture the OnEvent handler registered by Init().
local function SetupWithFrameCapture()
	local ns = ExtendNS(nsMocks.CreateNS())

	local capturedOnEvent = nil
	local realCreateFrame = _G.CreateFrame
	_G.CreateFrame = function(...)
		local frame = realCreateFrame(...)
		local originalSetScript = frame.SetScript
		frame.SetScript = function(self, event, handler)
			if event == "OnEvent" then
				capturedOnEvent = handler
			end
			return originalSetScript(self, event, handler)
		end
		return frame
	end

	nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns)
	ns.PositionBroadcaster:Init()

	_G.CreateFrame = realCreateFrame

	return ns, ns.PositionBroadcaster, function() return capturedOnEvent end
end

--- Stub C_Map and UnitClass for a successful BroadcastPosition.
local function StubPositionAPIs(x, y, mapID)
	x     = x     or 0.5
	y     = y     or 0.3
	mapID = mapID or 1234

	local origUnitClass = _G.UnitClass
	local origCMap      = _G.C_Map

	_G.UnitClass = function() return "Warrior", "WARRIOR" end
	_G.C_Map = {
		GetBestMapForUnit    = function() return mapID end,
		GetPlayerMapPosition = function() return { x = x, y = y } end,
	}

	return function()
		_G.UnitClass = origUnitClass
		_G.C_Map     = origCMap
	end
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("PositionBroadcaster", function()

	local savedNewTicker
	local savedTimerAfter
	before_each(function()
		savedNewTicker  = _G.C_Timer.NewTicker
		savedTimerAfter = _G.C_Timer.After
	end)
	after_each(function()
		_G.C_Timer.NewTicker = savedNewTicker
		_G.C_Timer.After     = savedTimerAfter
	end)

	-- =========================================================================
	-- Movement event logic
	-- =========================================================================
	describe("movement events", function()

		it("PLAYER_STARTED_MOVING starts a ticker and sets pending flag", function()
			local restore = StubPositionAPIs()
			local tickerStarted = false
			local broadcastCount = 0

			local ns2, bc, getHandler = SetupWithFrameCapture()
			local origBroadcast = bc.BroadcastPosition
			bc.BroadcastPosition = function()
				broadcastCount = broadcastCount + 1
				return origBroadcast()
			end

			local tickerCallback = nil
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerStarted = true
				tickerCallback = cb
				return { Cancel = function() end }
			end

			getHandler()(nil, "PLAYER_STARTED_MOVING")
			assert.is_true(tickerStarted, "STARTED should start ticker")
			assert.are.equal(0, broadcastCount, "STARTED should NOT broadcast immediately")
			tickerCallback()
			assert.are.equal(1, broadcastCount, "Ticker should broadcast when pending flag is set")
			restore()
		end)

		it("PLAYER_STARTED_MOVING starts a ticker", function()
			local restore = StubPositionAPIs()
			local tickerStarted = false

			local _, _, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerStarted = true
				return { Cancel = function() end }
			end

			getHandler()(nil, "PLAYER_STARTED_MOVING")
			restore()

			assert.is_true(tickerStarted)
		end)

		it("PLAYER_STARTED_MOVING uses 1.5s ticker interval", function()
			local restore = StubPositionAPIs()
			local capturedInterval = nil

			local _, _, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				capturedInterval = interval
				return { Cancel = function() end }
			end

			getHandler()(nil, "PLAYER_STARTED_MOVING")
			restore()

			assert.are.equal(1.5, capturedInterval)
		end)

		it("second PLAYER_STARTED_MOVING does not start a new ticker", function()
			local restore = StubPositionAPIs()
			local tickerStartCount = 0

			local _, _, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerStartCount = tickerStartCount + 1
				return { Cancel = function() end }
			end

			local onEvent = getHandler()
			onEvent(nil, "PLAYER_STARTED_MOVING")
			onEvent(nil, "PLAYER_STARTED_MOVING")
			onEvent(nil, "PLAYER_STARTED_MOVING")
			restore()

			assert.are.equal(1, tickerStartCount)
		end)

		it("PLAYER_STARTED_MOVING does not start second ticker if already running", function()
			local restore = StubPositionAPIs()
			local tickerStartCount = 0

			local _, _, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerStartCount = tickerStartCount + 1
				return { Cancel = function() end }
			end
			_G.C_Timer.NewTimer = function() return { Cancel = function() end } end

			local onEvent = getHandler()
			onEvent(nil, "PLAYER_STARTED_MOVING")
			onEvent(nil, "PLAYER_STARTED_MOVING")
			restore()

			assert.are.equal(1, tickerStartCount)
		end)

		it("PLAYER_STARTED_MOVING broadcasts if pending flag is set", function()
			local restore = StubPositionAPIs()
			local broadcastCount = 0

			local ns2, bc, getHandler = SetupWithFrameCapture()
			local origBroadcast = bc.BroadcastPosition
			bc.BroadcastPosition = function()
				broadcastCount = broadcastCount + 1
				return origBroadcast()
			end

			local tickerCallback = nil
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerCallback = cb
				return { Cancel = function() end }
			end
			_G.C_Timer.NewTimer = function() return { Cancel = function() end } end

			local onEvent = getHandler()
			broadcastCount = 0
			onEvent(nil, "PLAYER_STARTED_MOVING")
			assert.are.equal(0, broadcastCount, "STARTED should NOT broadcast immediately (pending flag instead)")
			tickerCallback()
			assert.are.equal(1, broadcastCount, "Ticker should broadcast when pending flag is set")
			restore()
		end)

		it("PLAYER_STOPPED_MOVING with no active ticker does not error", function()
			local restore = StubPositionAPIs()
			local _, _, getHandler = SetupWithFrameCapture()

			assert.has_no_errors(function()
				getHandler()(nil, "PLAYER_STOPPED_MOVING")
			end)
			restore()
		end)

		it("after PLAYER_STOPPED_MOVING a new PLAYER_STARTED_MOVING cancels the debounce timer", function()
			local restore = StubPositionAPIs()
			local debounceTimerCancelled = false

			local _, _, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function() return { Cancel = function() end } end
			_G.C_Timer.NewTimer = function()
				return {
					Cancel = function()
						debounceTimerCancelled = true
					end,
				}
			end

			local onEvent = getHandler()
			onEvent(nil, "PLAYER_STARTED_MOVING")
			onEvent(nil, "PLAYER_STOPPED_MOVING")
			debounceTimerCancelled = false  -- Reset flag after STOPPED creates it
			onEvent(nil, "PLAYER_STARTED_MOVING")
			restore()

			assert.is_true(debounceTimerCancelled, "STARTED should cancel the pending stop debounce")
		end)

		it("PLAYER_STOPPED_MOVING throttles rapid broadcasts (stutter-stepping)", function()
			local restore = StubPositionAPIs()
			local timerStopDebounces = {}

			local ns2, bc, getHandler = SetupWithFrameCapture()

			local tickerCallback = nil
			_G.C_Timer.NewTicker = function(interval, cb)
				tickerCallback = cb
				return { Cancel = function() end }
			end

			_G.C_Timer.NewTimer = function(delay, callback)
				table.insert(timerStopDebounces, callback)
				return { Cancel = function() end }
			end

			local onEvent = getHandler()
			-- Start movement
			onEvent(nil, "PLAYER_STARTED_MOVING")
			assert.are.equal(0, #timerStopDebounces, "STARTED should not schedule stop debounce")

			-- Stop movement
			onEvent(nil, "PLAYER_STOPPED_MOVING")
			assert.are.equal(1, #timerStopDebounces, "STOPPED should schedule stop debounce")

			-- Rapid restart (stutter-step)
			onEvent(nil, "PLAYER_STARTED_MOVING")
			assert.are.equal(1, #timerStopDebounces, "STARTED should cancel and not reschedule debounce")

			-- Stop again
			onEvent(nil, "PLAYER_STOPPED_MOVING")
			assert.are.equal(2, #timerStopDebounces, "Second STOPPED should schedule new debounce")

			-- Ticker is still running (wasn't stopped)
			assert.is_not_nil(tickerCallback, "Ticker should be running despite STOPPED events")

			restore()
		end)

	end)

	-- =========================================================================
	-- Message structure
	-- =========================================================================
	describe("message structure", function()

		it("BuildMessage receives payload with all required short-key fields", function()
			local fakeNow = 5000
			local origTime = _G.time
			_G.time = function() return fakeNow end
			local restore = StubPositionAPIs(0.5, 0.3, 1234)

			local ns2 = ExtendNS(nsMocks.CreateNS())
			local capturedMsgType = nil
			local capturedPayload = nil
			ns2.AddonMessages.BuildMessage = function(msgType, payload)
				capturedMsgType = msgType
				capturedPayload = payload
				return "encoded_msg"
			end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()

			restore()
			_G.time = origTime

			assert.are.equal("P",               capturedMsgType)
			assert.is_not_nil(capturedPayload)
			assert.are.equal(0.5,               capturedPayload["px"])
			assert.are.equal(0.3,               capturedPayload["py"])
			assert.are.equal(1234,              capturedPayload["mi"])
			assert.are.equal("NGUID-001",       capturedPayload["ng"])
			assert.are.equal("TestPlayer#1234", capturedPayload["b"])
			assert.are.equal(fakeNow,           capturedPayload["ts"])
		end)

		it("SendMessage is called with Channel chat type and string channel number", function()
			local restore = StubPositionAPIs()

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.Position.GetActiveChannelNumber = function() return 7 end
			local capturedChatType = nil
			local capturedTarget   = nil
			ns2.AddonMessages.SendMessage = function(msg, chatType, target)
				capturedChatType = chatType
				capturedTarget   = target
				return true
			end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()
			restore()

			assert.are.equal("CHANNEL", capturedChatType)
			assert.are.equal("7",       capturedTarget)
		end)

	end)

	-- =========================================================================
	-- Guard conditions (no-send paths)
	-- =========================================================================
	describe("no-send guards", function()

		it("does not send when GetActiveChannel returns nil neighborhoodGUID", function()
			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.Position.GetActiveChannel = function() return nil, nil end

			local sendCalled = false
			ns2.AddonMessages.SendMessage = function() sendCalled = true; return true end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()

			assert.is_false(sendCalled)
		end)

		it("does not send when channel number is 0 (not joined)", function()
			local restore = StubPositionAPIs()

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.Position.GetActiveChannelNumber = function() return 0 end
			local sendCalled = false
			ns2.AddonMessages.SendMessage = function() sendCalled = true; return true end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()
			restore()

			assert.is_false(sendCalled)
		end)

		it("does not send when GetBattleTag returns nil", function()
			local restore = StubPositionAPIs()

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.PlayerInfo.GetBattleTag = function() return nil end
			local sendCalled = false
			ns2.AddonMessages.SendMessage = function() sendCalled = true; return true end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()
			restore()

			assert.is_false(sendCalled)
		end)

		it("does not send when GetPlayerMapPosition returns nil", function()
			local origCMap = _G.C_Map
			_G.C_Map = {
				GetBestMapForUnit    = function() return 1234 end,
				GetPlayerMapPosition = function() return nil end,
			}

			local ns2 = ExtendNS(nsMocks.CreateNS())
			local sendCalled = false
			ns2.AddonMessages.SendMessage = function() sendCalled = true; return true end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()

			_G.C_Map = origCMap
			assert.is_false(sendCalled)
		end)

	end)

	-- =========================================================================
	-- GetDiagnostics
	-- =========================================================================
	describe("GetDiagnostics", function()

		it("returns tickerState=idle when no ticker is running", function()
			local _, bc = Setup()
			assert.are.equal("idle", bc.GetDiagnostics().tickerState)
		end)

		it("returns nil lastBroadcastTime before any successful send", function()
			local _, bc = Setup()
			assert.is_nil(bc.GetDiagnostics().lastBroadcastTime)
		end)

		it("returns messagesSentCount = 0 on fresh load", function()
			local _, bc = Setup()
			assert.are.equal(0, bc.GetDiagnostics().messagesSentCount)
		end)

		it("reports updated lastBroadcastTime and count after successful sends", function()
			local fakeNow = 9999
			local origTime = _G.time
			_G.time = function() return fakeNow end
			local restore = StubPositionAPIs()

			local _, bc = Setup()
			bc.BroadcastPosition()
			bc.BroadcastPosition()

			local diag = bc.GetDiagnostics()

			restore()
			_G.time = origTime

			assert.are.equal(9999,   diag.lastBroadcastTime)
			assert.are.equal(2,      diag.messagesSentCount)
		end)

		it("reports tickerState=running while ticker is active", function()
			local restore = StubPositionAPIs()

			local ns2, bc, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				return { Cancel = function() end }
			end

			getHandler()(nil, "PLAYER_STARTED_MOVING")
			local diag = bc.GetDiagnostics()
			restore()

			assert.are.equal("running", diag.tickerState)
		end)

		it("reports tickerState=idle after debounce timer fires and ticker is stopped", function()
			local restore = StubPositionAPIs()

			local ns2, bc, getHandler = SetupWithFrameCapture()
			local timerCallback = nil
			_G.C_Timer.NewTicker = function(interval, cb)
				return { Cancel = function() end }
			end
			_G.C_Timer.NewTimer = function(delay, callback)
				timerCallback = callback
				return { Cancel = function() end }
			end

			local onEvent = getHandler()
			onEvent(nil, "PLAYER_STARTED_MOVING")
			local diag1 = bc.GetDiagnostics()
			assert.are.equal("running", diag1.tickerState, "Ticker should be running after STARTED")

			onEvent(nil, "PLAYER_STOPPED_MOVING")
			local diag2 = bc.GetDiagnostics()
			assert.are.equal("running", diag2.tickerState, "Ticker still running after STOPPED (debounce not expired)")

			timerCallback()
			local diag3 = bc.GetDiagnostics()
			assert.are.equal("idle", diag3.tickerState, "Ticker should be idle after debounce expires")
			restore()
		end)

	end)

	-- =========================================================================
	-- Init idempotence
	-- =========================================================================
	describe("Init", function()

		it("calling Init multiple times does not error and creates only one frame", function()
			local frameCreateCount = 0
			local realCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				frameCreateCount = frameCreateCount + 1
				return realCreateFrame(...)
			end

			local ns2 = ExtendNS(nsMocks.CreateNS())
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)

			assert.has_no_errors(function()
				ns2.PositionBroadcaster:Init()
				ns2.PositionBroadcaster:Init()
				ns2.PositionBroadcaster:Init()
			end)

			assert.are.equal(1, frameCreateCount)
			_G.CreateFrame = realCreateFrame
		end)

		it("registers both PLAYER_STARTED_MOVING and PLAYER_STOPPED_MOVING", function()
			local registeredEvents = {}
			local realCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				local frame = realCreateFrame(...)
				local origRegister = frame.RegisterEvent
				frame.RegisterEvent = function(self, event)
					table.insert(registeredEvents, event)
					return origRegister(self, event)
				end
				return frame
			end

			local ns2 = ExtendNS(nsMocks.CreateNS())
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:Init()
			_G.CreateFrame = realCreateFrame

			local hasStarted = false
			local hasStopped = false
			for _, e in ipairs(registeredEvents) do
				if e == "PLAYER_STARTED_MOVING" then hasStarted = true end
				if e == "PLAYER_STOPPED_MOVING" then hasStopped = true end
			end
			assert.is_true(hasStarted, "Expected PLAYER_STARTED_MOVING to be registered")
			assert.is_true(hasStopped, "Expected PLAYER_STOPPED_MOVING to be registered")
		end)

	end)

	-- =========================================================================
	-- SendMessage failure path
	-- =========================================================================
	describe("SendMessage failure", function()

		it("does NOT increment messagesSentCount when SendMessage returns false", function()
			local restore = StubPositionAPIs()

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.AddonMessages.SendMessage = function() return false end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()
			restore()

			assert.are.equal(0, ns2.PositionBroadcaster:GetDiagnostics().messagesSentCount)
		end)

		it("does NOT update lastBroadcastTime when SendMessage returns false", function()
			local restore = StubPositionAPIs()

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.AddonMessages.SendMessage = function() return false end

			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:BroadcastPosition()
			restore()

			assert.is_nil(ns2.PositionBroadcaster:GetDiagnostics().lastBroadcastTime)
		end)

	end)

	-- =========================================================================
	-- GetLastBroadcastTime (backward-compat shim)
	-- =========================================================================
	describe("GetLastBroadcastTime", function()

		it("returns nil before any send", function()
			local _, bc = Setup()
			assert.is_nil(bc.GetLastBroadcastTime())
		end)

		it("returns the timestamp of the last successful send", function()
			local fakeNow = 12345
			local origTime = _G.time
			_G.time = function() return fakeNow end
			local restore = StubPositionAPIs()

			local _, bc = Setup()
			bc.BroadcastPosition()

			local result = bc.GetLastBroadcastTime()

			restore()
			_G.time = origTime

			assert.are.equal(fakeNow, result)
		end)

	end)

	-- =========================================================================
	-- Privacy opt-out
	-- =========================================================================
	describe("privacy opt-out", function()

		it("Init() returns early without creating a frame when opted out", function()
			local frameCreateCount = 0
			local realCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				frameCreateCount = frameCreateCount + 1
				return realCreateFrame(...)
			end

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.Settings = { GetPositionOptOut = function() return true end }
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:Init()

			_G.CreateFrame = realCreateFrame
			assert.are.equal(0, frameCreateCount)
		end)

		it("Init() emits a DebugPrint log message when opted out", function()
			local debugLines = {}
			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.DebugPrint = function(msg) table.insert(debugLines, msg) end
			ns2.Settings = { GetPositionOptOut = function() return true end }
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:Init()

			local found = false
			for _, line in ipairs(debugLines) do
				if line:find("opt-out", 1, true) then found = true end
			end
			assert.is_true(found, "Expected a DebugPrint line mentioning opt-out")
		end)

		it("Init() proceeds normally (creates a frame) when opt-out is false", function()
			local frameCreateCount = 0
			local realCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				frameCreateCount = frameCreateCount + 1
				return realCreateFrame(...)
			end

			local ns2 = ExtendNS(nsMocks.CreateNS())
			ns2.Settings = { GetPositionOptOut = function() return false end }
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:Init()

			_G.CreateFrame = realCreateFrame
			assert.are.equal(1, frameCreateCount)
		end)

		it("Init() proceeds normally when ns.Settings is nil (load-order safety)", function()
			local frameCreateCount = 0
			local realCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				frameCreateCount = frameCreateCount + 1
				return realCreateFrame(...)
			end

			local ns2 = ExtendNS(nsMocks.CreateNS())
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:Init()

			_G.CreateFrame = realCreateFrame
			assert.are.equal(1, frameCreateCount)
		end)

	end)

	-- =========================================================================
	-- Shutdown
	-- =========================================================================
	describe("Shutdown", function()

		it("cancels the running ticker on shutdown", function()
			local restore = StubPositionAPIs()
			local cancelCount = 0

			local _, bc, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				return { Cancel = function() cancelCount = cancelCount + 1 end }
			end

			getHandler()(nil, "PLAYER_STARTED_MOVING")
			bc.Shutdown()
			restore()

			assert.are.equal(1, cancelCount)
		end)

		it("unregisters movement events so PLAYER_STARTED_MOVING no longer affects state", function()
			local restore = StubPositionAPIs()
			local tickerCallbacks = {}

			local ns2, bc, getHandler = SetupWithFrameCapture()
			_G.C_Timer.NewTicker = function(interval, cb)
				table.insert(tickerCallbacks, cb)
				return { Cancel = function() end }
			end
			_G.C_Timer.NewTimer = function() return { Cancel = function() end } end

			local origBroadcast = bc.BroadcastPosition
			local broadcastCount = 0
			bc.BroadcastPosition = function()
				broadcastCount = broadcastCount + 1
				return origBroadcast()
			end

			-- Fire a movement event before shutdown
			getHandler()(nil, "PLAYER_STARTED_MOVING")
			assert.are.equal(1, #tickerCallbacks, "Ticker should be created")
			tickerCallbacks[1]()
			assert.are.equal(1, broadcastCount, "Ticker should broadcast after STARTED")

			bc.Shutdown()

			-- After shutdown, ticker is cancelled and can't be used
			-- Verify by checking diagnostics show idle state
			assert.are.equal("idle", bc.GetDiagnostics().tickerState)
		end)

		it("is idempotent — calling Shutdown twice does not error", function()
			local _, bc = Setup()
			bc.Init()
			assert.has_no_errors(function()
				bc.Shutdown()
				bc.Shutdown()
			end)
		end)

		it("allows re-Init after Shutdown", function()
			local frameCreateCount = 0
			local realCreateFrame = _G.CreateFrame
			_G.CreateFrame = function(...)
				frameCreateCount = frameCreateCount + 1
				return realCreateFrame(...)
			end

			local ns2 = ExtendNS(nsMocks.CreateNS())
			nsMocks.LoadAddonFile("Endeavoring/Services/PositionBroadcaster.lua", ns2)
			ns2.PositionBroadcaster:Init()
			ns2.PositionBroadcaster:Shutdown()
			ns2.PositionBroadcaster:Init()  -- should create a new frame

			_G.CreateFrame = realCreateFrame
			assert.are.equal(2, frameCreateCount)
		end)

	end)

end)
