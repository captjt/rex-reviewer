-- The watcher on Herdr, under LuaJIT. scripts/watch-herdr.sh runs it with
-- hc's events for rex-reviewer's terminals on stdin, one JSON line each,
-- and a {"tick":true} line every 5 seconds:
--
--   a status change, exit, or removal    a step soon (at the next tick)
--   every poll_seconds                   check GitHub, then a step
--   check-now left by a client           the same, within 5 seconds
--
-- lua/rex_reviewer/loop.lua is the step, and the status this terminal
-- reports (OSC 7501), which herdr-core keeps and the Herdr apps show.
-- scripts/watch.lua is the same watcher in Rex.

-- This checkout, from where this script is, made absolute: the actions run
-- commands from the home folder.
local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
if SRC:sub(1, 1) ~= "/" then
  SRC = (os.getenv("PWD") or ".") .. "/" .. SRC
end
local ROOT = SRC:match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local loop = require("rex_reviewer.loop")
local host = require("rex_reviewer.host")
local requests = require("rex_reviewer.requests")
local actions = require("rex_reviewer.actions")

-- The checker's preview and post: the watcher runs them for it, outside
-- its sandbox (see lua/rex_reviewer/requests.lua).
local function run_action(name, args)
  return actions.by_name[name].run(args)
end

local function log(line, raw)
  io.write(raw and line or (os.date("!%H:%M:%SZ") .. "  " .. line), "\n")
  io.flush()
end

local c = config.load()
if c.host ~= "herdr" then
  log(string.format("host is %s in the config, so this Herdr watcher does nothing; rex-reviewer down closes it", c.host))
  util.run({ "sleep", "300" }, { check = false })
  return
end

-- Events that can move a round on: an agent's status, or its terminal
-- ending or going away.
local MOVES = { status = true, finished = true, removed = true, lost = true }

local w = loop.new(host.home_scope(), log)
w.banner("Herdr")
w.clear()
w.step(true)

local state = { last_check = os.time(), dirty = false, ticks = 0 }
for line in io.lines() do
  local msg = util.decode(line)
  if type(msg) ~= "table" then
    -- Not JSON: ignore it.
  elseif msg.tick then
    state.ticks = state.ticks + 1
    local ok, err = pcall(requests.serve, run_action, log)
    if not ok then
      log("requests failed: " .. tostring(err))
    end
    -- The app adopts the watcher's terminal soon after it starts; name its
    -- space and tab then, once.
    if state.ticks == 2 then
      pcall(host.decorate)
    end
    if os.remove(ledger.check_now_path()) or os.time() - state.last_check >= c.poll_seconds then
      state.last_check, state.dirty = os.time(), false
      w.step(true)
    elseif state.dirty then
      state.dirty = false
      w.step(false)
    end
  elseif msg.method == "event" and type(msg.params) == "table" and MOVES[msg.params.type] then
    state.dirty = true
  elseif msg.method == "missed" then
    state.dirty = true
  end
end
log("the event stream ended")
