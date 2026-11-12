-- Rex: the panes are Rex blocks, a PR's tab is a Rex window, and the
-- watcher runs in the control tab of the rex-reviewer session, as a
-- `rex do` script in Rex's own Lua. bin/rex-agent drives the agents.
--
-- Every host module gives the rest of rex-reviewer the same calls; see
-- lua/rex_reviewer/host.lua.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")

local M = { name = "rex" }

local function rex_cli(args)
  return util.run(util.append({ "rex" }, args))
end

function M.driver()
  return config.ROOT .. "/bin/rex-agent"
end

function M.watch_script()
  return config.ROOT .. "/scripts/watch.lua"
end

-- What the doctor checks for on PATH.
M.programs = { "rex" }

---------------------------------------------------------------------------
-- Where a PR's panes are

-- The IDs of the Rex sessions that exist now, or nil when Rex can't say.
function M.live_scopes()
  local rex = rawget(_G, "rex")
  local ok, res
  if rex then
    ok, res = pcall(rex.call, "session.list", {})
  else
    ok, res = pcall(function()
      return util.decode(rex_cli({ "api", "call", "session.list", "{}" }).stdout)
    end)
  end
  if not ok or type(res) ~= "table" then
    return nil
  end
  local live = {}
  for _, s in ipairs(res.sessions or {}) do
    live[s.session_id] = true
  end
  return live
end

-- The session a PR's panes are in: the one its last round opened them in,
-- while that session exists, otherwise fallback (the watcher's). A saved ID
-- can outlive its session: when Rex restarts, reviewer_up makes a new
-- rex-reviewer session, and the old one's panes are gone with it.
function M.scope(e, fallback, live)
  if e.session_id and (live == nil or live[e.session_id]) then
    return e.session_id
  end
  return fallback
end

-- The watcher's session, from state.json.
function M.home_scope()
  return ledger.load_state().session_id
end

---------------------------------------------------------------------------
-- The session and its watcher pane

local function watcher_loop()
  return string.format(
    'while :; do rex do "%s"; echo "watcher stopped ($?); restarting in 10s"; sleep 10; done',
    M.watch_script()
  )
end

-- rex.call("session.set_block_label") from Lua returns without setting the
-- label, so this goes through the CLI.
local function label_block(sid, bid, label)
  rex_cli({ "api", "call", "session.set_block_label", util.json({ session_id = sid, block_id = bid, label = label }) })
end

local function sessions()
  local rex = rawget(_G, "rex")
  if rex then
    return (rex.call("session.list", {}) or {}).sessions or {}
  end
  return (util.decode(rex_cli({ "api", "call", "session.list", "{}" }).stdout) or {}).sessions or {}
end

-- Make sure the session exists with a running watcher. The session is
-- found by the ID in state.json, because agents in its panes can rename it.
function M.start_watcher()
  local label = config.load().session
  local st = ledger.load_state()
  local sid
  local list = sessions()
  for _, s in ipairs(list) do
    if st.session_id and s.session_id == st.session_id then
      sid = s.session_id
    end
  end
  if not sid then
    for _, s in ipairs(list) do
      if s.label == label then
        sid = s.session_id
      end
    end
  end
  if not sid then
    local j = util.decode(rex_cli({ "new", label, "--window", "control", "-c", util.HOME, "--json", "--", "/bin/sh", "-c", watcher_loop() }).stdout)
    sid = j.session_id
    local bid = j.initial_windows[1].block_ids[1]
    label_block(sid, bid, "watcher")
    ledger.update_state(function(s)
      s.session_id = sid
    end)
    return { session_id = sid, watcher = bid, created = "session" }
  end
  if st.session_id ~= sid then
    ledger.update_state(function(s)
      s.session_id = sid
    end)
  end
  rex_cli({ "session", "rename", sid, label })
  local blocks = util.decode(rex_cli({ "block", "ls", "-s", sid, "--json" }).stdout).blocks or {}
  for _, b in ipairs(blocks) do
    if b.label == "watcher" then
      local p = util.decode(rex_cli({ "block", "call", "-s", sid, "-b", b.block_id, "process" }).stdout) or {}
      if p.child and p.last_exit == nil then
        return { session_id = sid, watcher = b.block_id, created = false }
      end
      rex_cli({ "block", "close", "-s", sid, b.block_id })
    end
  end
  local j = util.decode(rex_cli({ "window", "new", "-s", sid, "control", "-c", util.HOME, "--focus=false", "--json", "--", "/bin/sh", "-c", watcher_loop() }).stdout)
  local bid = j.block_ids[1]
  label_block(sid, bid, "watcher")
  return { session_id = sid, watcher = bid, created = "watcher" }
end

-- Close the watcher's pane. Review tabs stay open.
function M.stop_watcher()
  local st = ledger.load_state()
  local closed = {}
  if st.session_id then
    local ok, res = pcall(rex_cli, { "block", "ls", "-s", st.session_id, "--json" })
    local blocks = ok and (util.decode(res.stdout) or {}).blocks or {}
    for _, b in ipairs(blocks) do
      if b.label == "watcher" then
        rex_cli({ "block", "close", "-s", st.session_id, b.block_id })
        closed[#closed + 1] = b.block_id
      end
    end
  end
  return closed
end

---------------------------------------------------------------------------
-- Showing a pane

local function block_window(sid, bid)
  local blocks = util.decode(rex_cli({ "block", "ls", "-s", sid, "--json" }).stdout).blocks or {}
  for _, b in ipairs(blocks) do
    if b.block_id == bid or (bid == "watcher" and b.label == "watcher") then
      return b.block_id, b.window_id
    end
  end
end

-- Focus the pane, then take the app to its session and tab. The app takes
-- that only with Remote Control on (Settings, Rex Server); without it,
-- selected is false. pane is a block ID, or "watcher".
function M.show(sid, pane)
  local bid, wid = block_window(sid, pane)
  if not bid then
    return nil
  end
  rex_cli({ "focus", "-s", sid, bid })
  local selected, err = pcall(rex_cli, { "do", "session.select", "session_id=" .. sid, "window_id=" .. wid })
  return {
    session_id = sid, block_id = bid, selected = selected,
    note = not selected and tostring(err):match("Rex%.app is not accepting actions") and "remote control off" or nil,
  }
end

---------------------------------------------------------------------------
-- What agents run

-- The command an agent runs for an action, as a brief writes it.
function M.action_cmd(action, args)
  return "rex do " .. action .. (args and args ~= "" and (" " .. args) or "")
end

-- Claude Code's permission rule for that command.
function M.allow(action)
  return "Bash(rex do " .. action .. ":*)"
end

-- Extra args an agent needs on this host.
function M.agent_args(_)
  return {}
end

return M
