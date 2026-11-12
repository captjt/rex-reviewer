-- Herdr: herdr-core (`hc`) runs the panes as terminals, the Herdr app
-- shows them, and the phone app lists them. Nothing here needs the app to
-- be open: a terminal labeled herdr.space and herdr.tab is placed in that
-- space and tab whenever the app runs, split to the right of the tab's
-- last pane.
--
--   space <session>            the config's session, rex-reviewer by default
--     tab <session>.control    the watcher
--     tab <session>.<pane>     a PR's reviewers, checker, and post terminal
--
-- bin/hc-agent drives the terminals and owns their names. The watcher runs
-- scripts/watch-herdr.sh, which feeds hc's events and a tick to LuaJIT.
--
-- Every host module gives the rest of rex-reviewer the same calls; see
-- lua/rex_reviewer/host.lua.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")
local status = require("rex_reviewer.status")

local M = { name = "herdr" }

-- The oldest versions with what this host uses.
M.MIN_HC = "0.1.20"
M.MIN_APP = "0.1.15"
M.APP_BUNDLE = "dev.herdr.app"

function M.driver()
  return config.ROOT .. "/bin/hc-agent"
end

function M.watch_script()
  return config.ROOT .. "/scripts/watch-herdr.lua"
end

M.programs = { "hc", "luajit" }

local function agent(args)
  return util.run(util.append({ M.driver() }, args), { check = false, env = { HC_AGENT_APP = config.APP } })
end

-- herdr-core starts programs in its own environment, not the caller's. The
-- watcher and the post terminal run rex-reviewer itself, so they get the
-- folders and the terminal prefix this one runs with, when they're moved
-- (as tests do).
local PASSED = {
  "REX_REVIEWER_CONFIG_DIR", "REX_REVIEWER_STATE_DIR", "REX_REVIEWER_DATA_DIR", "REX_REVIEWER_CACHE_DIR",
  "HC_AGENT_PREFIX",
}

