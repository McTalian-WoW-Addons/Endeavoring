--- Load-order test: loads every addon module in TOC order.
---
--- PURPOSE:
--- Exercises all module-level initialization code (constant definitions,
--- table creation, mixin setup, event registration) that runs when each
--- file is loaded by the WoW client. This code is never called from
--- individual function-level tests, so it would otherwise remain uncovered.
---
--- HOW IT WORKS:
--- 1. Loads extended WoW API stubs and Frame API stubs (beyond helper.lua basics)
--- 2. Parses Endeavoring.toc to discover .lua files in load order
--- 3. Creates a fresh addon namespace (addonName, ns) simulating WoW's vararg
--- 4. loadfile()s each .lua file from the TOC in order, passing (addonName, ns)
--- 5. Asserts that every module loads without error
--- 6. Spot-checks that key namespace fields were populated
---
--- DESIGN NOTES:
--- - This test does NOT use nsMocks.lua; it builds the namespace organically
---   by loading Bootstrap.lua first (which populates ns.Constants, ns.MSG_TYPE, etc.)
---   and then loading each subsequent module in order, just like WoW does.
--- - The extended stubs (APIs.lua, FrameAPI.lua) are only loaded here, keeping
---   the lighter mock environment for pure-logic specs.
--- - The TOC is parsed at runtime so this test automatically picks up new
---   modules without manual updates.

-- Extended stubs (beyond what helper.lua provides)
require("Endeavoring_spec._mocks.WoWGlobals.APIs")
require("Endeavoring_spec._mocks.WoWGlobals.FrameAPI")

--- Parse a FrameXML-style .xml file and return an ordered list of .lua file paths.
--- Extracts <Script file="..."/> entries, recursing into nested .xml imports.
---@param xmlPath string Path to the XML file
---@return string[] luaFiles Ordered list of .lua file paths
local function ParseXML(xmlPath)
	local xmlDir = xmlPath:match("^(.-/)[^/]+$") or ""
	local files = {}

	for line in io.lines(xmlPath) do
		-- Match both <Script file="..."/> and <Include file="..."/>
		local scriptFile = line:match('[Ss]cript%s+file="([^"]+)"')
			or line:match('[Ii]nclude%s+file="([^"]+)"')
		if scriptFile then
			if scriptFile:match("%.lua$") then
				table.insert(files, xmlDir .. scriptFile)
			elseif scriptFile:match("%.xml$") then
				-- Recurse into nested XML files
				local nested = ParseXML(xmlDir .. scriptFile)
				for _, f in ipairs(nested) do
					table.insert(files, f)
				end
			end
		end
	end

	return files
end

