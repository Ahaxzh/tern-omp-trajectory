--!strict
-- Data -> node trees. No IO here: every function takes plain data and
-- returns ui nodes (uses the global `tern`, so it runs host-side only).

local Parse = require("./parse")
local Query = require("./query")

local View = {}

local ui = tern.ui

export type Entry = Parse.Entry
export type Round = Query.Round
export type Usage = Parse.Usage

export type Row = {
	row_kind: "round" | "entry",
	id: string, -- stable row id (list item key)
	round: Round?,
	entry: Entry?,
}

--- Flattens a round slice into ledger rows, honoring the active filter.
function View.build_rows(rounds: { Round }, filter: string?): { Row }
	local rows: { Row } = {}
	for _, r in rounds do
		local shown = 0
		for _, e in r.entries do
			if Query.entry_matches(e, filter) then
				shown += 1
			end
		end
		if shown == 0 and not (filter == nil or filter == "") then
			continue
		end
		table.insert(rows, {
			row_kind = "round",
			id = "r" .. tostring(r.index),
			round = r,
		})
		for _, e in r.entries do
			if e.kind ~= "usage" and Query.entry_matches(e, filter) then
				table.insert(rows, {
					row_kind = "entry",
					id = "e" .. e.id,
					entry = e,
					round = r,
				})
			end
		end
	end
	return rows
end

---------------------------------------------------------------------
-- Ledger rows
---------------------------------------------------------------------

local function kind_tone(e: Entry): string
	if e.kind == "user" then
		return "user"
	elseif e.kind == "assistant" then
		return "info"
	elseif e.kind == "compaction" then
		return "warning"
	elseif e.kind == "system" then
		return "muted"
	elseif e.is_error then
		return "error"
	elseif e.pending then
		return "pending"
	end
	return "neutral"
end

local function entry_icon(e: Entry): string?
	if e.kind == "user" then
		return "person"
	elseif e.kind == "assistant" then
		return "sparkle"
	elseif e.kind == "tool" then
		return "terminal"
	elseif e.kind == "compaction" then
		return "archive"
	elseif e.sys_kind == "title" then
		return "tag"
	elseif e.sys_kind == "model" then
		return "cpu"
	elseif e.sys_kind == "digest" then
		return "fingerprint"
	elseif e.sys_kind == "session" then
		return "history"
	end
	return nil
end

local SYS_LABELS: { [string]: string } = {
	session = "session",
	title = "title",
	model = "model",
	mode = "mode",
	thinking = "thinking level",
	tier = "service tier",
	digest = "system prompt digest",
	compaction = "compaction",
	["session_exit"] = "session exit",
}

local function entry_label(e: Entry): string
	if e.kind == "user" then
		return Query.clip(e.text or "(empty prompt)", 120)
	elseif e.kind == "assistant" then
		if e.text ~= nil and e.text ~= "" then
			return Query.clip(e.text, 120)
		elseif e.usage ~= nil then
			return "(model call, no text)"
		end
		return "(assistant)"
	elseif e.kind == "tool" then
		return e.tool or "tool"
	elseif e.kind == "compaction" then
		return e.sys_detail or "compaction"
	end
	local label = SYS_LABELS[e.sys_kind or ""] or e.sys_kind or "system"
	local detail = e.sys_detail
	if detail ~= nil and detail ~= "" then
		return label .. ": " .. Query.clip((detail :: string):gsub("%s+", " "), 100)
	end
	return label
end

local function entry_detail(e: Entry): string?
	if e.kind == "user" then
		return nil
	elseif e.kind == "assistant" then
		local parts: { string } = {}
		if e.usage ~= nil then
			local u = e.usage :: Usage
			table.insert(parts, Query.fmt_tokens(u.total) .. " tok")
		end
		if e.ttft ~= nil then
			table.insert(parts, "ttft " .. Query.fmt_ms(e.ttft))
		end
		if e.stop ~= nil then
			table.insert(parts, e.stop :: string)
		end
		if #parts == 0 then
			return nil
		end
		return table.concat(parts, " · ")
	elseif e.kind == "tool" then
		local intent = e.intent
		if intent == nil and e.args ~= nil then
			intent = Query.args_summary(e.args, 90)
		end
		if intent ~= nil and intent ~= "" then
			return Query.clip(intent, 90)
		end
		return nil
	end
	return nil
end

local function entry_value(e: Entry): string?
	if e.kind == "tool" then
		if e.is_error then
			return "error"
		elseif e.pending then
			return "running"
		elseif e.wall_ms ~= nil then
			return Query.fmt_ms(e.wall_ms)
		end
		return nil
	end
	return Query.fmt_clock(e.ts)
end

