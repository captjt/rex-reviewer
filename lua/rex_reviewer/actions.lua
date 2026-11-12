-- The actions: what people, apps and agents can ask rex-reviewer to do.
-- In Rex, init.lua registers each as a Rex action (`rex do reviewer_post
-- pr=12`). Anywhere else, scripts/cli.lua runs them under LuaJIT
-- (`rex-reviewer do reviewer_post pr=12`). Each is
--
--   { name, title, args, run = function(a) … end, rex = false? }
--
-- args maps each argument to its type, as Rex declares them ("integer",
-- "string?", …). rex = false keeps an action out of Rex, which cuts actions
-- off at 30 s.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")
local rounds = require("rex_reviewer.rounds")
local watcher = require("rex_reviewer.watcher")
local status = require("rex_reviewer.status")
local host = require("rex_reviewer.host")

local M = { list = {}, by_name = {} }

-- The repo an action acts on: repo= when given, else the only one that fits.
local function repo_of(a)
  return config.repo(a.repo, a.pr, ledger).slug
end

-- The PR an action acts on, as repo and number. item= is the id of a status
-- record the watcher reports (see lua/rex_reviewer/status.lua), so a client
-- such as rex-inbox can act on the item it showed. It must still name the
-- round in progress, and, when phase is given, a round in that phase.
-- Otherwise pr= and repo= name the PR.
function M.target(a, phase)
  if a.item and a.item ~= "" then
    local repo, pr, round = status.resolve(a.item, config.load().repo_list)
    local e = ledger.load(repo, pr)
    local label = ledger.label({ repo = repo, pr = pr })
    if not e or e.state ~= "reviewing" or e.round ~= round then
      error(string.format("%s round %d is over; nothing was done", label, round), 0)
    end
    local now = e.phase or "reviewer"
    if phase and now ~= phase then
      error(string.format("%s round %d isn't waiting for you (its phase is %s); nothing was done", label, round, now), 0)
    end
    return repo, pr
  end
  if not a.pr then
    error("pass pr= (and repo= when more than one repo is configured), or item=", 0)
  end
  return repo_of(a), a.pr
end

local PR = { pr = "integer?", repo = "string?", item = "string?" }

local function action(name, title, args, run, opts)
  local a = { name = name, title = title, args = args, run = run, rex = not (opts and opts.rex == false) }
  M.list[#M.list + 1] = a
  M.by_name[name] = a
end

action("reviewer_status", "status", nil, function()
  return watcher.status()
end)

action("reviewer_doctor", "check the setup", nil, function()
  return watcher.doctor()
end)

-- Start or repair the watcher on the host. A LaunchAgent runs it with
-- auto=true, which leaves a watcher stopped with reviewer_down alone.
action("reviewer_up", "start or repair the watcher", { auto = "boolean?" }, function(a)
  return watcher.up({ auto = a.auto })
end)

action("reviewer_down", "stop the watcher", nil, function()
  return watcher.down()
end)

action("reviewer_pause", "pause new rounds", nil, function()
  return ledger.set_paused(true)
end)

action("reviewer_resume", "resume new rounds", nil, function()
  return ledger.set_paused(false)
end)

-- Ask the watcher to check GitHub now. It looks for the request every 5 s.
action("reviewer_check", "check GitHub now", nil, function()
  util.mkdirp(config.STATE_DIR)
  util.write_file(ledger.check_now_path(), "")
  return { requested = true }
end)

action("reviewer_scan", "check GitHub (dry run unless save=true)", { save = "boolean?" }, function(a)
  local evs = watcher.scan({ dry = not a.save })
  return { dry_run = not a.save, events = evs }
end)

action("reviewer_pickup", "review a PR that didn't request you", { pr = "integer", repo = "string?" }, function(a)
  return rounds.pickup(repo_of(a), a.pr)
end)

action("reviewer_prep", "prepare a PR's worktree and context", { pr = "integer", repo = "string?" }, function(a)
  return rounds.prep(repo_of(a), a.pr)
end)

-- Starting a round takes longer than Rex allows an action (30 s), so in Rex
-- it's a script: rex do <rex-reviewer>/scripts/start.lua pr=<n>
action("reviewer_start", "start a PR's next round now (after reviewer_prep)", { pr = "integer", repo = "string?", session = "string?" }, function(a)
  return rounds.start(repo_of(a), a.pr, a.session or host.home_scope())
end, { rex = false })

action("reviewer_preview", "render the checked review without posting", PR, function(a)
  local repo, pr = M.target(a)
  return rounds.post(repo, pr, { dry = true })
end)

-- With item=, only a review that waits for you: with post = "auto", the
-- checker posts by pr=.
action("reviewer_post", "post the checked review", PR, function(a)
  local repo, pr = M.target(a, "awaiting")
  return rounds.post(repo, pr)
end)

action("reviewer_dismiss", "end a round without posting", PR, function(a)
  local repo, pr = M.target(a)
  return rounds.dismiss(repo, pr)
end)

action("reviewer_cleanup", "clean up a merged or closed PR", { pr = "integer", repo = "string?" }, function(a)
  local slug = repo_of(a)
  local e = ledger.load(slug, a.pr)
  local home = host.home_scope()
  return rounds.cleanup(slug, a.pr, e and host.scope(e, home, host.live_scopes()) or home)
end)

action("reviewer_focus", "show a round's tab, or the watcher's", PR, function(a)
  if a.pr or (a.item and a.item ~= "") then
    return watcher.focus(M.target(a))
  end
  return watcher.focus(nil, nil)
end)

---------------------------------------------------------------------------
-- Arguments from a command line

-- key=value strings as an action's arguments, typed as its args declare.
-- Errors name what's wrong, as Rex's do.
function M.parse(spec, words)
  spec = spec or {}
  local out = {}
  for _, w in ipairs(words) do
    local k, v = w:match("^([%w_]+)=(.*)$")
    if not k then
      error(string.format("arguments look like key=value, not %s", w), 0)
    end
    local kind = spec[k]
    if not kind then
      local names = {}
      for name in pairs(spec) do
        names[#names + 1] = name
      end
      table.sort(names)
      error(string.format("unknown argument %s; this action takes %s", k, #names > 0 and table.concat(names, ", ") or "none"), 0)
    end
    kind = kind:gsub("%?$", "")
    if kind == "integer" then
      local n = tonumber(v)
      if not n or n ~= math.floor(n) then
        error(string.format("%s must be a whole number, not %s", k, v), 0)
      end
      out[k] = n
    elseif kind == "boolean" then
      if v ~= "true" and v ~= "false" then
        error(string.format("%s must be true or false, not %s", k, v), 0)
      end
      out[k] = v == "true"
    else
      out[k] = v
    end
  end
  for k, kind in pairs(spec) do
    if not kind:match("%?$") and out[k] == nil then
      error(string.format("%s is required", k), 0)
    end
  end
  return out
end

return M
