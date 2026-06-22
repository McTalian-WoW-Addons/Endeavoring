--- Tests for Data/Database.lua
---
--- Covers:
--- - Init (fresh DB creation, migration/defaults, partial DB)
--- - RegisterCurrentCharacter (new char, existing char, no BattleTag)
--- - SetPlayerAlias / GetPlayerAlias / GetAlias
--- - GetCharacters (own, synced, not found)
--- - GetPlayerProfile / GetMyProfile / GetMyBattleTag
--- - GetCharacterCount
--- - GetAllProfiles / GetProfile
--- - GetMyProfileForBroadcast
--- - UpdateProfile (newer data, older data, self-protection)
--- - IsDataNewer
--- - GetManifest
--- - GetCharactersAddedAfter / GetProfileCharactersAddedAfter
--- - AddCharactersToProfile (new, update, self-protection, auto-init)
--- - UpdateProfileAlias (newer, older, self-protection, auto-init)
--- - PurgeSyncedProfiles
--- - IsVerboseDebug / SetVerboseDebug
--- - Activity log cache (Get/Set/Clear)
--- - Gossip tracking (Get/Update/Prune)
--- - Settings (Get/Set)
--- - LastSelectedTab (Get/Set)

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

--- Load Database into a fresh namespace, resetting the EndeavoringDB global
local function SetupDatabase(existingDB)
	_G.EndeavoringDB = existingDB or nil

	local ns = nsMocks.CreateNS()

	-- PlayerInfo stubs for RegisterCurrentCharacter
	ns.PlayerInfo.GetBattleTag = function()
		return "TestPlayer#1234"
	end
	ns.PlayerInfo.GetCharacterInfo = function()
		return { name = "Thrall", realm = "Stormrage" }
	end

	nsMocks.LoadAddonFile("Endeavoring/Data/Database.lua", ns)
	return ns, ns.DB
end

-- Tests ------------------------------------------------------------------

