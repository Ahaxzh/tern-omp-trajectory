--!strict
-- omp session JSONL entry parser. Pure Luau, no host (tern) dependencies:
-- input is an array of raw lines, output is normalized entries. Tolerates
-- bad lines (counted, skipped) and unknown entry types (kept as system rows
-- so nothing written by future omp versions is silently dropped).

local Json = require("./json")

local Parse = {}

-- Display kinds; `usage` entries (omp auxiliary model calls) carry stats but
-- render no ledger row.
export type Kind = "user" | "assistant" | "tool" | "compaction" | "system" | "usage"

export type Usage = {
	input: number,
	output: number,
	cache_read: number,
	cache_write: number,
	total: number,
	reasoning: number?,
	cost: number?,
}

export type Entry = {
	kind: Kind,
	-- Stable id for view keys and expansion: the entry's own id, a tool call
	-- id, or a synthesized one for id-less lines (title, session).
	id: string,
	ts: number?, -- epoch ms
	-- user / assistant
	text: string?,
	thinking: string?,
	model: string?,
	provider: string?,
	stop: string?,
	ttft: number?, -- ms to first token
	duration: number?, -- ms of the model turn
	usage: Usage?,
	epoch: number?, -- omp compaction epoch (contextSnapshot.compactionEpoch)
	-- tool rows
	call_id: string?,
	tool: string?,
	intent: string?,
	args: any?,
	result: string?,
	is_error: boolean?,
	wall_ms: number?, -- toolResult details.wallTimeMs
	pending: boolean?, -- started but no result seen yet
	-- system rows
	sys_kind: string?, -- "session" | "title" | "model" | "digest" | ...
	sys_detail: string?,
	aux: boolean?, -- auxiliary (non-assistant) model call
	raw: any, -- the decoded line, for the inspector
}

export type Meta = {
	id: string?,
	cwd: string?,
	title: string?,
	model: string?,
	digest: string?,
}

export type Parsed = {
	entries: { Entry },
	by_call: { [string]: Entry },
	bad: number, -- undecodable lines
	meta: Meta,
}

---------------------------------------------------------------------
-- Timestamps
---------------------------------------------------------------------

-- Seconds between local time and UTC, computed once.
local tz_offset: number? = nil

local function tz(): number
	if tz_offset == nil then
		local lt = os.date("*t") :: any
		local ut = os.date("!*t") :: any
		tz_offset = os.time(lt) - os.time(ut)
	end
	return tz_offset :: number
end

--- "2026-10-19T07:04:07.366Z" (or with an offset) -> epoch milliseconds.
function Parse.iso_ms(s: string): number?
	local y, mo, d, h, mi, sec, frac =
		string.match(s, "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)")
	if y == nil then
		return nil
	end
	local base = os.time({
		year = tonumber(y) :: number,
		month = tonumber(mo) :: number,
		day = tonumber(d) :: number,
		hour = tonumber(h) :: number,
		min = tonumber(mi) :: number,
		sec = tonumber(sec) :: number,
	})
	local ms = 0
	if frac ~= nil and frac ~= "" then
		ms = tonumber(string.sub(frac .. "000", 1, 3)) :: number
	end
	return (base - tz()) * 1000 + ms
end

local function epoch_ms(n: any): number?
	if type(n) == "number" and n > 1e12 then
		-- Already milliseconds.
		return n
	elseif type(n) == "number" then
		return n * 1000
	end
	return nil
end

---------------------------------------------------------------------
-- Field extraction
---------------------------------------------------------------------

local function first_text(blocks: any): string?
	if type(blocks) ~= "table" then
		return nil
	end
	local out: { string } = {}
	for _, block in blocks :: { any } do
		if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
			table.insert(out, block.text :: string)
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, "\n")
end

local function concat_thinking(blocks: any): string?
	if type(blocks) ~= "table" then
		return nil
	end
	local out: { string } = {}
	for _, block in blocks :: { any } do
		if type(block) == "table" and block.type == "thinking" and type(block.thinking) == "string" then
			table.insert(out, block.thinking :: string)
		end
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out, "\n")
end