--- Builds ui.list Items for ledger rows. Selection is carried by the list's
--- `selected` prop (not by rewriting labels), so cursor moves diff as a
--- single property instead of the whole list.
function View.ledger_items(rows: { Row }): { Item }
	local items: { Item } = {}
	for _, row in rows do
		local item: Item
		if row.row_kind == "round" then
			local r = row.round :: Round
			local head = if r.index == 0 then "start" else "round " .. tostring(r.index)
			local title = (r.title or ""):gsub("%s+", " ")
			local label = head .. "  ·  " .. Query.clip(title, 72) .. "  ·  " .. tostring(#r.entries) .. " rows"
			item = { label = { ui.span(label, "strong muted") } }
		else
			local e = row.entry :: Entry
			item = {
				label = entry_label(e),
				detail = entry_detail(e),
				value = entry_value(e),
				icon = entry_icon(e),
				tone = kind_tone(e),
			}
		end
		table.insert(items, item)
	end
	return items
end

---------------------------------------------------------------------
-- Inspector
---------------------------------------------------------------------

local function kv_pairs(e: Entry): { { Spans } }
	local pairs_list: { { Spans } } = {}
	local function add(k: string, v: string?, tone: string?)
		if v == nil or v == "" then
			return
		end
		table.insert(pairs_list, { { ui.span(k, "muted") }, { ui.span(v :: string, tone) } })
	end
	if e.kind == "tool" then
		add("tool", e.tool)
		add("call id", e.call_id, "code")
		add("intent", e.intent)
		add("wall time", Query.fmt_ms(e.wall_ms), "num")
		add("status", if e.is_error then "error" elseif e.pending then "running" else "done", if e.is_error then "error" else "success")
	elseif e.kind == "assistant" then
		add("model", table.concat({ e.provider or "", e.model or "" }, "/"))
		if e.usage ~= nil then
			local u = e.usage :: Usage
			add("tokens", string.format(
				"%s total (in %s · out %s · cache read %s · write %s%s)",
				Query.fmt_int(u.total),
				Query.fmt_int(u.input),
				Query.fmt_int(u.output),
				Query.fmt_int(u.cache_read),
				Query.fmt_int(u.cache_write),
				if u.reasoning then string.format(" · reasoning %s", Query.fmt_int(u.reasoning)) else ""
			), "num")
			if u.cost ~= nil then
				add("cost", Query.fmt_cost(u.cost), "num")
			end
		end
		add("ttft", Query.fmt_ms(e.ttft), "num")
		add("duration", Query.fmt_ms(e.duration), "num")
		add("stop", e.stop)
		if e.epoch ~= nil then
			add("compaction epoch", tostring(e.epoch))
		end
	elseif e.kind == "usage" then
		add("purpose", e.sys_detail)
		add("model", e.model)
		if e.usage ~= nil then
			add("tokens", Query.fmt_int((e.usage :: Usage).total), "num")
		end
	else
		add("kind", e.sys_kind)
		add("detail", e.sys_detail)
	end
	if e.ts ~= nil then
		local t = os.date("%Y-%m-%d %H:%M:%S", math.floor((e.ts :: number) / 1000))
		add("at", t, "num")
	end
	return pairs_list
end

--- Full inspector for one entry: human fields, then the entry's complete
--- original JSON (capped) plus full-text sections.
function View.inspector(e: Entry): Node
	local parts: { Node } = {}
	local head: string
	if e.kind == "tool" then
		head = "tool · " .. (e.tool or "?")
	elseif e.kind == "user" then
		head = "user prompt"
	elseif e.kind == "assistant" then
		head = "assistant"
	elseif e.kind == "compaction" then
		head = "compaction"
	else
		head = e.sys_kind or "system"
	end

	table.insert(parts, ui.kv(kv_pairs(e)))

	if e.args ~= nil then
		local ok, encoded = pcall(tern.json.encode, e.args, true)
		table.insert(parts, ui.section("Arguments", { ui.code(if ok then encoded else Query.args_summary(e.args, 2000), "json") }))
	end
	if e.result ~= nil and e.result ~= "" then
		table.insert(parts, ui.section("Result", { ui.code(e.result :: string, "text") }))
	end
	if e.kind == "user" and e.text ~= nil then
		table.insert(parts, ui.section("Prompt", { ui.code(e.text :: string, "text") }))
	end
	if e.thinking ~= nil and e.thinking ~= "" then
		table.insert(parts, ui.section("Thinking", { ui.code(e.thinking :: string, "text") }))
	end
	if e.text ~= nil and e.text ~= "" and e.kind == "assistant" then
		table.insert(parts, ui.section("Text", { ui.md(e.text :: string) }))
	end

	if e.raw ~= nil then
		local ok, encoded = pcall(tern.json.encode, e.raw, true)
		if ok then
			local body = encoded :: string
			local note: Node? = nil
			if #body > 16000 then
				body = string.sub(body, 1, 16000)
				note = ui.overflow(#(encoded :: string) - 16000)
			end
			local section_children: { Node } = { ui.code(body, "json") }
			if note then
				table.insert(section_children, note)
			end
			table.insert(parts, ui.section("Entry JSON", section_children))
		end
	end

	return ui.card(head, parts)
end

---------------------------------------------------------------------
-- Info strip and timeline
---------------------------------------------------------------------

--- Info bar: totals plus context sparkline with first/last values.
function View.info(stats: Query.Stats, truncated: boolean, bad: number): Node
	local children: { Node } = {}
	table.insert(children, ui.kv({
		{ { ui.span("rounds", "muted") }, { ui.span(tostring(stats.rounds), "num") } },
		{ { ui.span("requests", "muted") }, { ui.span(tostring(stats.requests), "num") } },
		{ { ui.span("tokens", "muted") }, { ui.span(Query.fmt_tokens(stats.tokens), "num") } },
		{ { ui.span("cost", "muted") }, { ui.span(Query.fmt_cost(stats.cost), "num") } },
		{ { ui.span("model", "muted") }, { ui.span(stats.model or "?", "code") } },
		{
			{ ui.span("context", "muted") },
			{
				ui.span(
					if stats.first_ctx and stats.last_ctx
						then Query.fmt_tokens(stats.first_ctx :: number) .. " → " .. Query.fmt_tokens(stats.last_ctx :: number)
						else "-",
					"num"
				),
			},
		},
	}))
	if stats.aux_calls > 0 then
		table.insert(children, ui.text({
			ui.span(
				string.format("+ %d auxiliary model calls (%s tokens) not listed", stats.aux_calls, Query.fmt_tokens(stats.aux_tokens)),
				"muted"
			),
		}))
	end
	if #stats.spark >= 2 then
		table.insert(children, ui.spark(stats.spark))
	end
	local flags: { string } = {}
	if truncated then
		table.insert(flags, "truncated view — load earlier for more")
	end
	if bad > 0 then
		table.insert(flags, string.format("%d unparseable lines skipped", bad))
	end
	if #flags > 0 then
		table.insert(children, ui.text({ ui.span(table.concat(flags, " · "), "warning") }))
	end
	return ui.section("Session", children)
end

--- Timeline strip: one chip per round that has assistant usage; height is
--- encoded in tone, clicking jumps to the round.
function View.timeline(rounds: { Round }, cap: number): Node?
	local chips: { Node } = {}
	local max_tokens = 0
	type Chip = { round: number, tokens: number }
	local data: { Chip } = {}
	for _, r in rounds do
		local tokens = 0
		for _, e in r.entries do
			if e.kind == "assistant" and e.usage ~= nil then
				tokens += (e.usage :: Usage).total
			end
		end
		if tokens > 0 then
			table.insert(data, { round = r.index, tokens = tokens })
			if tokens > max_tokens then
				max_tokens = tokens
			end
		end
	end
	if #data == 0 then
		return nil
	end
	local overflow: Node? = nil
	if #data > cap then
		overflow = ui.overflow(#data - cap)
		data = table.move(data, #data - cap + 1, #data, 1, {})
	end
	for _, chip in data do
		local ratio = if max_tokens > 0 then chip.tokens / max_tokens else 0
		local tone = if ratio >= 0.66
			then "error"
			else (if ratio >= 0.33 then "warning" else "accent")
		local node = ui.badge(Query.fmt_tokens(chip.tokens), tone)
		local p: { [string]: any } = node.p or {}
		p.actions = { click = "jump=" .. tostring(chip.round) }
		p.key = "t" .. tostring(chip.round)
		node.p = p
		table.insert(chips, node)
	end
	local children: { Node } = { ui.row(chips) }
	if overflow then
		table.insert(children, overflow)
	end
	return ui.section("Timeline (tokens per round, click to jump)", children)
end

---------------------------------------------------------------------
-- Session list
---------------------------------------------------------------------

export type SessionInfo = {
	path: string,
	project: string,
	name: string, -- file name
	title: string?,
	size: number,
	mtime: number, -- epoch seconds
}

function View.session_items(sessions: { SessionInfo }): { Item }
	local items: { Item } = {}
	for _, s in sessions do
		table.insert(items, {
			label = Query.clip(s.title or s.name, 80),
			detail = Query.clip(s.project, 48),
			value = Query.fmt_size(s.size) .. " · " .. Query.fmt_clock(s.mtime * 1000),
			icon = "history",
		})
	end
	return items
end

--- Attaches stable keys and click actions to the children of a ui.list
--- node; ids ride in the action value.
function View.wire_list(listing: Node, click_prefix: string, rows: { Row }?, ids: { string }?)
	local children: { Node } = listing.c or {}
	for i, child in children do
		local p: { [string]: any } = child.p or {}
		p.key = if rows then
			rows[i].id
		else
			(if ids then ids[i] else tostring(i))
		p.actions = { click = click_prefix .. "=" .. (p.key :: string) }
		child.p = p
	end
	listing.c = children
end

export type HintPart = { t: string, s: string }

function View.hint(spans: { HintPart }): Node
	local out: { Span | string } = {}
	for _, pair in spans do
		table.insert(out, ui.span(pair.t, if pair.s ~= "" then pair.s else nil))
	end
	return ui.text(out)
end

return View