local function own(argv)
  local out = {}
  for _, k in ipairs(PASSED) do
    local v = os.getenv(k)
    if v and v ~= "" then
      out[#out + 1] = k .. "=" .. v
    end
  end
  return util.append(out, argv)
end

-- What hc-agent says about a pane, or nil when it's gone.
local function get(name)
  local res = agent({ "get", name })
  if not res.ok then
    return nil
  end
  return util.decode(res.stdout)
end

---------------------------------------------------------------------------
-- Where a PR's panes are

-- Spaces outlive the app and every terminal, so any saved one is live.
function M.live_scopes()
  return nil
end

-- The space a PR's panes are in. A Rex session ID, left from before the
-- host changed, names no space.
function M.scope(e, fallback)
  local s = e.session_id
  if type(s) == "string" and s ~= "" and not s:find(":", 1, true) then
    return s
  end
  return fallback
end

function M.home_scope()
  return config.load().session
end

---------------------------------------------------------------------------
-- The watcher's terminal

-- Make sure the watcher runs. Its terminal reports a status as long as the
-- script does; a live one without status (a fresh shell after a core
-- restart, say) is replaced, unless it's under two minutes old and still
-- starting.
function M.start_watcher()
  local space = M.home_scope()
  local w = get("watcher")
  if w and w.live and (w.state ~= "unknown" or (w.age_s or 0) < 120) then
    return { space = space, watcher = w.block_id, created = false }
  end
  if w then
    agent({ "close", "watcher" })
  end
  local res = agent({
    "start", "watcher", "-s", space, "--plain", "--tab-id", "control", "--role", "watcher", "--no-watch",
    "--cwd", util.HOME, "--kind", "env", "--", unpack(own({ "/bin/sh", config.ROOT .. "/scripts/watch-herdr.sh" })),
  })
  if not res.ok then
    error("the watcher didn't start: " .. util.trim(res.stderr ~= "" and res.stderr or res.stdout):sub(1, 300), 0)
  end
  local j = util.decode(res.stdout) or {}
  ledger.update_state(function(s)
    s.space = space
  end)
  return { space = space, watcher = j.block_id, created = "watcher" }
end

function M.stop_watcher()
  local w = get("watcher")
  if not w then
    return {}
  end
  agent({ "close", "watcher" })
  return { w.block_id }
end

-- Name the space and the watcher's tab in the open window. The app names a
-- space it made from labels after its first terminal's folder. Without a
-- window, nothing happens.
function M.decorate()
  local space = M.home_scope()
  util.run({ "herdr-app", "do", "space.rename", util.json({ id = space, name = config.APP }) }, { check = false })
  util.run({ "herdr-app", "do", "tab.rename", util.json({ id = space .. ".control", name = "watcher" }) }, { check = false })
end

---------------------------------------------------------------------------
-- Showing a pane

-- Show a terminal in the Herdr app: the agent itself, in its tab. pane is
-- a terminal address, or "watcher".
function M.show(_, pane)
  if pane == "watcher" then
    local w = get("watcher")
    if not w or not w.live then
      return nil
    end
    pane = w.block_id
  end
  local res = util.run({ "herdr-app", "do", "agent.focus", util.json({ terminal = pane }) }, { check = false })
  local selected = res.ok and not res.stdout:find('"error"', 1, true)
  if selected then
    util.run({ "open", "-b", M.APP_BUNDLE }, { check = false })
  end
  return {
    space = M.home_scope(), block_id = pane, selected = selected,
    note = not selected and "the Herdr app isn't open" or nil,
  }
end

---------------------------------------------------------------------------
-- What agents run

-- The command an agent runs for an action, as a brief writes it. In its
-- sandbox, with gh signed out, the agent can't run the action itself, so
-- it asks the watcher to (lua/rex_reviewer/requests.lua), as the rex CLI
-- asks the Rex server.
function M.action_cmd(action, args)
  return config.ROOT .. "/bin/rex-reviewer request " .. action .. (args and args ~= "" and (" " .. args) or "")
end

function M.allow(action)
  return "Bash(" .. config.ROOT .. "/bin/rex-reviewer request " .. action .. ":*)"
end

-- Codex runs its commands in a daemon of its own unless told not to, and
-- then they run outside herdr-core's terminal.
function M.agent_args(agent_name)
  if agent_name == "codex" then
    return { "--no-daemon" }
  end
  return {}
end

---------------------------------------------------------------------------
-- The post terminal: a review waiting for you, as a terminal of its own
-- that asks. It reports blocked, so the phone lists it under needs you and
-- the Herdr app notifies. See scripts/ask.lua.

function M.ask_pane(e)
  return (e.pane or "pr") .. "-post"
end

-- Open the round's post terminal in the PR's tab, beside its reviewers,
-- unless it's open. The tab's id comes from the primary reviewer's pane
-- name, so this finds it even after the reviewers' panes have closed.
-- Returns its name.
function M.open_ask(e, space)
  local name = M.ask_pane(e)
  if get(name) then
    return name
  end
  local res = agent({
    "start", name, "-s", space, "--plain", "--rm", "--role", "ask",
    "--tab-id", e.pane or name, "--cwd", e.worktree or util.HOME,
    "--kind", "env", "--", unpack(own({ "luajit", config.ROOT .. "/scripts/ask.lua",
      "item=" .. status.item_id(e.repo, e.pr, e.round) })),
  })
  if not res.ok then
    error("the post terminal didn't open: " .. util.trim(res.stderr):sub(1, 200), 0)
  end
  return name
end

---------------------------------------------------------------------------
-- The doctor

local function version_of(cmd)
  local res = util.run({ cmd, "--version" }, { check = false })
  return res.ok and res.stdout:match("(%d+%.%d+%.%d+)") or nil
end

local function older(v, min)
  local a, b = {}, {}
  for n in v:gmatch("%d+") do
    a[#a + 1] = tonumber(n)
  end
  for n in min:gmatch("%d+") do
    b[#b + 1] = tonumber(n)
  end
  for i = 1, 3 do
    if (a[i] or 0) ~= (b[i] or 0) then
      return (a[i] or 0) < (b[i] or 0)
    end
  end
  return false
end

-- { check, ok, detail } for herdr-core and the app.
function M.checks()
  local out = {}
  local hc = version_of("hc")
  out[#out + 1] = {
    check = "herdr-core", ok = hc ~= nil and not older(hc, M.MIN_HC),
    detail = hc and ("hc " .. hc .. (older(hc, M.MIN_HC) and (", older than " .. M.MIN_HC .. "; run hc update") or ""))
      or "hc isn't on PATH; install herdr-core",
  }
  local app = version_of("herdr-app")
  out[#out + 1] = {
    check = "Herdr app", ok = true,
    detail = app and ("herdr-app " .. app .. (older(app, M.MIN_APP) and (", older than " .. M.MIN_APP) or ""))
      or "not installed; the panes still run, and show in the phone app",
  }
  return out
end

return M
