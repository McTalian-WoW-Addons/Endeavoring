---@type string
local addonName = select(1, ...)
---@class Ndvrng_NS
local ns = select(2, ...)

local MessageCodec = {}
ns.MessageCodec = MessageCodec

local DebugPrint = ns.DebugPrint

--[[
Message Wire Format:
  Three-step encoding to handle binary data safely
  
  Encode: Table → CBOR serialize → Deflate compress → Base64 encode → String
  Decode: String → Base64 decode → Deflate decompress → CBOR deserialize → Table
  
  Base64 encoding ensures the compressed binary becomes safe ASCII characters
  for transmission through WoW's addon message API.
  
  Message type is embedded in the decoded table's 'type' field
--]]

--- Encode a Lua table/value into a wire-format string
--- Serializes to CBOR, compresses, then base64 encodes for safe transmission
--- @param data any The data to encode (table, string, number, etc.)
--- @return string|nil encoded The encoded message, or nil on failure
--- @return string|nil error Error message if encoding failed
function MessageCodec.Encode(data)
	-- Guard: Check if APIs are available
	if not C_EncodingUtil or not C_EncodingUtil.SerializeCBOR then
		return nil, "C_EncodingUtil.SerializeCBOR not available"
	end
	if not C_EncodingUtil.CompressString then
		return nil, "C_EncodingUtil.CompressString not available"
	end
	if not C_EncodingUtil.EncodeBase64 then
		return nil, "C_EncodingUtil.EncodeBase64 not available"
	end

	-- Step 1: Serialize to CBOR
	local serialized = C_EncodingUtil.SerializeCBOR(data)
	if not serialized or serialized == "" then
		return nil, "CBOR serialization failed"
	end

	-- Step 2: Compress with Deflate
	local compressed =
		C_EncodingUtil.CompressString(serialized, Enum.CompressionMethod.Deflate, Enum.CompressionLevel.OptimizeForSize)

	if not compressed or compressed == "" then
		return nil, "Deflate compression failed"
	end

	-- Step 3: Encode as Base64 for safe transmission
	local encoded = C_EncodingUtil.EncodeBase64(compressed)
	if not encoded or encoded == "" then
		return nil, "Base64 encoding failed"
	end

	return encoded, nil
end

--- Decode a wire-format string back into a Lua value
--- Base64 decodes, decompresses, then deserializes CBOR
--- @param encoded string The encoded message
--- @return any|nil data The decoded data, or nil on failure
--- @return string|nil error Error message if decoding failed
function MessageCodec.Decode(encoded)
	-- Guard: Check if APIs are available
	if not C_EncodingUtil or not C_EncodingUtil.DeserializeCBOR then
		return nil, "C_EncodingUtil.DeserializeCBOR not available"
	end
	if not C_EncodingUtil.DecompressString then
		return nil, "C_EncodingUtil.DecompressString not available"
	end
	if not C_EncodingUtil.DecodeBase64 then
		return nil, "C_EncodingUtil.DecodeBase64 not available"
	end

	-- Validate we have data
	if not encoded or encoded == "" then
		return nil, "Empty message"
	end

	-- Step 1: Decode Base64 to get compressed binary
	local compressed = C_EncodingUtil.DecodeBase64(encoded)
	if not compressed or compressed == "" then
		return nil, "Base64 decoding failed"
	end

	-- Step 2: Decompress to get CBOR binary
	local decompressed = C_EncodingUtil.DecompressString(compressed, Enum.CompressionMethod.Deflate)

	if not decompressed or decompressed == "" then
		return nil, "Deflate decompression failed"
	end

	-- Step 3: Deserialize CBOR to get Lua table
	local data = C_EncodingUtil.DeserializeCBOR(decompressed)
	if data == nil then
		return nil, "CBOR deserialization failed"
	end

	return data, nil
end

--- Get codec statistics for debugging
--- @return table stats Statistics about encoding/decoding
function MessageCodec.GetStats()
	return {
		features = {
			cbor = (C_EncodingUtil and C_EncodingUtil.SerializeCBOR) ~= nil,
			compression = (C_EncodingUtil and C_EncodingUtil.CompressString) ~= nil,
		},
	}
end

--- Estimate encoded size without actually encoding
--- Useful for detecting potential message size issues
--- @param data any The data to estimate
--- @return number|nil estimatedSize Size estimate in bytes, or nil if unavailable
function MessageCodec.EstimateSize(data)
	-- We can't get exact size without encoding, but we can provide a rough estimate
	-- For testing/debug purposes, just encode and return actual size
	local encoded, err = MessageCodec.Encode(data)
	if not encoded then
		return nil
	end
	return #encoded
end
