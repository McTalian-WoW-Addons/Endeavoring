--- Tests for Services/MessageCodec.lua
---
--- Covers: Encode (guard checks, pipeline), Decode (guard checks, pipeline),
--- EstimateSize, GetStats. Uses stubbed C_EncodingUtil to test the
--- encode/decode plumbing without real CBOR/compression.

local nsMocks = require("Endeavoring_spec._mocks.nsMocks")

describe("MessageCodec", function()
	local ns

	before_each(function()
		ns = nsMocks.CreateNS()

		-- Stub C_EncodingUtil with identity transforms for pipeline testing
		_G.C_EncodingUtil = {
			SerializeCBOR = function(data)
				return "cbor:" .. tostring(data)
			end,
			DeserializeCBOR = function(data)
				return { decoded = true }
			end,
			CompressString = function(s)
				return "compressed:" .. s
			end,
			DecompressString = function(s)
				return s:gsub("^compressed:", "")
			end,
			EncodeBase64 = function(s)
				return "b64:" .. s
			end,
			DecodeBase64 = function(s)
				return s:gsub("^b64:", "")
			end,
		}

		nsMocks.LoadAddonFile("Endeavoring/Services/MessageCodec.lua", ns)
	end)

	-- ========================================
	-- Encode
	-- ========================================
	describe("Encode", function()
		it("returns encoded string through full pipeline", function()
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_string(encoded)
			assert.is_nil(err)
			-- Should have passed through all 3 steps: CBOR → compress → base64
			assert.truthy(encoded:find("b64:"))
		end)

		it("returns nil when SerializeCBOR is missing", function()
			_G.C_EncodingUtil.SerializeCBOR = nil
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.is_string(err)
		end)

		it("returns nil when CompressString is missing", function()
			_G.C_EncodingUtil.CompressString = nil
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.is_string(err)
		end)

		it("returns nil when EncodeBase64 is missing", function()
			_G.C_EncodingUtil.EncodeBase64 = nil
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.is_string(err)
		end)

		it("returns nil when C_EncodingUtil is nil", function()
			_G.C_EncodingUtil = nil
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.is_string(err)
		end)

		it("returns nil when CBOR serialization returns empty", function()
			_G.C_EncodingUtil.SerializeCBOR = function()
				return ""
			end
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.truthy(err:find("serialization"))
		end)

		it("returns nil when CBOR serialization returns nil", function()
			_G.C_EncodingUtil.SerializeCBOR = function()
				return nil
			end
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.truthy(err:find("serialization"))
		end)

		it("returns nil when compression returns empty", function()
			_G.C_EncodingUtil.CompressString = function()
				return ""
			end
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.truthy(err:find("compression"))
		end)

		it("returns nil when base64 encoding returns empty", function()
			_G.C_EncodingUtil.EncodeBase64 = function()
				return ""
			end
			local encoded, err = ns.MessageCodec.Encode({ test = true })
			assert.is_nil(encoded)
			assert.truthy(err:find("encoding"))
		end)
	end)

	-- ========================================
	-- Decode
	-- ========================================
	describe("Decode", function()
		it("returns decoded table through full pipeline", function()
			local data, err = ns.MessageCodec.Decode("b64:compressed:cbor_data")
			assert.is_table(data)
			assert.is_nil(err)
			assert.is_true(data.decoded)
		end)

		it("returns nil for nil input", function()
			local data, err = ns.MessageCodec.Decode(nil)
			assert.is_nil(data)
			assert.truthy(err:find("Empty"))
		end)

		it("returns nil for empty string", function()
			local data, err = ns.MessageCodec.Decode("")
			assert.is_nil(data)
			assert.truthy(err:find("Empty"))
		end)

		it("returns nil when DeserializeCBOR is missing", function()
			_G.C_EncodingUtil.DeserializeCBOR = nil
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.is_string(err)
		end)

		it("returns nil when DecompressString is missing", function()
			_G.C_EncodingUtil.DecompressString = nil
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.is_string(err)
		end)

		it("returns nil when DecodeBase64 is missing", function()
			_G.C_EncodingUtil.DecodeBase64 = nil
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.is_string(err)
		end)

		it("returns nil when C_EncodingUtil is nil", function()
			_G.C_EncodingUtil = nil
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.is_string(err)
		end)

		it("returns nil when base64 decode returns empty", function()
			_G.C_EncodingUtil.DecodeBase64 = function()
				return ""
			end
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.truthy(err:find("Base64"))
		end)

		it("returns nil when decompression returns empty", function()
			_G.C_EncodingUtil.DecompressString = function()
				return ""
			end
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.truthy(err:find("decompression"))
		end)

		it("returns nil when CBOR deserialization returns nil", function()
			_G.C_EncodingUtil.DeserializeCBOR = function()
				return nil
			end
			local data, err = ns.MessageCodec.Decode("test")
			assert.is_nil(data)
			assert.truthy(err:find("deserialization"))
		end)
	end)

	-- ========================================
	-- EstimateSize
	-- ========================================
	describe("EstimateSize", function()
		it("returns size of encoded data", function()
			local size = ns.MessageCodec.EstimateSize({ test = true })
			assert.is_number(size)
			assert.is_true(size > 0)
		end)

		it("returns nil when encoding fails", function()
			_G.C_EncodingUtil.SerializeCBOR = function()
				return nil
			end
			local size = ns.MessageCodec.EstimateSize({ test = true })
			assert.is_nil(size)
		end)
	end)

	-- ========================================
	-- GetStats
	-- ========================================
	describe("GetStats", function()
		it("returns feature availability", function()
			local stats = ns.MessageCodec.GetStats()
			assert.is_table(stats)
			assert.is_table(stats.features)
			assert.is_true(stats.features.cbor)
			assert.is_true(stats.features.compression)
		end)

		it("reports missing features", function()
			_G.C_EncodingUtil = nil
			local stats = ns.MessageCodec.GetStats()
			assert.is_false(stats.features.cbor)
			assert.is_false(stats.features.compression)
		end)
	end)
end)
