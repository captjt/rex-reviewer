-- The watcher in Rex. reviewer_up runs it in the control tab of the
-- rex-reviewer session, inside a loop that restarts it:
--
--   rex do <rex-reviewer>/scripts/watch.lua
--
-- Every poll_seconds it checks GitHub once and applies the rules. Whenever a
-- pane in the session changes status, and after every check, it moves each
-- PR one step. It spends no tokens. lua/rex_reviewer/loop.lua is the step,
-- and the status the watcher's pane reports; it also writes watcher.json,
-- which the menu bar app reads. scripts/watch-herdr.lua is the same watcher
-- on Herdr.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local loop = require("rex_reviewer.loop")

local function log(line, raw)
  rex.log(raw and line or (os.date("!%H:%M:%SZ") .. "  " .. line))
end

local c = config.load()
if c.host ~= "rex" then
  -- The config moved to another host. Wait a while before Rex's restart
  -- loop runs this again; reviewer_down closes this pane.
  log(string.format("host is %s in the config, so this Rex watcher does nothing; rex-reviewer down closes it", c.host))
  util.run({ "sleep", "300" }, { check = false })
  return
end

local w = loop.new(rex.session_id, log)

-- A pane's status changing can move a round on. The watcher's own records
-- changing can't, so its own pane is left out.
rex.on("com.superlogical.terminal.program_status_changed", function(ctx)
  if ctx and rex.block_id and ctx.block_id == rex.block_id then
    return
  end
  w.step(false)
end)

w.banner()
w.clear()
w.step(true)
rex.every(c.poll_seconds, function()
  w.step(true)
end)

-- A client's "check now" leaves this file; it's picked up within 5 seconds.
rex.every(5, function()
  if not w.busy() and os.remove(ledger.check_now_path()) then
    w.step(true)
  end
end)