--- Parse a .toc file and return an ordered list of .lua file paths.
--- Skips metadata (## lines), comments (#), and blank lines.
--- .xml entries are expanded by parsing their <Script> tags.
--- Paths are prefixed with the TOC's parent directory.
---@param tocPath string Absolute or relative path to the .toc file
---@return string[] luaFiles Ordered list of .lua file paths
local function ParseTOC(tocPath)
	local dir = tocPath:match("^(.-/)[^/]+$") or ""
	local files = {}

	for line in io.lines(tocPath) do
		-- Strip leading/trailing whitespace
		line = line:match("^%s*(.-)%s*$")

		-- Skip blank lines, metadata (##), and comments (#)
		if line ~= "" and not line:match("^#") then
			if line:match("%.lua$") then
				table.insert(files, dir .. line)
			elseif line:match("%.xml$") then
				-- Expand XML includes into their constituent .lua files
				local xmlFiles = ParseXML(dir .. line)
				for _, f in ipairs(xmlFiles) do
					table.insert(files, f)
				end
			end
		end
	end

	return files
end

describe("Load Order", function()
	local TOC_PATH = "Endeavoring/Endeavoring.toc"
	local TOC_FILES = ParseTOC(TOC_PATH)

	local addonName = "Endeavoring"
	local ns

	it("TOC contains at least one .lua file", function()
		assert.is_true(#TOC_FILES > 0, "No .lua files found in " .. TOC_PATH)
	end)

	it("loads all modules in TOC order without errors", function()
		ns = {}

		for _, path in ipairs(TOC_FILES) do
			local chunk, loadErr = loadfile(path)
			assert(chunk, string.format("Failed to load %s: %s", path, tostring(loadErr)))

			-- pcall to get a clear error message per module
			local ok, runErr = pcall(chunk, addonName, ns)
			assert(ok, string.format("Runtime error in %s: %s", path, tostring(runErr)))
		end
	end)

	-- Spot-checks: verify that key namespace fields were populated by the load
	describe("namespace population", function()
		before_each(function()
			-- Ensure the load test ran first (ns is populated in the it() above).
			-- If running in isolation, load everything now.
			if not ns or not ns.Constants then
				ns = {}
				for _, path in ipairs(TOC_FILES) do
					local chunk = assert(loadfile(path))
					chunk(addonName, ns)
				end
			end
		end)

		it("Bootstrap populates Constants", function()
			assert.is_table(ns.Constants)
			assert.is_string(ns.Constants.NO_ACTIVE_ENDEAVOR)
			assert.is_string(ns.Constants.PREFIX_INFO)
		end)

		it("Bootstrap populates MSG_TYPE", function()
			assert.is_table(ns.MSG_TYPE)
			assert.equals("M", ns.MSG_TYPE.MANIFEST)
			assert.equals("G", ns.MSG_TYPE.GOSSIP_DIGEST)
		end)

		it("Bootstrap populates SK (short keys)", function()
			assert.is_table(ns.SK)
			assert.equals("t", ns.SK.type)
			assert.equals("b", ns.SK.battleTag)
		end)

		it("Bootstrap populates state and ui tables", function()
			assert.is_table(ns.state)
			assert.is_table(ns.ui)
		end)

		it("Bootstrap defines DebugPrint", function()
			assert.is_function(ns.DebugPrint)
		end)

		it("Services are attached to namespace", function()
			assert.is_table(ns.PlayerInfo)
			assert.is_table(ns.MessageCodec)
			assert.is_table(ns.API)
			assert.is_table(ns.QuestRewards)
			assert.is_table(ns.AddonMessages)
		end)

		it("Data/Cache modules are attached", function()
			assert.is_table(ns.DB)
			assert.is_table(ns.CharacterCache)
			assert.is_table(ns.ActivityLogCache)
		end)

		it("Sync modules are attached", function()
			assert.is_table(ns.Coordinator)
			assert.is_table(ns.Gossip)
			assert.is_table(ns.Protocol)
		end)

		it("Feature modules are attached", function()
			assert.is_table(ns.Header)
			assert.is_table(ns.Tasks)
			assert.is_table(ns.Leaderboard)
			assert.is_table(ns.Activity)
			assert.is_table(ns.Settings)
		end)

		it("Integration modules are attached", function()
			assert.is_table(ns.Integrations)
			assert.is_table(ns.Integrations.HousingDashboard)
		end)

		it("Commands module is attached", function()
			assert.is_table(ns.Commands)
			assert.is_function(ns.Commands.Register)
		end)

		it("Core defines ToggleMainFrame", function()
			assert.is_function(ns.ToggleMainFrame)
		end)

		it("Core defines RefreshInitiativeUI", function()
			assert.is_function(ns.RefreshInitiativeUI)
		end)

		it("AddonMessages.ChatType enum is defined", function()
			assert.is_table(ns.AddonMessages.ChatType)
			assert.equals("GUILD", ns.AddonMessages.ChatType.Guild)
			assert.equals("WHISPER", ns.AddonMessages.ChatType.Whisper)
		end)

		it("DB has expected public functions", function()
			assert.is_function(ns.DB.Init)
			assert.is_function(ns.DB.RegisterCurrentCharacter)
			assert.is_function(ns.DB.GetMyProfile)
			assert.is_function(ns.DB.GetAllProfiles)
			assert.is_function(ns.DB.UpdateProfile)
		end)
	end)
end)
