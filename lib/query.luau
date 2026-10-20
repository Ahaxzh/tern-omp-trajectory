--!strict
-- Session queries over parsed entries: round grouping, tail pagination,
-- stats, spark series, row filtering and formatting helpers. Pure Luau.

local Parse = require("./parse")

local Query = {}

export type Entry = Parse.Entry
export type Round = {
	index: number, -- 1-based round number (0 = before the first user turn)
	title: string?, -- first user text of the round
	start_ts: number?,
	end_ts: number?,
	entries: { Entry },
}

--- Groups entries into rounds: a round begins at each user entry; anything
--- before the first user entry forms round 0 (prologue).
function Query.rounds(entries: { Entry }): { Round }
	local rounds: { Round } = {}
	local current: Round? = nil
	local function ensure(): Round
		local c = current
		if c == nil then
			local made: Round = { index = #rounds, entries = {} }
			table.insert(rounds, made)
			current = made
			return made
		end
		return c
	end
	for _, e in entries do
		if e.kind == "user" then
			current = {
				index = math.max(1, #rounds),
				title = e.text,
				start_ts = e.ts,
				entries = { e },
			}
			table.insert(rounds, current :: Round)
		else
			local c = ensure()
			table.insert(c.entries, e)
		end
		local c = current
		if c ~= nil then
			c.end_ts = e.ts
		end
	end
	for _, r in rounds do
		if r.index == 0 then
			r.title = "(before first prompt)"
		end
	end
	return rounds
end

--- The tail window: last `max` rounds (round 0 counts only when the whole
--- session has no user rounds). Returns the first index into `rounds`.
function Query.tail_from(rounds: { Round }, max: number): number
	local user_rounds = 0
	for _, r in rounds do
		if r.index > 0 then
			user_rounds += 1
		end
	end
	if user_rounds <= max then
		return 1
	end
	-- Skip round 0 plus (user_rounds - max) numbered rounds.
	return 1 + (user_rounds - max) + (if rounds[1] and rounds[1].index == 0 then 1 else 0)
end

export type Stats = {
	rounds: number, -- user rounds
	requests: number, -- assistant model calls
	tokens: number, -- sum of assistant totalTokens
	cost: number, -- sum of assistant cost.total
	aux_calls: number, -- auxiliary model_usage entries
	aux_tokens: number,
	model: string?,
	first_ctx: number?, -- totalTokens of first assistant call
	last_ctx: number?,
	spark: { { any } }, -- per assistant call totalTokens: positional {label, value}
}

function Query.stats(entries: { Entry }, total_rounds: number): Stats
	local s: Stats = {
		rounds = total_rounds,
		requests = 0,
		tokens = 0,
		cost = 0,
		aux_calls = 0,
		aux_tokens = 0,
		spark = {},
	}
	local n = 0
	for _, e in entries do
		if e.kind == "assistant" and e.usage ~= nil then
			local u = e.usage :: Parse.Usage
			s.requests += 1
			s.tokens += u.total
			s.cost += (u.cost or 0)
			n += 1
			if s.first_ctx == nil then
				s.first_ctx = u.total
			end
			s.last_ctx = u.total
			-- ui.spark takes positional {label, value} pairs.
			local point: { any } = { tostring(n), u.total }
			table.insert(s.spark, point)
		elseif e.kind == "usage" and e.usage ~= nil then
			local u = e.usage :: Parse.Usage
			s.aux_calls += 1
			s.aux_tokens += u.total
		end
		if s.model == nil and e.model ~= nil then
			s.model = e.model
		end
	end
	return s
end

---------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------

function Query.clip(s: string, n: number): string
	if #s <= n then
		return s
	end
	return string.sub(s, 1, math.max(0, n - 1)) .. "…"
end

--- One-line summary of a tool args table for the ledger row.
function Query.args_summary(args: any, width: number): string
	if args == nil then
		return ""
	end
	local t = args
	if type(t) ~= "table" then
		return Query.clip(tostring(t), width)
	end
	local parts: { string } = {}
	-- Prefer the most informative keys first.
	local order: { string } = {}
	for k in t :: { any } do
		if type(k) == "string" then
			table.insert(order, k)
		end
	end
	table.sort(order, function(a: string, b: string)
		return a < b
	end)
	for _, k in order do
		local v = (t :: { [string]: any })[k]
		if type(v) == "string" then
			local one = (v :: string):gsub("%s+", " ")
			table.insert(parts, k .. "=" .. Query.clip(one, 48))
		elseif type(v) == "number" or type(v) == "boolean" then
			table.insert(parts, k .. "=" .. tostring(v))
		elseif type(v) == "table" then
			local count = 0
			for _ in (v :: { any }) do
				count += 1
			end
			table.insert(parts, k .. "[..]" .. tostring(count))
		end
		if #parts >= 3 then
			break
		end
	end
	return Query.clip(table.concat(parts, " "), width)
end

function Query.fmt_int(n: number): string
	local neg = n < 0
	local v = math.abs(math.floor(n))
	if v == 0 then
		return "0"
	end
	local parts: { string } = {}
	while v > 0 do
		table.insert(parts, 1, tostring(v % 1000))
		v = math.floor(v / 1000)
	end
	for idx = 2, #parts do
		parts[idx] = string.format("%03d", tonumber(parts[idx]) :: number)
	end
	return (if neg then "-" else "") .. table.concat(parts, ",")
end

--- 4321 -> "4.3k", 5_200_000 -> "5.2M"
function Query.fmt_tokens(n: number): string
	if n >= 1_000_000 then
		return string.format("%.1fM", n / 1_000_000)
	elseif n >= 1_000 then
		return string.format("%.1fk", n / 1_000)
	end
	return tostring(n)
end

function Query.fmt_cost(n: number): string
	if n >= 1 then
		return string.format("$%.2f", n)
	elseif n >= 0.01 then
		return string.format("$%.3f", n)
	end
	return string.format("$%.4f", n)
end

--- Milliseconds as "812ms" / "4.7s" / "2m05s" / "1h03m".
function Query.fmt_ms(ms: number?): string
	if ms == nil then
		return ""
	end
	local v = ms :: number
	if v < 1000 then
		return string.format("%dms", math.floor(v))
	elseif v < 60_000 then
		return string.format("%.1fs", v / 1000)
	elseif v < 3_600_000 then
		return string.format("%dm%02ds", math.floor(v / 60_000), math.floor((v % 60_000) / 1000))
	end
	return string.format("%dh%02dm", math.floor(v / 3_600_000), math.floor((v % 3_600_000) / 60_000))
end

--- Epoch ms -> "HH:MM" or "MM-DD HH:MM" (UTC-local of the viewer).
function Query.fmt_clock(ms: number?): string
	if ms == nil then
		return ""
	end
	local secs = math.floor((ms :: number) / 1000)
	local t = os.date("%H:%M", secs) :: string
	local d = os.date("%m%d", secs) :: string
	local today = os.date("%m%d") :: string
	if d ~= today then
		return os.date("%m-%d %H:%M", secs) :: string
	end
	return t
end

function Query.fmt_size(bytes: number): string
	if bytes >= 1_048_576 then
		return string.format("%.1fMB", bytes / 1_048_576)
	elseif bytes >= 1024 then
		return string.format("%.1fKB", bytes / 1024)
	end
	return string.format("%dB", bytes)
end

---------------------------------------------------------------------
-- Filtering
---------------------------------------------------------------------

--- Case-insensitive substring match over the row's searchable text.
function Query.entry_matches(e: Entry, needle: string?): boolean
	if needle == nil or needle == "" then
		return true
	end
	local hay: { string } = { e.kind, e.tool or "", e.intent or "", e.text or "", e.result or "" }
	if e.model ~= nil then
		table.insert(hay, e.model :: string)
	end
	if e.sys_detail ~= nil then
		table.insert(hay, e.sys_detail :: string)
	end
	if e.sys_kind ~= nil then
		table.insert(hay, e.sys_kind :: string)
	end
	if e.args ~= nil then
		local ok, summary = pcall(Query.args_summary, e.args, 400)
		if ok and summary ~= nil then
			table.insert(hay, summary :: string)
		end
	end
	local lower = string.lower(needle :: string)
	for _, h in hay do
		if string.find(string.lower(h), lower, 1, true) ~= nil then
			return true
		end
	end
	return false
end

return Query