local function usage_of(m: any): Usage?
	local u = m.usage
	if type(u) ~= "table" then
		return nil
	end
	local cost = nil
	if type(u.cost) == "table" and type((u.cost :: any).total) == "number" then
		cost = (u.cost :: any).total
	end
	local function num(v: any): number
		return if type(v) == "number" then v else 0
	end
	return {
		input = num(u.input),
		output = num(u.output),
		cache_read = num(u.cacheRead),
		cache_write = num(u.cacheWrite),
		total = num(u.totalTokens),
		reasoning = if type(u.reasoningTokens) == "number" then u.reasoningTokens else nil,
		cost = cost,
	}
end

local function clean(s: string?): string?
	if s == nil then
		return nil
	end
	local t = (s :: string):gsub("^%s+", ""):gsub("%s+$", "")
	local out = t
	return if out == "" then nil else out
end

---------------------------------------------------------------------
-- Line -> entries
---------------------------------------------------------------------

local function sys(seq: number, kind: string, detail: string?, ts: number?, raw: any): Entry
	return {
		kind = "system",
		id = "sys" .. tostring(seq),
		ts = ts,
		sys_kind = kind,
		sys_detail = detail,
		raw = raw,
	}
end

-- One input line -> zero or more entries (assistant lines also emit one tool
-- entry per toolCall block). `prev_epoch` carries the compaction epoch across
-- lines; an increase inserts a compaction entry before the assistant row.
-- Returns (entries, new_epoch).
function Parse.line(line: string, seq: number, prev_epoch: number?, raw_keep: boolean?): ({ Entry }, number?)
	local obj = Json.decode(line)
	if obj == nil or type(obj) ~= "table" then
		-- Undecodable: the caller's pcall counts this line as bad.
		error("undecodable line")
	end
	local o = obj :: any
	local t = o.type
	local ts = if type(o.timestamp) == "string" then Parse.iso_ms(o.timestamp) else epoch_ms(o.timestamp)
	local out: { Entry } = {}

	local function base(kind: Kind, id: any): Entry
		return {
			kind = kind,
			id = if type(id) == "string" and id ~= "" then id else "x" .. tostring(seq),
			ts = ts,
			raw = if raw_keep ~= false then o else nil,
		} :: Entry
	end

	if t == "session" then
		local e = base("system", o.id)
		e.sys_kind = "session"
		e.sys_detail = clean(type(o.cwd) == "string" and o.cwd or nil)
		table.insert(out, e)
	elseif t == "message" then
		local m = o.message
		if type(m) ~= "table" then
			return {}, prev_epoch
		end
		local role = m.role
		if role == "user" then
			local e = base("user", o.id)
			e.text = first_text(m.content)
			table.insert(out, e)
		elseif role == "assistant" then
			local epoch = nil
			if type(m.contextSnapshot) == "table" and type(m.contextSnapshot.compactionEpoch) == "number" then
				epoch = m.contextSnapshot.compactionEpoch
				if prev_epoch ~= nil and (epoch :: number) > prev_epoch then
					local c = base("compaction", nil)
					c.sys_kind = "compaction"
					c.sys_detail = string.format("context compacted (epoch %d)", epoch :: number)
					table.insert(out, c)
				end
			end
			local e = base("assistant", o.id)
			e.text = first_text(m.content)
			e.thinking = concat_thinking(m.content)
			e.model = clean(type(m.model) == "string" and m.model or nil)
			e.provider = clean(type(m.provider) == "string" and m.provider or nil)
			e.stop = clean(type(m.stopReason) == "string" and m.stopReason or nil)
			e.ttft = if type(m.ttft) == "number" then m.ttft else nil
			e.duration = if type(m.duration) == "number" then m.duration else nil
			e.usage = usage_of(m)
			e.epoch = epoch
			table.insert(out, e)
			-- Each toolCall block becomes its own ledger row, merged later
			-- with its tool_execution_start / toolResult lines.
			if type(m.content) == "table" then
				for _, block in m.content :: { any } do
					if type(block) == "table" and block.type == "toolCall" then
						local te = base("tool", if type(block.id) == "string" then block.id else nil)
						te.call_id = te.id
						te.tool = clean(type(block.name) == "string" and block.name or nil)
						te.args = if block.arguments ~= nil then block.arguments else nil
						te.intent = clean(type(block.intent) == "string" and block.intent or nil)
						te.pending = true
						table.insert(out, te)
					end
				end
			end
			return out, if epoch ~= nil then epoch else prev_epoch
		elseif role == "toolResult" then
			local call_id = if type(m.toolCallId) == "string" then m.toolCallId else nil
			if call_id == nil then
				return {}, prev_epoch
			end
			-- Marked so the session assembler can merge into an existing row.
			local e = base("tool", nil)
			e.call_id = call_id
			e.sys_kind = "merge"
			e.tool = clean(type(m.toolName) == "string" and m.toolName or nil)
			-- Result text: concat of text blocks (images skipped).
			local parts: { string } = {}
			if type(m.content) == "table" then
				for _, block in m.content :: { any } do
					if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
						table.insert(parts, block.text :: string)
					end
				end
			end
			e.result = if #parts > 0 then table.concat(parts, "\n") else nil
			e.is_error = if m.isError == true then true else nil
			if type(m.details) == "table" and type(m.details.wallTimeMs) == "number" then
				e.wall_ms = m.details.wallTimeMs
			end
			-- The inspector keeps the full original entry.
			table.insert(out, e)
		else
			local e = base("system", o.id)
			e.sys_kind = "message:" .. tostring(role)
			table.insert(out, e)
		end
	elseif t == "custom" then
		local ct = tostring(o.customType)
		if ct == "tool_execution_start" then
			local d = o.data
			if type(d) ~= "table" then
				return {}, prev_epoch
			end
			local call_id = if type(d.toolCallId) == "string" then d.toolCallId else nil
			if call_id == nil then
				return {}, prev_epoch
			end
			local e = base("tool", nil)
			e.call_id = call_id
			e.sys_kind = "merge"
			e.tool = clean(type(d.toolName) == "string" and d.toolName or nil)
			e.intent = clean(type(d.intent) == "string" and d.intent or nil)
			e.args = if d.args ~= nil then d.args else nil
			if type(d.startedAt) == "string" then
				e.ts = Parse.iso_ms(d.startedAt)
			end
			table.insert(out, e)
		elseif ct == "system-prompt-digest" then
			local detail = if type(o.data) == "string" then o.data else nil
			table.insert(out, sys(seq, "digest", detail, ts, o))
		else
			local detail = if ct == "session_exit" and type(o.data) == "table"
				then tostring((o.data :: any).reason)
				else nil
			table.insert(out, sys(seq, ct, detail, ts, o))
		end
	elseif t == "model_usage" then
		local e = base("usage", o.id)
		e.model = clean(type(o.model) == "string" and o.model or nil)
		e.provider = clean(type(o.provider) == "string" and o.provider or nil)
		e.usage = usage_of(o)
		e.aux = true
		e.sys_detail = clean(type(o.purpose) == "string" and o.purpose or nil)
		table.insert(out, e)
	elseif t == "title" or t == "title_change" then
		local e = base("system", if t == "title_change" then o.id else nil)
		e.sys_kind = "title"
		e.sys_detail = clean(type(o.title) == "string" and o.title or nil)
		if ts == nil and type(o.updatedAt) == "string" then
			e.ts = Parse.iso_ms(o.updatedAt)
		end
		table.insert(out, e)
	elseif t == "model_change" then
		table.insert(out, sys(seq, "model", clean(type(o.model) == "string" and o.model or nil), ts, o))
	elseif t == "mode_change" then
		table.insert(out, sys(seq, "mode", clean(type(o.mode) == "string" and o.mode or nil), ts, o))
	elseif t == "thinking_level_change" then
		table.insert(
			out,
			sys(
				seq,
				"thinking",
				clean(type(o.thinkingLevel) == "string" and o.thinkingLevel or nil),
				ts,
				o
			)
		)
	elseif t == "service_tier_change" then
		table.insert(
			out,
			sys(
				seq,
				"tier",
				clean(type(o.serviceTier) == "string" and o.serviceTier or nil),
				ts,
				o
			)
		)
	elseif t == "custom_message" then
		local e = base("system", o.id)
		e.sys_kind = clean(tostring(o.customType))
		e.sys_detail = clean(if type(o.content) == "string" then o.content else nil)
		table.insert(out, e)
	else
		-- Unknown future entry type: keep it visible as a system row.
		table.insert(out, sys(seq, tostring(t), nil, ts, o))
	end
	return out, prev_epoch
