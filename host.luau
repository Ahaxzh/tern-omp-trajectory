--!strict
-- OMP Trajectory, host half. Block `omp-trajectory.trajectory`:
-- a session picker over ~/.omp/agent/sessions plus a trajectory ledger for
-- one session JSONL (round-grouped call flow, inspectors, timeline).
-- All file IO is async (process callbacks); handlers stay inside the 2s
-- worker budget. State lives in the block; persistence via save/tern.kv.

local Parse = require("./lib/parse")
local Query = require("./lib/query")
local View = require("./lib/view")

type Entry = Parse.Entry
type Round = Query.Round
type Row = View.Row
type SessionInfo = View.SessionInfo

local ui = tern.ui

local SESSIONS_DIR = (tern.getenv("HOME") or "") .. "/.omp/agent/sessions"
local CHUNK_BYTES = 1024 * 1024 -- tail window parsed at open / per page
local TAIL_ROUNDS = 50 -- rounds shown initially
local WATCH_MS = 60 * 1000 -- active-session refresh interval
local TIMELINE_CAP = 32 -- chips in the timeline strip

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------

type Mode = "list" | "view"

type State = {
	mode: Mode,
	-- session list
	sessions: { SessionInfo },
	listing: boolean,
	sel_list: number,
	preselect: string?, -- kv "last" path to highlight once listed
	-- session view
	path: string?,
	error: string?,
	loading: boolean,
	entries: { Entry },
	rounds: { Round },
	bad: number,
	win_from: number, -- first round index (1-based) of the visible window
	sel: number, -- row index into rows
	open_id: string?, -- expanded entry id
	follow: boolean, -- cursor pinned to the last row
	filter: string?, -- applied filter
	filter_edit: boolean,
	filter_buf: string,
	file_size: number,
	stream_upto: number, -- byte offset after the last complete parsed line
	loaded_from: number, -- first byte offset of loaded data (1-based)
	truncated: boolean,
	stats: Query.Stats?,
	-- derived per render
	rows: { Row },
	newest_path: string?,
	parse_token: number, -- bumps per parse chain; stale chains abort
}

local function fresh(): State
	return {
		mode = "list",
		sessions = {},
		listing = true,
		sel_list = 1,
		preselect = tern.kv.get("last"),
		path = nil,
		error = nil,
		loading = false,
		entries = {},
		rounds = {},
		bad = 0,
		win_from = 1,
		sel = 1,
		open_id = nil,
		follow = true,
		filter = nil,
		filter_edit = false,
		filter_buf = "",
		file_size = 0,
		stream_upto = 0,
		loaded_from = 1,
		truncated = false,
		stats = nil,
		rows = {},
		newest_path = nil,
		parse_token = 0,
	}
end

-- Open blocks by pane. Background callbacks mutate through this registry.
type Reg = { cx: BlockCx, st: State, watch: TimerHandle? }
local reg: { [number]: Reg } = {}

local function alive(pane: number): boolean
	for _, info in tern.pane.list() do
		if info.pane == pane then
			return true
		end
	end
	return false
end

local function drop_reg(pane: number)
	local r = reg[pane]
	if r and r.watch then
		(r.watch :: TimerHandle):cancel()
	end
	reg[pane] = nil
end

local function render(pane: number)
	local r = reg[pane]
	if r then
		r.cx:render()
	end
end

---------------------------------------------------------------------
-- Session listing (one python3 spawn; titles from the file heads)
---------------------------------------------------------------------

