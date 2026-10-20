# tern-omp-trajectory

A [Tern](https://docs.stencil.so/tern) plugin that turns
[omp](https://github.com/can1357/oh-my-pi) session logs
(`~/.omp/agent/sessions/**/*.jsonl`) into a native trajectory viewer: a
turn-grouped call ledger, per-entry inspectors, and a token timeline.

## Install

```sh
tern plugin install github.com/Ahaxzh/tern-omp-trajectory
```

or link a checkout in place (edits hot-reload):

```sh
git clone https://github.com/Ahaxzh/tern-omp-trajectory
tern plugin link ./tern-omp-trajectory
```

Then open the command palette and run **New OMP Trajectory block**. The
block kind is `omp-trajectory.trajectory`.

## Use

Session list and ledger share one keymap (vim-style arrows work too):

| Key | Session list | Ledger |
| --- | --- | --- |
| `↑`/`↓` | move selection | move cursor |
| `enter` | open session | expand/collapse inspector |
| `click` | select | select; click again toggles the inspector |
| `f` | – | filter rows (tool name / intent / text); `enter` applies, `esc` cancels |
| `r` | rescan sessions | reload session |
| `esc` | – | close inspector → clear filter → back to list |
| `q` | quit block | quit block |

Timeline chips (tokens per round) and **Load earlier** are clickable.

## Behavior

- **Tail-first**: opening parses at most the last 1 MB of the file (last 50
  rounds); **Load earlier** pages one chunk back. Files are never parsed
  whole beyond the chunk, regardless of size.
- **Live sessions**: viewing the newest `.jsonl` refreshes every 60 s with
  an incremental tail read; the cursor follows the tail until you scroll
  up, and the watch stops when the block closes.
- **Row model**: user / assistant / tool / compaction / system rows grouped
  by round (round headers start at each user prompt). Auxiliary
  `model_usage` calls are counted in the info bar, not rendered as rows.
- **Inspector**: human fields (tokens in/out/cache, cost, ttft, duration,
  stop reason, wall time) plus the entry's complete original JSON and the
  full tool args/result text. Inspectors are keyed by entry id, so diffs
  stay stable across reloads.
- **Info bar**: rounds, requests, token and cost totals, model, and a
  sparkline of `totalTokens` per assistant call with first/last values.
- Unknown entry types are kept as system rows, so future omp versions
  degrade visibly instead of silently dropping data. Unparseable lines are
  counted and skipped. State lives in the block; preferences (last opened
  session) in `tern.kv`.

## Layout

```
plugin.toml        manifest (block id "trajectory")
host.luau          block state machine, async IO within the 2 s worker budget
lib/json.luau      pure-Luau JSON decoder (no tern dependency)
lib/parse.luau     JSONL line -> normalized entries, tool merge, compaction epochs
lib/query.luau     rounds, pagination, stats, formatting, filtering (pure)
lib/view.luau      data -> ui nodes (no IO)
tern.d.luau        generated type definitions (`tern plugin types .`)
tests/             unit tests + fixtures from real session logs
```

`lib/parse` and `lib/query` are pure Luau, so they test on the plain
`luau` CLI without a running Tern.

## Development

```sh
tern plugin types .   # regenerate tern.d.luau for your tern build
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau \
  host.luau lib/json.luau lib/parse.luau lib/query.luau lib/view.luau
luau tests/run.luau   # 83 assertions over two real 1.4 MB / 670 KB sessions
```

`tests/fixtures.luau` embeds two real session logs (2.8 MB) with
ground-truth counts measured via jq; `tests/gen_fixtures.sh` regenerates
it from `$A`/`$B` if you want fixtures from your own sessions.

## Limitations

- JSONL is the only source; live updates poll the file every 60 s rather
  than tailing inotify.
- System prompt content is only a digest in the logs (show it, note
  `/dump` for the full text).
- The timeline caps at 32 rounds with an overflow note; the ledger caps at
  the pane height plus scroll (`list` keeps the selection in view).
- Windows/macOS untested; development happened on Linux (uses `wc`,
  `tail`, `head`, `python3` for listing metadata).