end

---------------------------------------------------------------------
-- Incremental assembly (budget-friendly batching)
---------------------------------------------------------------------

local function merge_tool(target: Entry, patch: Entry)
	if patch.tool ~= nil and target.tool == nil then
		target.tool = patch.tool
	end
	if patch.intent ~= nil and target.intent == nil then
		target.intent = patch.intent
	end
	if patch.args ~= nil and target.args == nil then
		target.args = patch.args
	end
	if patch.ts ~= nil and target.ts == nil then
		target.ts = patch.ts
	end
	if patch.result ~= nil then
		target.result = patch.result
		target.pending = false
		target.raw = patch.raw -- result entry is the richer inspector payload
	end
	if patch.is_error == true then
		target.is_error = true
	end
	if patch.wall_ms ~= nil then
		target.wall_ms = patch.wall_ms
	end
end

--- Accumulator for parsing lines across multiple small callbacks (each
--- callback stays far under the worker budget). Equivalent to Parse.lines.
export type Acc = {
	entries: { Entry },
	by_call: { [string]: Entry },
	bad: number,
	meta: Meta,
	seq: number,
	prev_epoch: number?,
}

function Parse.acc(): Acc
	return { entries = {}, by_call = {}, bad = 0, meta = {}, seq = 0, prev_epoch = nil }
