--!strict
-- Pure-Luau JSON decoder. No host (tern) dependencies, so unit tests can run
-- on the plain `luau` CLI. Decode-only: the plugin encodes through tern.json.

local Json = {}

local MAX_DEPTH = 100

local ESCAPES: { [string]: string } = {
	['"'] = '"',
	["\\"] = "\\",
	["/"] = "/",
	b = "\b",
	f = "\f",
	n = "\n",
	r = "\r",
	t = "\t",
}

-- UTF-8 encode of one code point (callers pass <= 0x10FFFF).
local function utf8_enc(cp: number): string
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(bit32.bor(0xC0, bit32.rshift(cp, 6)), bit32.bor(0x80, bit32.band(cp, 0x3F)))
	elseif cp < 0x10000 then
		return string.char(
			bit32.bor(0xE0, bit32.rshift(cp, 12)),
			bit32.bor(0x80, bit32.band(bit32.rshift(cp, 6), 0x3F)),
			bit32.bor(0x80, bit32.band(cp, 0x3F))
		)
	end
	return string.char(
		bit32.bor(0xF0, bit32.rshift(cp, 18)),
		bit32.bor(0x80, bit32.band(bit32.rshift(cp, 12), 0x3F)),
		bit32.bor(0x80, bit32.band(bit32.rshift(cp, 6), 0x3F)),
		bit32.bor(0x80, bit32.band(cp, 0x3F))
	)
end

--- Decodes one JSON document. Returns (value, nil) or (nil, reason).
--- Trailing non-whitespace after the document is an error.
function Json.decode(text: string): (any?, string?)
	local s = text
	local n = #s
	local i = 1
	local depth = 0

	local function fail(msg: string): (nil, string)
		return nil, msg
	end

	local function skip_ws()
		while i <= n do
			local b = string.byte(s, i)
			if b == 32 or b == 9 or b == 10 or b == 13 then
				i += 1
			else
				break
			end
		end
	end

	local function peek(): number?
		if i > n then
			return nil
		end
		return string.byte(s, i)
	end

	-- \uXXXX at `at` (the backslash is at at, the u at at+1).
	local function hex_escape(at: number): (number?, number?, string?)
		if at + 5 > n then
			return nil, nil, "truncated \\u escape"
		end
		local cp = tonumber(string.sub(s, at + 2, at + 5), 16)
		if cp == nil then
			return nil, nil, "bad \\u escape"
		end
		return cp, at + 6, nil
	end

	local function string_body(): (string?, string?)
		-- i sits on the opening quote.
		local j = i + 1
		local parts: { string } = {}
		local chunk_start = j
		while j <= n do
			local b = string.byte(s, j)
			if b == 34 then -- '"'
				if j > chunk_start then
					table.insert(parts, string.sub(s, chunk_start, j - 1))
				end
				i = j + 1
				return table.concat(parts), nil
			elseif b == 92 then -- '\'
				if j > chunk_start then
					table.insert(parts, string.sub(s, chunk_start, j - 1))
				end
				local e = string.sub(s, j + 1, j + 1)
				if e == "" then
					return fail("unterminated string")
				end
				local simple = ESCAPES[e]
				if simple then
					table.insert(parts, simple)
					j += 2
				elseif e == "u" then
					local cp, after, err = hex_escape(j)
					if cp == nil then
						return fail(err :: string)
					end
					j = after :: number
					-- Surrogate pair: high followed by low combines into one point.
					if cp >= 0xD800 and cp <= 0xDBFF then
						if string.sub(s, j, j + 1) == "\\u" then
							local lo, after2, err2 = hex_escape(j)
							if lo == nil then
								return fail(err2 :: string)
							end
							if lo >= 0xDC00 and lo <= 0xDFFF then
								cp = 0x10000 + bit32.lshift(cp - 0xD800, 10) + (lo - 0xDC00)
								j = after2 :: number
							end
						end
					end
					table.insert(parts, utf8_enc(cp))
				else
					return fail("bad escape \\" .. e)
				end
				chunk_start = j
			else
				j += 1
			end
		end
		return fail("unterminated string")
	end

	local function number_body(): (number?, string?)
		local start = i
		if string.byte(s, i) == string.byte("-") then
			i += 1
		end
		while i <= n do
			local b = string.byte(s, i)
			if (b >= 48 and b <= 57) or b == 43 or b == 45 or b == 46 or b == 101 or b == 69 then
				i += 1
			else
				break
			end
		end
		local body = string.sub(s, start, i - 1)
		local value = tonumber(body)
		if value == nil then
			return fail("bad number " .. body)
		end
		return value, nil
	end

	local parse_value: () -> (any?, string?)

	local function object_body(): ({ [string]: any }?, string?)
		i += 1 -- '{'
		local out: { [string]: any } = {}
		skip_ws()
		if peek() == 125 then -- '}'
			i += 1
			return out, nil
		end
		while true do
			skip_ws()
			if peek() ~= 34 then
				return fail("expected string key")
			end
			local key, err = string_body()
			if key == nil then
				return nil, err
			end
			skip_ws()
			if peek() ~= 58 then -- ':'
				return fail("expected :")
			end
			i += 1
			local value, verr = parse_value()
			if verr ~= nil then
				return nil, verr
			end
			out[key] = value
			skip_ws()
			local b = peek()
			if b == 44 then -- ','
				i += 1
			elseif b == 125 then -- '}'
				i += 1
				return out, nil
			else
				return fail("expected , or }")
			end
		end
	end

	local function array_body(): ({ any }?, string?)
		i += 1 -- '['
		local out: { any } = {}
		skip_ws()
		if peek() == 93 then -- ']'
			i += 1
			return out, nil
		end
		while true do
			local value, err = parse_value()
			if err ~= nil then
				return nil, err
			end
			table.insert(out, value)
			skip_ws()
			local b = peek()
			if b == 44 then -- ','
				i += 1
			elseif b == 93 then -- ']'
				i += 1
				return out, nil
			else
				return fail("expected , or ]")
			end
		end
	end

	parse_value = function(): (any?, string?)
		skip_ws()
		local b = peek()
		if b == nil then
			return fail("unexpected end of input")
		end
		depth += 1
		if depth > MAX_DEPTH then
			depth -= 1
			return fail("nesting too deep")
		end
		local result: any, err: string?
		if b == 123 then -- '{'
			result, err = object_body()
		elseif b == 91 then -- '['
			result, err = array_body()
		elseif b == 34 then -- '"'
			result, err = string_body()
		elseif b == 116 then -- 't'
			if string.sub(s, i, i + 3) == "true" then
				i += 4
				result = true
			else
				err = "bad literal"
			end
		elseif b == 102 then -- 'f'
			if string.sub(s, i, i + 4) == "false" then
				i += 5
				result = false
			else
				err = "bad literal"
			end
		elseif b == 110 then -- 'n'
			if string.sub(s, i, i + 3) == "null" then
				i += 4
				result = nil
			else
				err = "bad literal"
			end
		else
			result, err = number_body()
		end
		depth -= 1
		if err ~= nil then
			return nil, err
		end
		return result, nil
	end

	local value, err = parse_value()
	if err ~= nil then
		return nil, err
	end
	skip_ws()
	if i <= n then
		return nil, "trailing content"
	end
	return value, nil
end

return Json
