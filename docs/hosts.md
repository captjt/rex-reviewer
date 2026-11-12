# Hosts: Rex or Herdr

rex-reviewer's rounds, rules, ledger and briefs don't depend on where the
agents' panes run. A host does that part: it starts and drives the panes,
shows them, and runs the watcher. `host` in the config picks one.

```lua
host = "rex",    -- the default
host = "herdr",  -- herdr-core, with the Herdr app and the phone app
```

Run one host at a time: both watchers would start every round twice. Both
read and write the same ledger, so switching keeps the history, the recap,
and the token counts.

| | Rex | Herdr |
| --- | --- | --- |
| Runs the panes | the Rex server | herdr-core (`hc`) |
| Shows them | Rex.app | the Herdr app, and the phone app |
| Runs the actions | Rex's Lua: `rex do reviewer_post pr=12` | LuaJIT: `rex-reviewer do reviewer_post pr=12` |
| Runs the checker's preview and post | the Rex server, for `rex do` | the watcher, for `rex-reviewer request` |
| Drives the agents | `bin/rex-agent` | `bin/hc-agent` |
| The watcher | `scripts/watch.lua`, in the control tab of the session | `scripts/watch-herdr.sh` and `.lua`, in the control tab of the space |
| A review waiting for you | a status record on the watcher's tab; rex-inbox shows it | a post terminal in the PR's tab, which the phone lists under needs you |

`bin/rex-agent` and `bin/hc-agent` take the same commands and give the same
JSON and exit codes, and the watcher's status records are the same OSC 7501
bytes on both, so the rest of the code doesn't ask which host it's on.
[`lua/rex_reviewer/host.lua`](../lua/rex_reviewer/host.lua) lists what a
host module provides.

## Herdr

You need herdr-core 0.1.20 or later (`hc`), LuaJIT (`brew install luajit`),
and `gh`, `git` and `jq` as for Rex. The Herdr app (0.1.15 or later) shows
the panes in spaces and tabs; without it they still run, and the phone app
still lists them.

```sh
# In ~/.config/rex-reviewer/config.lua: host = "herdr"
rex-reviewer doctor          # checks hc, the app, LuaJIT, and the rest
rex-reviewer up              # starts the watcher in herdr-core
rex-reviewer launch-agent    # optional: start it at login, repair it every 5 minutes
```

Nothing loads in Rex: on Herdr, `bin/rex-reviewer` runs the actions with
`luajit scripts/cli.lua`, so the dofile line in Rex's `init.lua` isn't
needed.

### Where things show

Each terminal carries `herdr.space` and `herdr.tab` labels. Whenever the
Herdr app runs, it puts a labeled terminal in that space and tab, split to
the right of the tab's last pane, without moving your focus.

```
space rex-reviewer                 the config's session
  tab watcher                      rr-watcher
  tab api-12                       rr-api-12, rr-api-12-claude, rr-api-12-check, rr-api-12-post
```

Terminal names are unique across herdr-core, so each gets the `rr-` prefix,
shortened with a hash past hc's 32 characters. Labels record the pane's
name and role (`rex-reviewer.pane`, `rex-reviewer.role`), and
`rex-reviewer=1` marks the terminals whose events the watcher follows.

The app names a space it made from labels after its first terminal's folder,
and a tab by its number. When the window is open, the watcher renames the
space and its tab, and `bin/hc-agent` names each PR's tab.

### What the checker runs

The checker previews the review, and with `post = "auto"` posts it, from
its sandbox, where `gh` is signed out. In Rex, `rex do` hands the action to
the Rex server, which runs it outside the sandbox. herdr-core has no such
server, so the checker runs `rex-reviewer request reviewer_preview …`
instead: that leaves a request in `.tmp/requests/` of its worktree and
waits, and the watcher runs it on its next tick, with your `gh` login, and
leaves the result beside it. The watcher runs only the preview and post
actions, only for the round whose worktree holds the request, and only while
its checker checks; post also needs `post = "auto"`.
[`lua/rex_reviewer/requests.lua`](../lua/rex_reviewer/requests.lua) has the
details. A request waits for the watcher, so one that's busy starting
another round answers late.

### A review waiting for you

With `post = "ask"`, when a round's checked review is ready, the watcher
opens `scripts/ask.lua` in the PR's tab as `rr-<pane>-post`. It shows the
verdict and the findings, and reports `blocked` with `kind=permission`, so
the Herdr app notifies and the phone app lists it under needs you. It takes
one key:

| Key | Does |
| --- | --- |
| `p` | posts the review |
| `v` | shows the whole review, as it would post |
| `d` | dismisses it, after a second `d` |
| `r` | reads it again |

From the phone, type the key into the terminal, or send it from compose.
The terminal acts through the same actions as the menu bar and the CLI, by
the round's item id, so it can't act on a round that moved on. When the
round ends, its tab closes. The menu bar app and `rex-reviewer post` still
work as on Rex.

The phone app shows banners only while it's open.

### What differs from Rex

- The checker opens to the right of the reviewers; in Rex it opens on
  their left.
- herdr-core starts programs in its own environment. `bin/hc-agent` gives
  each agent the PATH rex-reviewer found it on.
- Codex gets `--no-daemon`, without which its commands run outside the
  terminal.
- A round's panes outlive the app's window, and a reboot: the app keeps a
  terminal it placed. After a reboot, a pane comes back as a shell without
  status, which counts as a closed pane, as in Rex.
- `start` is an action (`reviewer_start`), since nothing cuts it off at 30
  seconds.

## Switching hosts

Switch while no round is reviewing (`rex-reviewer status`).

1. `rex-reviewer down` on the current host.
2. Set `host` in the config.
3. `rex-reviewer up`, and `rex-reviewer launch-agent` again: the LaunchAgent
   runs `rex do` on Rex and `rex-reviewer` on Herdr.

A watcher left running on the other host sees the change when it restarts,
says so in its pane, and does nothing.

## Tests

- `luajit tests/status.lua`, `luajit tests/json.lua` and
  `luajit tests/requests.lua` need nothing else.
- `tests/hc-agent.sh` checks `bin/hc-agent` against a fake agent
  (`tests/fake-agent.sh`) in the running herdr-core. Its terminals are named
  `rr-hct-*`, in a space of their own, and it closes them.
- `REX_REVIEWER_CONFIG_DIR`, `REX_REVIEWER_STATE_DIR`,
  `REX_REVIEWER_DATA_DIR` and `REX_REVIEWER_CACHE_DIR` move rex-reviewer's
  folders, and `HC_AGENT_PREFIX` its terminal names, so a test watcher runs
  beside the real one.

## Renaming

The tool's name is in a few places that outlive a release: `config.APP` in
[`config.lua`](../lua/rex_reviewer/config.lua) (terminal labels, the default
session, Claude Code session names), `APP` in
[`status.lua`](../lua/rex_reviewer/status.lua) (the watcher's status
records, which rex-inbox matches), the `rr-` terminal prefix (`HC_AGENT_PREFIX`),
the config, state, data and cache folders and their environment variables,
the LaunchAgent label, the `rex-reviewer` CLI, the `reviewer_*` action
names, and the menu bar app's bundle. A rename moves each of them, and the
folders, once.
