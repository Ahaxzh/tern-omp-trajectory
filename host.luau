--!strict
-- OMP Trajectory, host half. Block `omp-trajectory.trajectory`:
-- a session picker over ~/.omp/agent/sessions plus a trajectory ledger for
-- one session JSONL (round-grouped call flow, inspectors, timeline).
--
-- IO design: the normal open/refresh/earlier path uses ZERO child processes
-- (tern.fs.read + batch-chained parsing). The worker's process hook is only
-- touched by two rare fallbacks (oversize files, optional list enrichment),
-- so one contended spike can no longer freeze the block: file reads are
-- ~10-30 ms of worker time and parsing runs in ~120-line timer ticks.

local Parse = require("./lib/parse")
local Query = require("./lib/query")
local View = require("./lib/view")

type Entry = Parse.Entry
type Round = Query.Round
type Row = View.Row
type SessionInfo = View.SessionInfo

local ui = tern.ui

local SESSIONS_DIR = (tern.getenv("HOME") or "") .. "/.omp/agent/sessions"
local CHUNK_BYTES = 1024 * 1024 -- tail window parsed at open / per earlier page
local FULL_LIMIT = 8 * 1024 * 1024 -- never read/parse more than this whole
local TAIL_ROUNDS = 50 -- rounds shown initially
local WATCH_MS = 60 * 1000 -- active-session refresh interval
local TIMELINE_CAP = 32 -- chips in the timeline strip
local PARSE_BATCH = 60 -- lines per chained callback (~15-40 ms)

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
	truncated: boolean,
	parsed_lines: number, -- lines of the current file parsed so far
	first_window_line: number, -- 1-based first line of the loaded window
	total_lines: number, -- line count at the last full read
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
		truncated = false,
		parsed_lines = 0,
		first_window_line = 1,
		total_lines = 0,
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
-- Session listing (pure fs; titles/sizes enriched by one optional spawn)
---------------------------------------------------------------------

-- Titles and sizes need file heads, which tern.fs cannot do partially; one
-- python3 pass fills them in. If the hook is disabled or the spawn fails,
-- the list simply stays name-only and everything else keeps working.
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

local function apply_listing(pane: number, sessions: { SessionInfo })
	local r = reg[pane]
	if r == nil then
		return
	end
	local st = r.st
	st.sessions = sessions
	st.listing = false
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
end

--- Immediate, spawn-free listing: names only (file names carry the UTC
--- start timestamp, so name order is chronological). Titles and sizes fill
--- in later from the enrichment pass when it succeeds.
local function list_sessions_fs(pane: number)
	local r = reg[pane]
	if r == nil then
		return
	end
	local sessions: { SessionInfo } = tern.json.array({})
	local ok, dirs = pcall(tern.fs.list, SESSIONS_DIR)
	if ok and type(dirs) == "table" then
		for _, proj in dirs :: { string } do
			local okd, files = pcall(tern.fs.list, SESSIONS_DIR .. "/" .. proj)
			if okd and type(files) == "table" then
				for _, f in files :: { string } do
					if #f > 6 and string.sub(f, -6) == ".jsonl" then
						table.insert(sessions, {
							path = SESSIONS_DIR .. "/" .. proj .. "/" .. f,
							project = proj,
							name = f,
							title = nil,
							size = 0,
							mtime = 0,
						})
					end
				end
			end
		end
	end
	table.sort(sessions, function(a: SessionInfo, b: SessionInfo)
		return a.name > b.name
	end)
	apply_listing(pane, sessions)
end

--- Optional enrichment (titles, sizes, mtimes) via one python3 spawn.
local function enrich_listing(pane: number)
	local r = reg[pane]
	if r == nil or #r.st.sessions == 0 or #r.st.sessions > 80 then
		return
	end
	tern.process.run({ "python3", "-c", LIST_PY }, { timeout_ms = 15000 }, function(res)
		local r = reg[pane]
		if r == nil or res.status ~= 0 then
			return -- name-only list stays; nothing else depends on this
		end
		local ok, data = pcall(tern.json.decode, res.stdout)
		if not ok or type(data) ~= "table" then
			return
		end
		local st = r.st
		for _, item in data :: { any } do
			if type(item) == "table" then
				local it = item :: any
				for _, s in st.sessions do
					if s.path == it.path then
						if type(it.title) == "string" and it.title ~= "" then
							s.title = it.title
						end
						s.size = tonumber(it.size) or s.size
						s.mtime = tonumber(it.mtime) or s.mtime
						break
					end
				end
			end
		end
		render(pane)
	end)
end

local function start_listing(pane: number)
	local r = reg[pane]
	if r == nil then
		return
	end
	r.st.listing = true
	render(pane)
	list_sessions_fs(pane)
	enrich_listing(pane)
end

---------------------------------------------------------------------
-- Session loading (spawn-free; batch-chained parsing)
---------------------------------------------------------------------

--- Whole-file read guarded by FULL_LIMIT. nil means the file is larger
--- (or unreadable) and the rare spawn-based fallback must handle it.
local function read_whole(path: string): string?
	local ok, text = pcall(tern.fs.read, path, FULL_LIMIT)
	if ok and type(text) == "string" then
		return text
	end
	return nil
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