local LIST_PY = [[
import os, sys, json, glob
base = os.path.expanduser("~/.omp/agent/sessions")
out = []
if os.path.isdir(base):
    for proj in sorted(os.listdir(base)):
        d = os.path.join(base, proj)
        if not os.path.isdir(d):
            continue
        for f in sorted(glob.glob(os.path.join(d, "*.jsonl"))):
            try:
                s = os.stat(f)
            except OSError:
                continue
            title = ""
            try:
                with open(f, "rb") as fh:
                    head = fh.read(65536).decode("utf-8", "ignore")
                for ln in head.splitlines():
                    try:
                        o = json.loads(ln)
                    except Exception:
                        continue
                    if o.get("type") == "title":
                        title = str(o.get("title", ""))
                        break
            except OSError:
                pass
            out.append({"path": f, "project": os.path.basename(d),
                        "name": os.path.basename(f), "size": s.st_size,
                        "mtime": int(s.st_mtime), "title": title})
out.sort(key=lambda x: -x["mtime"])
sys.stdout.write(json.dumps(out))
]]

local function start_listing(pane: number)
	local r = reg[pane]
	if r == nil then
		return
	end
	r.st.listing = true
	tern.process.run({ "python3", "-c", LIST_PY }, { timeout_ms = 10000 }, function(res)
		local r = reg[pane]
		if r == nil then
			return
		end
		local st = r.st
		st.listing = false
		if res.status ~= 0 then
			st.error = "session listing failed: "
				.. (if res.stderr ~= "" then res.stderr else "exit " .. tostring(res.status))
			render(pane)
			return
		end
		local ok, data = pcall(tern.json.decode, res.stdout)
		if not ok or type(data) ~= "table" then
			st.error = "session listing unreadable"
			render(pane)
			return
		end
		local sessions: { SessionInfo } = tern.json.array({})
		for _, item in data :: { any } do
			if type(item) == "table" and type((item :: any).path) == "string" then
				local it = item :: any
				table.insert(sessions, {
					path = it.path,
					project = tostring(it.project or ""),
					name = tostring(it.name or ""),
					title = if type(it.title) == "string" and it.title ~= "" then it.title else nil,
					size = tonumber(it.size) or 0,
					mtime = tonumber(it.mtime) or 0,
				})
			end
		end
		st.sessions = sessions
		st.error = nil
		if #sessions > 0 then
			st.newest_path = sessions[1].path
		end
		if st.preselect ~= nil then
			for i, s in sessions do
				if s.path == st.preselect then
					st.sel_list = i
					break
				end
			end
			st.preselect = nil
		end
		st.sel_list = math.clamp(st.sel_list, 1, math.max(1, #sessions))
		render(pane)
	end)
end

---------------------------------------------------------------------
-- Session loading (chunked, tail-first)
---------------------------------------------------------------------

local schedule_watch -- forward: open_session re-arms the watcher

local function stat_size(pane: number, path: string, cb: (number?) -> ())
	tern.process.run({ "wc", "-c", path }, { timeout_ms = 5000 }, function(res)
		if reg[pane] == nil then
			return
		end
		local n = tonumber((string.gsub(res.stdout, "^%s*(%d+).*", "%1")))
		cb(if res.status == 0 then n else nil)
	end)
end

--- Byte offset of the last newline in `text` (0 when none).
local function last_newline(text: string): number
	local i = #text
	while i > 0 do
		if string.byte(text, i) == 10 then
			return i
		end
		i -= 1
	end
	return 0
end

local function round_count(st: State): number
	local n = 0
	for _, r in st.rounds do
		if r.index > 0 then
			n += 1
		end
	end
	return n
end

local PARSE_BATCH = 120 -- lines per chained callback (~25 ms; the 2 s budget
-- is wall-clock and one contended spike once disabled the whole hook, so
-- every callback stays small by construction)

--- Parses `text` in small chained callbacks, then applies it to the state.
--- Stale chains (a newer open/reload) abort themselves via parse_token.
local function start_parse(
	pane: number,
	text: string,
	base_byte: number,
	mode: "replace" | "prepend",
	pin_tail: boolean?
)
	local r = reg[pane]
	if r == nil then
		return
	end
	local st = r.st
	local lines = Parse.split(text)
	local acc = Parse.acc()
	local anchor_id: string? = nil
	if mode == "prepend" then
		local anchor = st.rows[st.sel]
		anchor_id = if anchor then anchor.id else nil
	end
	st.parse_token += 1
	local token = st.parse_token
	local pos = 0

	local function finish()
		local r = reg[pane]
		if r == nil or r.st.parse_token ~= token then
			return
		end
		local st = r.st
		local f0 = tern.now()
		local parsed = Parse.finish(acc)
		local f1 = tern.now()
		if mode == "replace" then
			st.entries = parsed.entries
			st.bad = parsed.bad
			st.rounds = Query.rounds(st.entries)
			st.win_from = Query.tail_from(st.rounds, TAIL_ROUNDS)
			st.stats = Query.stats(st.entries, round_count(st))
			st.follow = true
		else
			local rounds_before2 = #st.rounds
			local merged: { Entry } = tern.json.array({})
			for _, e in parsed.entries do
				table.insert(merged, e)
			end
			for _, e in st.entries do
				table.insert(merged, e)
			end
			st.entries = merged
			st.bad += parsed.bad
			local f2 = tern.now()
			st.rounds = Query.rounds(st.entries)
			local f3 = tern.now()
			if pin_tail and st.follow then
				st.win_from = Query.tail_from(st.rounds, TAIL_ROUNDS)
			else
				st.win_from = math.max(1, st.win_from + (#st.rounds - rounds_before2))
			end
			st.stats = Query.stats(st.entries, round_count(st))
			local f4 = tern.now()
			local win: { Round } = {}
			for i = st.win_from, #st.rounds do
				table.insert(win, st.rounds[i])
			end
			st.rows = View.build_rows(win, st.filter)
			local f5 = tern.now()
			tern.log.warn(
				"probe finish",
				mode,
				math.floor((f1 - f0) * 1),
				math.floor(f2 - f1),
				math.floor(f3 - f2),
				math.floor(f4 - f3),
				math.floor(f5 - f4),
				"ms"
			)
			if st.follow then
				st.sel = #st.rows
			elseif anchor_id ~= nil then
				st.sel = 1
				for i, row in st.rows do
					if row.id == anchor_id then
						st.sel = i
						break
					end
				end
			end
		end
		-- Byte offset after the last complete line (a trailing partial line
		-- is reparsed on the next watch tick).
		st.stream_upto = (base_byte - 1) + last_newline(text)
		st.loading = false
		render(pane)
	end

	local function tick()
		local r = reg[pane]
		if r == nil or r.st.parse_token ~= token then
			return -- superseded by a newer open/reload, or block gone
		end
		local from = pos + 1
		local to = math.min(#lines, from + PARSE_BATCH - 1)
		for i = from, to do
			Parse.push(acc, lines[i])
		end
		pos = to
		if pos < #lines then
			tern.timer(0, tick)
		else
			finish()
		end
	end

	if #lines == 0 then
		finish()
	else
		tern.timer(0, tick)
	end
end

local function drop_first_line(text: string): string
	local i = string.find(text, "\n", 1, true)
	return if i then string.sub(text, (i :: number) + 1) else ""
end

local function load_tail(pane: number)
	local r = reg[pane]
	if r == nil or r.st.path == nil then
		return
	end
	local st = r.st
	local path = st.path :: string
	local size = st.file_size
	local want = math.min(size, CHUNK_BYTES)
	local from = math.max(1, size - want + 1)
	st.loaded_from = from
	st.truncated = from > 1
	st.loading = true
	if from <= 1 then
		-- Small file: read off-thread like every other path so no callback
		-- ever pays for disk IO.
		tern.process.run({ "cat", path }, { timeout_ms = 8000 }, function(res)
			local r = reg[pane]
			if r == nil or r.st.path ~= path then
				return
			end
			r.st.loading = false
			if res.status ~= 0 then
				r.st.error = "read failed: " .. res.stderr
			else
				r.st.error = nil
				start_parse(pane, res.stdout, 1, "replace")
			end
			render(pane)
		end)
		return
	end
	tern.process.run({ "tail", "-c", "+" .. tostring(from), path }, { timeout_ms = 8000 }, function(res)
		local r = reg[pane]
		if r == nil or r.st.path ~= path then
			return
		end
		r.st.loading = false
		if res.status ~= 0 then
			r.st.error = "read failed: " .. res.stderr
		else
			r.st.error = nil
			start_parse(pane, drop_first_line(res.stdout), from, "replace")
		end
		render(pane)
	end)
end

local function open_session(pane: number, path: string)
	local r = reg[pane]
	if r == nil then
		return
	end
	local st = r.st
	st.mode = "view"
	st.path = path
	st.error = nil
	st.entries = {}
	st.rounds = {}
	st.rows = {}
	st.stats = nil
	st.sel = 1
	st.open_id = nil
	st.follow = true
	st.filter = nil
	st.filter_edit = false
	st.filter_buf = ""
	st.file_size = 0
	st.stream_upto = 0
	st.loaded_from = 1
	st.truncated = false
	st.bad = 0
	tern.kv.set("last", path)
	schedule_watch(pane)
	stat_size(pane, path, function(n)
		local r = reg[pane]
		if r == nil or r.st.path ~= path then
			return
		end
		if n == nil then
			r.st.error = "cannot stat session file"
			render(pane)
			return
		end
		r.st.file_size = n :: number
		load_tail(pane)
	end)
end

local function load_earlier(pane: number)
	local r = reg[pane]
	if r == nil or r.st.path == nil then
		return
	end
	local st = r.st
	if st.loaded_from <= 1 then
		return
	end
	local path = st.path :: string
	local b = st.loaded_from
	local a = math.max(1, b - CHUNK_BYTES)
	st.loading = true
	local cmd = string.format("tail -c +%d %q | head -c %d", a, path, b - a)
	tern.process.run({ "sh", "-c", cmd }, { timeout_ms = 8000 }, function(res)
		local r = reg[pane]
		if r == nil or r.st.path ~= path then
			return
		end
		r.st.loading = false
		if res.status ~= 0 then
			r.st.error = "read failed: " .. res.stderr
		else
			r.st.error = nil
			r.st.loaded_from = a
			r.st.truncated = a > 1
			local text = res.stdout
			if a > 1 then
				text = drop_first_line(text)
			end
			-- BISECTION 3: state flip + parse chain, NO render here (the
			-- chain's finish renders once)
			start_parse(pane, text, a, "prepend")
		end
	end)
end

---------------------------------------------------------------------
-- Active-session watch: incremental refresh of the newest file
---------------------------------------------------------------------

schedule_watch = function(pane: number)
	local r = reg[pane]
	if r == nil then
		return
	end
	if r.watch then
		(r.watch :: TimerHandle):cancel()
	end
	r.watch = tern.timer(WATCH_MS, function()
		local r = reg[pane]
		if r == nil then
			return
		end
		r.watch = nil
		if not alive(pane) then
			drop_reg(pane)
			return
		end
		local st = r.st
		if st.mode ~= "view" or st.path == nil or st.path ~= st.newest_path then
			return -- chain stops; opening a session re-arms it
		end
		local path = st.path :: string
		stat_size(pane, path, function(n)
			local r = reg[pane]
			if r == nil then
				return
			end
			local st = r.st
			if n ~= nil and (n :: number) >= st.file_size and st.file_size > 0 and st.stream_upto >= st.file_size then
				-- Clean incremental read from the last complete line.
				local size = n :: number
				if size > st.file_size then
					local from = st.stream_upto + 1
					tern.process.run({ "tail", "-c", "+" .. tostring(from), path }, { timeout_ms = 8000 }, function(res)
						local r = reg[pane]
						if r == nil or r.st.path ~= path then
							return
						end
						if res.status == 0 then
							r.st.file_size = size
							start_parse(pane, res.stdout, from, "prepend", true)
						end
						render(pane)
					end)
				end
			else
				-- First stat after open, shrunk file, or a partial trailing
				-- line: reparse the tail window whole.
				if n ~= nil then
					st.file_size = n :: number
					load_tail(pane)
				end
			end
			schedule_watch(pane)
		end)
	end)
end

---------------------------------------------------------------------
-- Row helpers
---------------------------------------------------------------------

local function rebuild_rows(st: State)
	local win: { Round } = {}
	for i = st.win_from, #st.rounds do
		table.insert(win, st.rounds[i])
	end
	st.rows = View.build_rows(win, st.filter)
	st.sel = math.clamp(st.sel, 1, math.max(1, #st.rows))
end

local function row_by_id(st: State, id: string): number?
	for i, row in st.rows do
		if row.id == id then
			return i
		end
	end
	return nil
end

local function toggle_open(st: State): boolean
	local row = st.rows[st.sel]
	if row == nil or row.row_kind ~= "entry" then
		return false
	end
	local e = row.entry :: Entry
	if st.open_id == e.id then
		st.open_id = nil
	else
		st.open_id = e.id
	end
	return true
end

local function move(st: State, delta: number)
	if #st.rows == 0 then
		return
	end
	st.sel = math.clamp(st.sel + delta, 1, #st.rows)
	st.follow = st.sel == #st.rows
end

---------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------

local function key_view(st: State, key: Key, cx: BlockCx): boolean?
	if st.filter_edit then
		if key.name == "escape" then
			st.filter_edit = false
			st.filter_buf = ""
		elseif key.name == "enter" then
			st.filter_edit = false
			st.filter = st.filter_buf
			st.sel = 1
			rebuild_rows(st)
		elseif key.name == "backspace" then
			st.filter_buf = string.sub(st.filter_buf, 1, -2)
		elseif key.name == "paste" then
			st.filter_buf = string.sub(st.filter_buf .. (key.text or ""), 1, 120)
		elseif key.text ~= nil and #key.text > 0 then
			st.filter_buf = string.sub(st.filter_buf .. key.text, 1, 120)
		else
			return false
		end
		return true
	end
	local bare = not (key.ctrl or key.meta or key.alt)
	if key.name == "up" or (bare and key.name == "k") then
		move(st, -1)
	elseif key.name == "down" or (bare and key.name == "j") then
		move(st, 1)
	elseif key.name == "page_up" then
		move(st, -20)
	elseif key.name == "page_down" then
		move(st, 20)
	elseif key.name == "home" then
		st.sel = 1
		st.follow = #st.rows <= 1
	elseif key.name == "end" then
		st.sel = #st.rows
		st.follow = true
	elseif key.name == "enter" then
		return toggle_open(st)
	elseif key.name == "escape" then
		if st.open_id ~= nil then
			st.open_id = nil
		elseif st.filter ~= nil then
			st.filter = nil
			st.sel = 1
			rebuild_rows(st)
		else
			st.mode = "list"
		end
	elseif bare and key.name == "r" then
		if st.path ~= nil then
			open_session(cx.pane, st.path :: string)
		end
	elseif bare and key.name == "f" then
		st.filter_edit = true
		st.filter_buf = st.filter or ""
	elseif bare and (key.name == "h" or key.name == "left") then
		if st.truncated then
			load_earlier(cx.pane)
		else
			return false
		end
	elseif bare and key.name == "q" then
		cx:exit(0)
	else
		return false
	end
	return true
end

local function key_list(st: State, key: Key, cx: BlockCx): boolean?
	local bare = not (key.ctrl or key.meta or key.alt)
	if key.name == "up" or (bare and key.name == "k") then
		st.sel_list = math.max(1, st.sel_list - 1)
	elseif key.name == "down" or (bare and key.name == "j") then
		st.sel_list = math.min(math.max(1, #st.sessions), st.sel_list + 1)
	elseif key.name == "enter" then
		local s = st.sessions[st.sel_list]
		if s == nil then
			return false
		end
		open_session(cx.pane, s.path)
	elseif bare and key.name == "r" then
		start_listing(cx.pane)
	elseif bare and key.name == "q" then
		cx:exit(0)
	else
		return false
	end
	return true
end

---------------------------------------------------------------------
-- Events
---------------------------------------------------------------------

local function handle_event(st: State, ev: UiEvent, pane: number)
	if ev.ev ~= "action" then
		return
	end
	local act = ev.act
	local value = ev.value
	if act == "pick" and value ~= nil then
		for i, s in st.sessions do
			if "s" .. s.name == value then
				st.sel_list = i
				break
			end
		end
	elseif act == "open" and value ~= nil then
		for i, s in st.sessions do
			if "s" .. s.name == value then
				st.sel_list = i
				open_session(pane, s.path)
				break
			end
		end
	elseif act == "row" and value ~= nil then
		local i = row_by_id(st, value)
		if i ~= nil then
			if st.sel == i then
				toggle_open(st)
			else
				st.sel = i
				st.follow = st.sel == #st.rows
			end
		end
	elseif act == "toggle" and value ~= nil then
		local i = row_by_id(st, value)
		if i ~= nil then
			st.sel = i
			toggle_open(st)
		end
	elseif act == "earlier" then
		load_earlier(pane)
	elseif act == "jump" and value ~= nil then
		local target = tonumber(value)
		if target ~= nil then
			for i, row in st.rows do
				if row.row_kind == "round" and row.round ~= nil and (row.round :: Round).index == target then
					st.sel = i
					st.follow = false
					st.open_id = nil
					break
				end
			end
		end
	end
end

---------------------------------------------------------------------
-- Views
---------------------------------------------------------------------

local function dock_view(st: State): Node
	local spans: { View.HintPart } = {}
	local function add(t: string, s: string)
		table.insert(spans, { t = t, s = s })
	end
	if st.filter_edit then
		add("filter: " .. st.filter_buf .. "▏", "accent")
		add("  enter apply · esc cancel", "muted")
	else
		add("↑↓", "")
		add(" move · ", "muted")
		add("enter", "")
		add(if st.mode == "view" then " expand · " else " open · ", "muted")
		if st.mode == "view" then
			add("f", "")
			add(" filter" .. (if st.filter ~= nil then " (" .. (st.filter :: string) .. ")" else "") .. " · ", "muted")
			add("h", "")
			add(if st.truncated then " earlier · " else " · ", "muted")
			add("r", "")
			add(" reload · ", "muted")
			add("esc", "")
			add(" back · ", "muted")
		else
			add("r", "")
			add(" rescan · ", "muted")
		end
		add("q", "")
		add(" quit", "muted")
		if st.mode == "view" then
			add(
				if st.follow then "  · following tail" else "  · tail paused",
				if st.follow then "success" else "warning"
			)
		end
	end
	return ui.col({ View.hint(spans) })
end

local function list_view(st: State, cx: BlockCx): BlockView
	local children: { Node } = {}
	if st.error ~= nil then
		table.insert(children, ui.text({ ui.span(st.error :: string, "error") }))
	end
	if st.listing then
		table.insert(children, ui.text({ ui.span("Scanning " .. SESSIONS_DIR .. " …", "muted") }))
	elseif #st.sessions == 0 then
		table.insert(children, ui.text({ ui.span("No omp sessions found in " .. SESSIONS_DIR, "muted") }))
	else
		local items, selected = View.session_items(st.sessions, st.sel_list)
		local listing = ui.list(items)
		local ids: { string } = {}
		for _, s in st.sessions do
			table.insert(ids, "s" .. s.name)
		end
		View.wire_list(listing, "pick", nil, ids)
		local p: { [string]: any } = listing.p or {}
		p.key = "sessions"
		p.selected = if selected then "main.sessions." .. (selected :: string) else nil
		p.empty = { ui.span("No sessions", "muted") }
		p.max = { lines = math.max(8, (cx.rows or 24) - 6) }
		listing.p = p
		table.insert(children, listing)
	end
	return { main = ui.col(children), dock = dock_view(st) }
end

local function window_rounds(st: State): { Round }
	local win: { Round } = {}
	for i = st.win_from, #st.rounds do
		table.insert(win, st.rounds[i])
	end
	return win
end

local function traj_view(st: State, cx: BlockCx): BlockView
	rebuild_rows(st)
	local children: { Node } = {}
	if st.error ~= nil then
		table.insert(children, ui.text({ ui.span(st.error :: string, "error") }))
	end
	if st.stats ~= nil then
		table.insert(children, View.info(st.stats :: Query.Stats, st.truncated, st.bad))
	end
	local timeline = View.timeline(window_rounds(st), TIMELINE_CAP)
	if timeline then
		table.insert(children, timeline)
	end
	if st.truncated then
		local more = ui.badge("Load earlier", "accent")
		local mp: { [string]: any } = more.p or {}
		mp.actions = { click = "earlier" }
		mp.key = "earlier"
		more.p = mp
		table.insert(children, ui.row({ more, ui.text({
			ui.span(
				string.format("showing bytes %d–%d of %d", st.loaded_from, st.file_size, st.file_size),
				"muted"
			),
		}) }))
	end
	if st.loading and #st.rows == 0 then
		table.insert(children, ui.text({ ui.span("Loading session …", "muted") }))
	end
	local items, selected = View.ledger_items(st.rows, st.sel)
	local listing = ui.list(items)
	View.wire_list(listing, "row", st.rows, nil)
	local p: { [string]: any } = listing.p or {}
	p.key = "ledger"
	p.selected = if selected then "main.ledger." .. (selected :: string) else nil
	p.empty = {
		ui.span(if st.filter ~= nil then "No rows match the filter" else "Empty session", "muted"),
	}
	p.max = { lines = math.max(6, (cx.rows or 24) - 10) }
	listing.p = p
	table.insert(children, listing)

	-- Expanded inspector, keyed by the entry id for stable diffs.
	if st.open_id ~= nil then
		for _, row in st.rows do
			if row.row_kind == "entry" and row.entry ~= nil and (row.entry :: Entry).id == st.open_id then
				local node = View.inspector(row.entry :: Entry)
				local ip: { [string]: any } = node.p or {}
				ip.key = "insp-" .. st.open_id
				node.p = ip
				table.insert(children, node)
				break
			end
		end
	end
	local dock = dock_view(st)
	return { main = ui.col(children), dock = dock }
end

local block: BlockDef<State> = {
	init = function(cx, _args, saved)
		local st = fresh()
		reg[cx.pane] = { cx = cx, st = st, watch = nil }
		if saved and type(saved) == "table" then
			local s = saved :: any
			if type(s.path) == "string" and s.mode == "view" then
				st.preselect = s.path
				open_session(cx.pane, s.path :: string)
			end
			if type(s.sel_list) == "number" then
				st.sel_list = s.sel_list
			end
		end
		start_listing(cx.pane)
		schedule_watch(cx.pane)
		return st
	end,

	title = function(st)
		if st.mode == "view" and st.path ~= nil then
			local name = (st.path :: string):match("([^/]+)%.jsonl$")
			return "Trajectory · " .. (name or "session")
		end
		return "OMP Trajectory"
	end,

	view = function(st, cx)
		if st.mode == "list" then
			return list_view(st, cx)
		end
		return traj_view(st, cx)
	end,

	key = function(st, key, cx)
		if st.mode == "list" then
			return key_list(st, key, cx)
		end
		return key_view(st, key, cx)
	end,

	event = function(st, ev, cx)
		handle_event(st, ev, cx.pane)
	end,

	save = function(st)
		return { mode = st.mode, path = st.path, sel_list = st.sel_list }
	end,
}

tern.block.define("trajectory", block)
