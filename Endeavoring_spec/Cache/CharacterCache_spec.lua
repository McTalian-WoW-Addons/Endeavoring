--- Tests for Cache/CharacterCache.lua
---
--- Covers:
--- - FindBattleTag exact match (name-only lookup)
--- - FindBattleTag realm-stripping ("Name-Realm" → "Name" fallback)
--- - Cache rebuild from profiles on lookup
--- - Invalidation (full and selective)

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

-- Helpers ----------------------------------------------------------------

--- Load CharacterCache into a fresh namespace and return both
local function SetupCharacterCache()
	local ns = nsMocks.CreateNS()

	nsMocks.LoadAddonFile("Endeavoring/Cache/CharacterCache.lua", ns)
	return ns, ns.CharacterCache
end

-- Tests ------------------------------------------------------------------

describe("CharacterCache", function()
	describe("FindBattleTag", function()
		it("should return BattleTag for exact character name match", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {
					["Player#1234"] = {
						characters = {
							{ name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
						},
					},
				}
			end

			local result = CharacterCache.FindBattleTag("Thrall")
			assert.are.equal("Player#1234", result)
		end)

		it("should return nil for unknown character name", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {}
			end

			local result = CharacterCache.FindBattleTag("NobodyKnowsMe")
			assert.is_nil(result)
		end)

		it("should strip realm suffix and find match", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {
					["Player#1234"] = {
						characters = {
							{ name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
						},
					},
				}
			end

			-- CHAT_MSG_ADDON sends "Name-Realm" format
			local result = CharacterCache.FindBattleTag("Thrall-Stormrage")
			assert.are.equal("Player#1234", result)
		end)

		it("should strip realm suffix even when realm differs from stored", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {
					["Player#1234"] = {
						characters = {
							{ name = "Thrall", realm = "Proudmoore", addedAt = 1700000000 },
						},
					},
				}
			end

			-- Sender is on a connected realm but name matches
			local result = CharacterCache.FindBattleTag("Thrall-Stormrage")
			assert.are.equal("Player#1234", result)
		end)

		it("should return nil when name-realm doesn't match any character", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {
					["Player#1234"] = {
						characters = {
							{ name = "Jaina", realm = "Stormrage", addedAt = 1700000000 },
						},
					},
				}
			end

			local result = CharacterCache.FindBattleTag("Thrall-Stormrage")
			assert.is_nil(result)
		end)

		it("should handle nil input gracefully", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {}
			end

			local result = CharacterCache.FindBattleTag(nil)
			assert.is_nil(result)
		end)

		it("should include own profile characters in cache", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {}
			end
			ns.DB.GetMyProfile = function()
				return {
					battleTag = "Me#1234",
					characters = {
						{ name = "MyChar", realm = "Stormrage", addedAt = 1700000000 },
					},
				}
			end

			local result = CharacterCache.FindBattleTag("MyChar")
			assert.are.equal("Me#1234", result)
		end)

		it("should find own profile via realm-stripped name", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {}
			end
			ns.DB.GetMyProfile = function()
				return {
					battleTag = "Me#1234",
					characters = {
						{ name = "MyChar", realm = "Stormrage", addedAt = 1700000000 },
					},
				}
			end

			local result = CharacterCache.FindBattleTag("MyChar-Stormrage")
			assert.are.equal("Me#1234", result)
		end)

		it("should find characters across multiple profiles", function()
			local ns, CharacterCache = SetupCharacterCache()

			ns.DB.GetAllProfiles = function()
				return {
					["Player#1111"] = {
						characters = {
							{ name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
						},
					},
					["Player#2222"] = {
						characters = {
							{ name = "Jaina", realm = "Proudmoore", addedAt = 1700000000 },
						},
					},
				}
			end

			assert.are.equal("Player#1111", CharacterCache.FindBattleTag("Thrall"))
			assert.are.equal("Player#2222", CharacterCache.FindBattleTag("Jaina"))
			assert.are.equal("Player#2222", CharacterCache.FindBattleTag("Jaina-Proudmoore"))
		end)
	end)

	describe("Invalidate", function()
		it("should rebuild cache after full invalidation", function()
			local ns, CharacterCache = SetupCharacterCache()

			-- Initial state: one character
			ns.DB.GetAllProfiles = function()
				return {
					["Player#1234"] = {
						characters = {
							{ name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
						},
					},
				}
			end

			-- Prime the cache
			assert.are.equal("Player#1234", CharacterCache.FindBattleTag("Thrall"))

			-- Add a new character and invalidate
			ns.DB.GetAllProfiles = function()
				return {
					["Player#1234"] = {
						characters = {
							{ name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
							{ name = "Garrosh", realm = "Stormrage", addedAt = 1700000001 },
						},
					},
				}
			end

			CharacterCache.Invalidate()

			-- Both should be found after rebuild
			assert.are.equal("Player#1234", CharacterCache.FindBattleTag("Thrall"))
			assert.are.equal("Player#1234", CharacterCache.FindBattleTag("Garrosh"))
		end)

		it("should rebuild selectively when specific BattleTag is invalidated", function()
			local ns, CharacterCache = SetupCharacterCache()

			-- Initial profiles
			ns.DB.GetAllProfiles = function()
				return {
					["Player#1111"] = {
						characters = {
							{ name = "Thrall", realm = "Stormrage", addedAt = 1700000000 },
						},
					},
				}
			end

			-- Prime
			assert.are.equal("Player#1111", CharacterCache.FindBattleTag("Thrall"))

			-- Selectively invalidate a specific profile
			ns.DB.GetProfile = function(bt)
				if bt == "Player#2222" then
					return {
						characters = {
							{ name = "Jaina", realm = "Proudmoore", addedAt = 1700000000 },
						},
					}
				end
				return nil
			end

			CharacterCache.Invalidate("Player#2222")

			-- Both should be found (Thrall from original cache, Jaina from selective rebuild)
			assert.are.equal("Player#1111", CharacterCache.FindBattleTag("Thrall"))
			assert.are.equal("Player#2222", CharacterCache.FindBattleTag("Jaina"))
		end)
	end)
end)