end

function Parse.push(acc: Acc, line: string)
	if #string.gsub(line, "%s", "") == 0 then
		return
	end
	acc.seq += 1
	local ok, added, new_epoch = pcall(Parse.line, line, acc.seq, acc.prev_epoch)
	if not ok then
		acc.bad += 1
		return
	end
	acc.prev_epoch = new_epoch
	for _, e in added :: { Entry } do
		Parse.absorb(acc, e)
	end
end

function Parse.absorb(acc: Acc, e: Entry)
	if e.kind == "tool" and e.call_id ~= nil then
		if e.sys_kind == "merge" then
			local existing = acc.by_call[e.call_id :: string]
			if existing then
				merge_tool(existing, e)
				return
			end
			e.pending = false
			acc.by_call[e.call_id :: string] = e
			table.insert(acc.entries, e)
			return
		end
		local existing = acc.by_call[e.call_id :: string]
		if existing then
			merge_tool(existing, e)
			return
		end
		acc.by_call[e.call_id :: string] = e
	end
	if e.sys_kind == "session" then
		acc.meta.id = e.id
		acc.meta.cwd = e.sys_detail
	elseif e.sys_kind == "title" and acc.meta.title == nil and e.sys_detail ~= nil then
		acc.meta.title = e.sys_detail
	elseif e.kind == "assistant" and acc.meta.model == nil and e.model ~= nil then
		acc.meta.model = e.model
	elseif e.sys_kind == "digest" and e.sys_detail ~= nil then
		acc.meta.digest = e.sys_detail
	end
	table.insert(acc.entries, e)
end

function Parse.finish(acc: Acc): Parsed
	return { entries = acc.entries, by_call = acc.by_call, bad = acc.bad, meta = acc.meta }
end

---------------------------------------------------------------------
-- Whole-session assembly
---------------------------------------------------------------------

--- Parses an array of raw JSONL lines into a session.
function Parse.lines(lines: { string }): Parsed
	local acc = Parse.acc()
	for _, line in lines do
		Parse.push(acc, line)
	end
	return Parse.finish(acc)
end

--- Splits raw file text into JSONL lines (tolerates a missing final newline
--- and stray \r\n).
function Parse.split(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "([^\r\n]*)\r?\n") do
		table.insert(out, line)
	end
	-- gmatch drops a trailing segment without a newline.
	local last_start = #text
	while last_start > 0 do
		local b = string.byte(text, last_start)
		if b == 10 or b == 13 then
			break
		end
		last_start -= 1
	end
	if last_start < #text then
		table.insert(out, string.sub(text, last_start + 1))
	end
	return out
end

return Parse
