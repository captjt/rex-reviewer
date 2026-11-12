-- The host: what runs the panes. `host` in the config picks one, Rex by
-- default. Each is a module in lua/rex_reviewer/hosts/ with these calls:
--
--   name                        "rex" or "herdr"
--   driver()                    the agent driver: bin/rex-agent or bin/hc-agent,
--                               with the same commands, JSON and exit codes
--   watch_script()              the watcher's script
--   programs                    what the doctor looks for on PATH
--   live_scopes()               the sessions (spaces) that exist, or nil if all do
--   scope(e, fallback, live)    the session a PR's panes are in
--   home_scope()                the watcher's session
--   start_watcher()             start the watcher unless it runs
--   stop_watcher()              stop it; returns what it closed
--   show(scope, pane)           show a pane, or "watcher", in the app
--   action_cmd(action, args)    the command an agent runs for an action
--   allow(action)               Claude Code's permission rule for it
--   agent_args(agent)           extra args an agent needs on this host
--   open_ask(e, scope)          optional: open a round's post terminal
--   checks()                    optional: the doctor's host checks
--
-- The rest of rex-reviewer calls host.<name>, which goes to the configured
-- host's module.

local config = require("rex_reviewer.config")

local M = {}
local loaded = {}

function M.get(name)
  name = name or config.load().host
  if not loaded[name] then
    loaded[name] = require("rex_reviewer.hosts." .. name)
  end
  return loaded[name]
end

return setmetatable(M, {
  __index = function(_, k)
    return M.get()[k]
  end,
})