describe("Database", function()
	-- ================================================================
	-- Init
	-- ================================================================

	describe("Init", function()
		it("should create a fresh DB when EndeavoringDB is nil", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_not_nil(_G.EndeavoringDB)
			assert.is_not_nil(_G.EndeavoringDB.global)
			assert.are.same({}, _G.EndeavoringDB.global.profiles)
			assert.is_false(_G.EndeavoringDB.global.verboseDebug)
			assert.are.equal(1, _G.EndeavoringDB.global.version)
		end)

		it("should preserve existing data and fill missing fields", function()
			local ns, DB = SetupDatabase({
				global = {
					myProfile = {
						battleTag = "Existing#9999",
						alias = "Existing",
						aliasUpdatedAt = 100,
						characters = {},
						charsUpdatedAt = 100,
					},
				},
			})
			DB.Init()

			-- myProfile should be preserved
			assert.are.equal("Existing#9999", _G.EndeavoringDB.global.myProfile.battleTag)
			-- Missing fields should be filled
			assert.is_not_nil(_G.EndeavoringDB.global.profiles)
			assert.is_not_nil(_G.EndeavoringDB.global.version)
			assert.is_false(_G.EndeavoringDB.global.verboseDebug)
		end)

		it("should initialize global table if missing", function()
			local ns, DB = SetupDatabase({})
			DB.Init()

			assert.is_not_nil(_G.EndeavoringDB.global)
			assert.is_not_nil(_G.EndeavoringDB.global.profiles)
		end)
	end)

	-- ================================================================
	-- RegisterCurrentCharacter
	-- ================================================================

	describe("RegisterCurrentCharacter", function()
		it("should create myProfile and register character on first login", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			local success = DB.RegisterCurrentCharacter()
			assert.is_true(success)

			local profile = DB.GetMyProfile()
			assert.is_not_nil(profile)
			assert.are.equal("TestPlayer#1234", profile.battleTag)
			assert.are.equal("TestPlayer#1234", profile.alias) -- default alias = BattleTag
			assert.is_not_nil(profile.characters["Thrall"])
			assert.are.equal("Thrall", profile.characters["Thrall"].name)
			assert.are.equal("Stormrage", profile.characters["Thrall"].realm)
		end)

		it("should not duplicate an existing character", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			DB.RegisterCurrentCharacter()
			local firstTimestamp = DB.GetMyProfile().charsUpdatedAt

			-- Re-register same character
			DB.RegisterCurrentCharacter()
			local profile = DB.GetMyProfile()

			-- Should still have exactly one character
			local count = DB.GetCharacterCount(profile)
			assert.are.equal(1, count)
			-- Timestamp should not change
			assert.are.equal(firstTimestamp, profile.charsUpdatedAt)
		end)

		it("should return false when BattleTag is unavailable", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			ns.PlayerInfo.GetBattleTag = function()
				return nil
			end

			local success = DB.RegisterCurrentCharacter()
			assert.is_false(success)
			assert.is_nil(DB.GetMyProfile())
		end)

		it("should add a second character and update charsUpdatedAt", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			-- Switch to a different character
			ns.PlayerInfo.GetCharacterInfo = function()
				return { name = "Garrosh", realm = "Proudmoore" }
			end

			DB.RegisterCurrentCharacter()
			local profile = DB.GetMyProfile()
			assert.is_not_nil(profile.characters["Thrall"])
			assert.is_not_nil(profile.characters["Garrosh"])
			assert.are.equal(2, DB.GetCharacterCount(profile))
		end)
	end)

	-- ================================================================
	-- Alias Management
	-- ================================================================

	describe("SetPlayerAlias", function()
		it("should set alias on existing profile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local success = DB.SetPlayerAlias("ChiefWarchief")
			assert.is_true(success)
			assert.are.equal("ChiefWarchief", DB.GetPlayerAlias())
		end)

		it("should return false when BattleTag is unavailable", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			ns.PlayerInfo.GetBattleTag = function()
				return nil
			end

			local success = DB.SetPlayerAlias("Something")
			assert.is_false(success)
		end)

		it("should auto-initialize profile if missing", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			-- SetPlayerAlias should call RegisterCurrentCharacter if no profile
			local success = DB.SetPlayerAlias("AutoInit")
			assert.is_true(success)
			assert.are.equal("AutoInit", DB.GetPlayerAlias())
		end)
	end)

	describe("GetAlias", function()
		it("should return own alias for own BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()
			DB.SetPlayerAlias("MyAlias")

			assert.are.equal("MyAlias", DB.GetAlias("TestPlayer#1234"))
		end)

		it("should return synced profile alias", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#5678"] = {
				battleTag = "Other#5678",
				alias = "OtherAlias",
				aliasUpdatedAt = 100,
				characters = {},
				charsUpdatedAt = 100,
			}

			assert.are.equal("OtherAlias", DB.GetAlias("Other#5678"))
		end)

		it("should return nil for unknown BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetAlias("Nobody#0000"))
		end)

		it("should return nil when BattleTag not provided", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetAlias(nil))
		end)
	end)

	-- ================================================================
	-- GetCharacters
	-- ================================================================

	describe("GetCharacters", function()
		it("should return own characters for own BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local chars = DB.GetCharacters("TestPlayer#1234")
			assert.is_not_nil(chars)
			assert.is_not_nil(chars["Thrall"])
		end)

		it("should return synced profile characters", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#5678"] = {
				battleTag = "Other#5678",
				alias = "Other",
				aliasUpdatedAt = 100,
				characters = { ["Jaina"] = { name = "Jaina", realm = "Proudmoore", addedAt = 100 } },
				charsUpdatedAt = 100,
			}

			local chars = DB.GetCharacters("Other#5678")
			assert.is_not_nil(chars)
			assert.is_not_nil(chars["Jaina"])
		end)

		it("should return nil for unknown BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetCharacters("Nobody#0000"))
		end)

		it("should return nil when BattleTag not provided", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetCharacters(nil))
		end)
	end)

	-- ================================================================
	-- Profile Accessors
	-- ================================================================

	describe("GetMyBattleTag", function()
		it("should return BattleTag when profile exists", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			assert.are.equal("TestPlayer#1234", DB.GetMyBattleTag())
		end)

		it("should return nil when no profile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetMyBattleTag())
		end)
	end)

	describe("GetCharacterCount", function()
		it("should return 0 for nil profile", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.are.equal(0, DB.GetCharacterCount(nil))
		end)

		it("should return 0 for profile with no characters table", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.are.equal(0, DB.GetCharacterCount({ battleTag = "X" }))
		end)

		it("should count characters correctly", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			-- Add second character
			ns.PlayerInfo.GetCharacterInfo = function()
				return { name = "Garrosh", realm = "Proudmoore" }
			end
			DB.RegisterCurrentCharacter()

			assert.are.equal(2, DB.GetCharacterCount(DB.GetMyProfile()))
		end)
	end)

	describe("GetProfile", function()
		it("should return synced profile by BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#1111"] = {
				battleTag = "Other#1111",
				alias = "Other",
			}

			local profile = DB.GetProfile("Other#1111")
			assert.is_not_nil(profile)
			assert.are.equal("Other", profile.alias)
		end)

		it("should return myProfile when queried with own BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local profile = DB.GetProfile("TestPlayer#1234")
			assert.is_not_nil(profile)
			assert.are.equal("TestPlayer#1234", profile.battleTag)
		end)

		it("should return nil for nil BattleTag", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetProfile(nil))
		end)

		it("should return nil for unknown BattleTag", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetProfile("Unknown#0000"))
		end)
	end)

	-- ================================================================
	-- UpdateProfile
	-- ================================================================

	describe("UpdateProfile", function()
		it("should create a new synced profile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local result = DB.UpdateProfile("Other#2222", {
				battleTag = "Other#2222",
				alias = "OtherPlayer",
				charsUpdatedAt = 1700000100,
				characters = {},
			})
			assert.is_true(result)
			assert.are.equal("OtherPlayer", DB.GetProfile("Other#2222").alias)
		end)

		it("should update when incoming data is newer", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#2222"] = {
				battleTag = "Other#2222",
				alias = "OldAlias",
				charsUpdatedAt = 100,
				characters = {},
			}

			local result = DB.UpdateProfile("Other#2222", {
				battleTag = "Other#2222",
				alias = "NewAlias",
				charsUpdatedAt = 200,
				characters = {},
			})
			assert.is_true(result)
			assert.are.equal("NewAlias", DB.GetProfile("Other#2222").alias)
		end)

		it("should reject when incoming data is older", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#2222"] = {
				battleTag = "Other#2222",
				alias = "CurrentAlias",
				charsUpdatedAt = 200,
				characters = {},
			}

			local result = DB.UpdateProfile("Other#2222", {
				battleTag = "Other#2222",
				alias = "OlderAlias",
				charsUpdatedAt = 100,
				characters = {},
			})
			assert.is_false(result)
			assert.are.equal("CurrentAlias", DB.GetProfile("Other#2222").alias)
		end)

		it("should refuse to update myProfile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local result = DB.UpdateProfile("TestPlayer#1234", {
				battleTag = "TestPlayer#1234",
				alias = "Hacked",
				charsUpdatedAt = 9999999999,
				characters = {},
			})
			assert.is_false(result)
			-- Alias should be unchanged
			assert.are.equal("TestPlayer#1234", DB.GetMyProfile().alias)
		end)

		it("should return false for nil inputs", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_false(DB.UpdateProfile(nil, { charsUpdatedAt = 1 }))
			assert.is_false(DB.UpdateProfile("X#1", nil))
		end)
	end)

	-- ================================================================
	-- IsDataNewer
	-- ================================================================

	describe("IsDataNewer", function()
		it("should return true for unknown profile", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_true(DB.IsDataNewer("Unknown#1111", 100))
		end)

		it("should return true when incoming timestamp is newer", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#1111"] = {
				battleTag = "Other#1111",
				charsUpdatedAt = 100,
			}

			assert.is_true(DB.IsDataNewer("Other#1111", 200))
		end)

		it("should return false when incoming timestamp is older or equal", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#1111"] = {
				battleTag = "Other#1111",
				charsUpdatedAt = 200,
			}

			assert.is_false(DB.IsDataNewer("Other#1111", 200))
			assert.is_false(DB.IsDataNewer("Other#1111", 100))
		end)

		it("should return false for own BattleTag", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			assert.is_false(DB.IsDataNewer("TestPlayer#1234", 9999999999))
		end)

		it("should return false for nil inputs", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_false(DB.IsDataNewer(nil, 100))
			assert.is_false(DB.IsDataNewer("X#1", nil))
		end)
	end)

	-- ================================================================
	-- GetManifest
	-- ================================================================

	describe("GetManifest", function()
		it("should return manifest data from myProfile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()
			DB.SetPlayerAlias("ManifestAlias")

			local manifest = DB.GetManifest()
			assert.is_not_nil(manifest)
			assert.are.equal("TestPlayer#1234", manifest.battleTag)
			assert.are.equal("ManifestAlias", manifest.alias)
			assert.is_not_nil(manifest.charsUpdatedAt)
			assert.is_not_nil(manifest.aliasUpdatedAt)
		end)

		it("should return nil when no profile", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetManifest())
		end)
	end)

	-- ================================================================
	-- GetCharactersAddedAfter
	-- ================================================================

	describe("GetCharactersAddedAfter", function()
		it("should return characters added after timestamp", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local profile = DB.GetMyProfile()
			local charTimestamp = profile.characters["Thrall"].addedAt

			-- Characters added at charTimestamp should NOT be returned when filtering with charTimestamp
			local result = DB.GetCharactersAddedAfter(charTimestamp)
			assert.are.equal(0, #result)

			-- But should be returned when filtering with an earlier timestamp
			result = DB.GetCharactersAddedAfter(charTimestamp - 1)
			assert.are.equal(1, #result)
			assert.are.equal("Thrall", result[1].name)
		end)

		it("should return empty table when no profile", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			local result = DB.GetCharactersAddedAfter(0)
			assert.are.same({}, result)
		end)
	end)

	describe("GetProfileCharactersAddedAfter", function()
		it("should return characters from any profile added after timestamp", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			_G.EndeavoringDB.global.profiles["Other#5678"] = {
				battleTag = "Other#5678",
				alias = "Other",
				aliasUpdatedAt = 100,
				characters = {
					["Jaina"] = { name = "Jaina", realm = "Proudmoore", addedAt = 200 },
					["Anduin"] = { name = "Anduin", realm = "Proudmoore", addedAt = 300 },
				},
				charsUpdatedAt = 300,
			}

			-- Only Anduin added after 200
			local result = DB.GetProfileCharactersAddedAfter("Other#5678", 200)
			assert.are.equal(1, #result)
			assert.are.equal("Anduin", result[1].name)
		end)

		it("should return empty for unknown profile", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			local result = DB.GetProfileCharactersAddedAfter("Ghost#0000", 0)
			assert.are.same({}, result)
		end)
	end)

	-- ================================================================
	-- AddCharactersToProfile
	-- ================================================================

	describe("AddCharactersToProfile", function()
		it("should auto-initialize profile and add characters", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local result = DB.AddCharactersToProfile("New#3333", {
				{ name = "Velen", realm = "Argus", addedAt = 500 },
			})
			assert.is_true(result)

			local profile = DB.GetProfile("New#3333")
			assert.is_not_nil(profile)
			assert.is_not_nil(profile.characters["Velen"])
			assert.are.equal(500, profile.charsUpdatedAt)
		end)

		it("should update charsUpdatedAt to max addedAt", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			DB.AddCharactersToProfile("Other#3333", {
				{ name = "CharA", realm = "R1", addedAt = 100 },
				{ name = "CharB", realm = "R2", addedAt = 300 },
				{ name = "CharC", realm = "R3", addedAt = 200 },
			})

			local profile = DB.GetProfile("Other#3333")
			assert.are.equal(300, profile.charsUpdatedAt)
		end)

		it("should not overwrite a character with older data", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			_G.EndeavoringDB.global.profiles["Other#3333"] = {
				battleTag = "Other#3333",
				alias = "Other",
				aliasUpdatedAt = 100,
				characters = {
					["Thrall"] = { name = "Thrall", realm = "Stormrage", addedAt = 500 },
				},
				charsUpdatedAt = 500,
			}

			DB.AddCharactersToProfile("Other#3333", {
				{ name = "Thrall", realm = "OldRealm", addedAt = 100 },
			})

			-- Should keep the newer data
			assert.are.equal("Stormrage", DB.GetProfile("Other#3333").characters["Thrall"].realm)
		end)

		it("should refuse to update myProfile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local result = DB.AddCharactersToProfile("TestPlayer#1234", {
				{ name = "Hacked", realm = "X", addedAt = 9999 },
			})
			assert.is_false(result)
		end)

		it("should return false for nil inputs", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_false(DB.AddCharactersToProfile(nil, {}))
			assert.is_false(DB.AddCharactersToProfile("X#1", nil))
		end)
	end)

	-- ================================================================
	-- UpdateProfileAlias
	-- ================================================================

	describe("UpdateProfileAlias", function()
		it("should create profile and set alias if not exists", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local result = DB.UpdateProfileAlias("New#4444", "FreshAlias", 1000)
			assert.is_true(result)

			local profile = DB.GetProfile("New#4444")
			assert.are.equal("FreshAlias", profile.alias)
			assert.are.equal(1000, profile.aliasUpdatedAt)
		end)

		it("should update alias when newer", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#4444"] = {
				battleTag = "Other#4444",
				alias = "OldAlias",
				aliasUpdatedAt = 100,
				characters = {},
				charsUpdatedAt = 50,
			}

			local result = DB.UpdateProfileAlias("Other#4444", "NewAlias", 200)
			assert.is_true(result)
			assert.are.equal("NewAlias", DB.GetProfile("Other#4444").alias)
			-- charsUpdatedAt should be unchanged
			assert.are.equal(50, DB.GetProfile("Other#4444").charsUpdatedAt)
		end)

		it("should reject alias update when older", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()

			_G.EndeavoringDB.global.profiles["Other#4444"] = {
				battleTag = "Other#4444",
				alias = "CurrentAlias",
				aliasUpdatedAt = 200,
				characters = {},
				charsUpdatedAt = 50,
			}

			local result = DB.UpdateProfileAlias("Other#4444", "OlderAlias", 100)
			assert.is_false(result)
			assert.are.equal("CurrentAlias", DB.GetProfile("Other#4444").alias)
		end)

		it("should refuse to update myProfile alias via sync", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			local result = DB.UpdateProfileAlias("TestPlayer#1234", "Hacked", 9999999999)
			assert.is_false(result)
		end)

		it("should return false for nil inputs", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_false(DB.UpdateProfileAlias(nil, "X", 1))
			assert.is_false(DB.UpdateProfileAlias("X#1", nil, 1))
			assert.is_false(DB.UpdateProfileAlias("X#1", "X", nil))
		end)
	end)

	-- ================================================================
	-- PurgeSyncedProfiles
	-- ================================================================

	describe("PurgeSyncedProfiles", function()
		it("should remove all synced profiles and return count", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			_G.EndeavoringDB.global.profiles["A#1"] = { battleTag = "A#1" }
			_G.EndeavoringDB.global.profiles["B#2"] = { battleTag = "B#2" }
			_G.EndeavoringDB.global.profiles["C#3"] = { battleTag = "C#3" }

			local count = DB.PurgeSyncedProfiles()
			assert.are.equal(3, count)
			assert.are.same({}, DB.GetAllProfiles())
		end)

		it("should preserve myProfile", function()
			local ns, DB = SetupDatabase(nil)
			DB.Init()
			DB.RegisterCurrentCharacter()

			_G.EndeavoringDB.global.profiles["A#1"] = { battleTag = "A#1" }
			DB.PurgeSyncedProfiles()

			-- myProfile should be untouched
			assert.is_not_nil(DB.GetMyProfile())
			assert.are.equal("TestPlayer#1234", DB.GetMyBattleTag())
		end)

		it("should return 0 when no synced profiles", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.are.equal(0, DB.PurgeSyncedProfiles())
		end)
	end)

	-- ================================================================
	-- VerboseDebug
	-- ================================================================

	describe("VerboseDebug", function()
		it("should default to false", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_false(DB.IsVerboseDebug())
		end)

		it("should toggle verbose debug", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.SetVerboseDebug(true)
			assert.is_true(DB.IsVerboseDebug())

			DB.SetVerboseDebug(false)
			assert.is_false(DB.IsVerboseDebug())
		end)

		it("should handle missing DB gracefully", function()
			local _, DB = SetupDatabase(nil)
			-- Don't call Init - DB is nil
			_G.EndeavoringDB = nil

			assert.is_false(DB.IsVerboseDebug())
			-- SetVerboseDebug should not error
			DB.SetVerboseDebug(true)
		end)
	end)

	-- ================================================================
	-- Activity Log Cache
	-- ================================================================

	describe("ActivityLogCache", function()
		it("should store and retrieve cached activity log", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			local activityData = {
				isLoaded = true,
				neighborhoodGUID = "GUID-123",
				nextUpdateTime = time() + 3600,
				taskActivity = { { taskID = 1, completions = 5 } },
			}

			DB.SetActivityLogCache("GUID-123", activityData)

			local cached, isStale = DB.GetActivityLogCache("GUID-123")
			assert.is_not_nil(cached)
			assert.is_false(isStale)
			assert.is_true(cached.isLoaded)
			assert.are.equal(1, #cached.taskActivity)
		end)

		it("should report stale cache based on nextUpdateTime", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			local activityData = {
				isLoaded = true,
				neighborhoodGUID = "GUID-123",
				nextUpdateTime = time() - 1, -- Already past
				taskActivity = {},
			}

			DB.SetActivityLogCache("GUID-123", activityData)

			local cached, isStale = DB.GetActivityLogCache("GUID-123")
			assert.is_not_nil(cached)
			assert.is_true(isStale)
		end)

		it("should return nil for uncached neighborhood", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			local cached, isStale = DB.GetActivityLogCache("GUID-NOPE")
			assert.is_nil(cached)
			assert.is_false(isStale)
		end)

		it("should clear specific neighborhood cache", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.SetActivityLogCache(
				"GUID-A",
				{ isLoaded = true, neighborhoodGUID = "GUID-A", nextUpdateTime = 0, taskActivity = {} }
			)
			DB.SetActivityLogCache(
				"GUID-B",
				{ isLoaded = true, neighborhoodGUID = "GUID-B", nextUpdateTime = 0, taskActivity = {} }
			)

			DB.ClearActivityLogCache("GUID-A")

			assert.is_nil(DB.GetActivityLogCache("GUID-A"))
			assert.is_not_nil(DB.GetActivityLogCache("GUID-B"))
		end)

		it("should clear all cache when no GUID provided", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.SetActivityLogCache(
				"GUID-A",
				{ isLoaded = true, neighborhoodGUID = "GUID-A", nextUpdateTime = 0, taskActivity = {} }
			)
			DB.SetActivityLogCache(
				"GUID-B",
				{ isLoaded = true, neighborhoodGUID = "GUID-B", nextUpdateTime = 0, taskActivity = {} }
			)

			DB.ClearActivityLogCache(nil)

			assert.is_nil(DB.GetActivityLogCache("GUID-A"))
			assert.is_nil(DB.GetActivityLogCache("GUID-B"))
		end)
	end)

	-- ================================================================
	-- Gossip Tracking
	-- ================================================================

	describe("GossipTracking", function()
		it("should return empty table for unknown target", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.are.same({}, DB.GetGossipTracking("Nobody#0000"))
		end)

		it("should store and retrieve tracking data", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.UpdateGossipTracking("Target#1111", "Profile#2222", 100, 200, 3)

			local tracking = DB.GetGossipTracking("Target#1111")
			assert.is_not_nil(tracking["Profile#2222"])
			assert.are.equal(100, tracking["Profile#2222"].au)
			assert.are.equal(200, tracking["Profile#2222"].cu)
			assert.are.equal(3, tracking["Profile#2222"].cc)
		end)

		it("should overwrite tracking for same target+profile pair", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.UpdateGossipTracking("Target#1111", "Profile#2222", 100, 200, 3)
			DB.UpdateGossipTracking("Target#1111", "Profile#2222", 150, 250, 4)

			local tracking = DB.GetGossipTracking("Target#1111")
			assert.are.equal(150, tracking["Profile#2222"].au)
			assert.are.equal(250, tracking["Profile#2222"].cu)
			assert.are.equal(4, tracking["Profile#2222"].cc)
		end)

		it("should handle nil timestamps gracefully", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.UpdateGossipTracking("Target#1111", "Profile#2222", nil, nil, nil)

			local tracking = DB.GetGossipTracking("Target#1111")
			assert.are.equal(0, tracking["Profile#2222"].au)
			assert.are.equal(0, tracking["Profile#2222"].cu)
			assert.are.equal(0, tracking["Profile#2222"].cc)
		end)

		it("should return empty table for nil target", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.are.same({}, DB.GetGossipTracking(nil))
		end)

		it("should not error on UpdateGossipTracking with nil inputs", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			-- Should not error
			DB.UpdateGossipTracking(nil, "X#1", 1, 2, 3)
			DB.UpdateGossipTracking("X#1", nil, 1, 2, 3)
		end)
	end)

	describe("PruneGossipTracking", function()
		it("should remove entries not in valid set", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.UpdateGossipTracking("Keep#1111", "P#1", 1, 1, 1)
			DB.UpdateGossipTracking("Remove#2222", "P#2", 2, 2, 2)
			DB.UpdateGossipTracking("Keep#3333", "P#3", 3, 3, 3)

			local removed = DB.PruneGossipTracking({
				["Keep#1111"] = true,
				["Keep#3333"] = true,
			})

			assert.are.equal(1, removed)
			assert.is_not_nil(next(DB.GetGossipTracking("Keep#1111")))
			assert.are.same({}, DB.GetGossipTracking("Remove#2222"))
			assert.is_not_nil(next(DB.GetGossipTracking("Keep#3333")))
		end)

		it("should return 0 when nothing to prune", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.UpdateGossipTracking("Keep#1111", "P#1", 1, 1, 1)

			local removed = DB.PruneGossipTracking({ ["Keep#1111"] = true })
			assert.are.equal(0, removed)
		end)

		it("should return 0 for nil validBattleTags", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.are.equal(0, DB.PruneGossipTracking(nil))
		end)
	end)

	-- ================================================================
	-- Settings
	-- ================================================================

	describe("Settings", function()
		it("should return nil when no settings set", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetSettings())
		end)

		it("should store and retrieve settings", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.SetSettings({ showMinimap = true, scale = 1.2 })

			local settings = DB.GetSettings()
			assert.is_not_nil(settings)
			assert.is_true(settings.showMinimap)
			assert.are.equal(1.2, settings.scale)
		end)
	end)

	describe("LastSelectedTab", function()
		it("should return nil when not set", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			assert.is_nil(DB.GetLastSelectedTab())
		end)

		it("should store and retrieve tab ID", function()
			local _, DB = SetupDatabase(nil)
			DB.Init()

			DB.SetLastSelectedTab(2)
			assert.are.equal(2, DB.GetLastSelectedTab())

			DB.SetLastSelectedTab(3)
			assert.are.equal(3, DB.GetLastSelectedTab())
		end)
	end)
end)