--- Parses lines[from..to] in small chained callbacks, then applies the
--- result to the state. Stale chains abort via parse_token.
local function chain_parse(
	pane: number,
	lines: { string },
	from_line: number,
	to_line: number,
	mode: "replace" | "prepend",
	pin_tail: boolean?
)
	local r = reg[pane]
	if r == nil then
		return
	end
	local st = r.st
	local acc = Parse.acc()
	local anchor_id: string? = nil
	if mode == "prepend" then
		local anchor = st.rows[st.sel]
		anchor_id = if anchor then anchor.id else nil
	end
	st.parse_token += 1
	local token = st.parse_token
	local pos = from_line - 1

	local function finish()
		local r = reg[pane]
		if r == nil or r.st.parse_token ~= token then
			return
		end
		local st = r.st
		local parsed = Parse.finish(acc)
		if mode == "replace" then
			st.entries = parsed.entries
			st.bad = parsed.bad
			st.rounds = Query.rounds(st.entries)
			st.win_from = Query.tail_from(st.rounds, TAIL_ROUNDS)
			st.stats = Query.stats(st.entries, round_count(st))
			st.follow = true
			st.parsed_lines = to_line
		else
			local rounds_before = #st.rounds
			local merged: { Entry } = tern.json.array({})
			for _, e in parsed.entries do
				table.insert(merged, e)
			end
			for _, e in st.entries do
				table.insert(merged, e)
			end
			st.entries = merged
			st.bad += parsed.bad
			st.rounds = Query.rounds(st.entries)
			if pin_tail and st.follow then
				st.win_from = Query.tail_from(st.rounds, TAIL_ROUNDS)
			else
				st.win_from = math.max(1, st.win_from + (#st.rounds - rounds_before))
			end
			st.stats = Query.stats(st.entries, round_count(st))
			local win: { Round } = {}
			for i = st.win_from, #st.rounds do
				table.insert(win, st.rounds[i])
			end
			st.rows = View.build_rows(win, st.filter)
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
			st.parsed_lines = math.max(st.parsed_lines, to_line)
		end
		st.total_lines = math.max(st.total_lines, to_line)
		st.loading = false
		render(pane)
	end

	local function tick()
		local r = reg[pane]
		if r == nil or r.st.parse_token ~= token then
			return -- superseded by a newer open/reload, or block gone
		end
		local from = pos + 1
		local to = math.min(to_line, from + PARSE_BATCH - 1)
		for i = from, to do
			Parse.push(acc, lines[i])
		end
		pos = to
		if pos < to_line then
			tern.timer(0, tick)
		else
			finish()
		end
	end

	if from_line > to_line then
		finish()
	else
		st.loading = true
		tern.timer(0, tick)
	end
end

--- First line index of a window ending at `end_line` covering about
--- CHUNK_BYTES (walks line lengths backward; lengths only, no parsing).
local function window_start(lines: { string }, end_line: number): number
	local bytes = 0
	local i = end_line
	while i > 0 do
		bytes += #lines[i] + 1
		if bytes >= CHUNK_BYTES then
			break
		end
		i -= 1
	end
	return math.max(1, i)
end

local function reset_view_state(st: State)
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
	st.parsed_lines = 0
	st.first_window_line = 1
	st.total_lines = 0
	st.truncated = false
	st.bad = 0
end

local function load_session(pane: number, mode: "open" | "refresh" | "earlier")
	local r = reg[pane]
	if r == nil or r.st.path == nil then
		return
	end
	local st = r.st
	local path = st.path :: string

	local text = read_whole(path)
	if text == nil then
		st.loading = false
		st.error = "session file exceeds the 8 MB guard; open it with omp or trim it first"
		render(pane)
		return
	end
	local lines = Parse.split(text)
	st.total_lines = #lines

	if mode == "earlier" then
		local stop = st.first_window_line - 1
		if stop <= 0 then
			st.loading = false
			return
		end
		local startl = window_start(lines, stop)
		st.first_window_line = startl
		st.truncated = startl > 1
		chain_parse(pane, lines, startl, stop, "prepend")
		return
	end

	if mode == "refresh" and st.parsed_lines > 0 and #lines >= st.parsed_lines then
		-- Incremental: parse only the appended lines.
		if #lines > st.parsed_lines then
			chain_parse(pane, lines, st.parsed_lines + 1, #lines, "prepend", true)
		end
		return
	end

	-- Full (re)open: last window of the file.
	local startl = window_start(lines, #lines)
	st.first_window_line = startl
	st.truncated = startl > 1
	chain_parse(pane, lines, startl, #lines, "replace")
end

---------------------------------------------------------------------
-- Active-session watch: incremental refresh of the open file
---------------------------------------------------------------------

local function schedule_watch(pane: number)
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
		if st.mode ~= "view" or st.path == nil then
			return -- chain stops; opening a session re-arms it
		end
		load_session(pane, "refresh")
		schedule_watch(pane)
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
	reset_view_state(st)
	tern.kv.set("last", path)
	schedule_watch(pane)
	load_session(pane, "open")
	render(pane)
end

local function load_earlier(pane: number)
	local r = reg[pane]
	if r == nil or r.st.path == nil or r.st.truncated == false then
		return
	end
	load_session(pane, "earlier")
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
			if st.truncated then
				add("h", "")
				add(" earlier · ", "muted")
			end
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
				string.format(
					"showing lines %d–%d of %d",
					st.first_window_line,
					st.total_lines,
					st.total_lines
				),
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
	return { main = ui.col(children), dock = dock_view(st) }
end

---------------------------------------------------------------------
-- Block definition
---------------------------------------------------------------------

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
