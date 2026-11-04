-- rex-reviewer: Rex actions for agent PR reviews.
--
-- Load it from ~/.config/rex/init.lua:
--
--   dofile(os.getenv("HOME") .. "/path/to/rex-reviewer/init.lua")
--
-- The actions read ~/.config/rex-reviewer/config.lua when they run, so a bad
-- config shows up as an action error, and `rex do reviewer_doctor` says what's
-- wrong.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path

local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local rounds = require("rex_reviewer.rounds")
local watcher = require("rex_reviewer.watcher")

-- The repo an action acts on: repo= when given, else the only one that fits.
local function repo_of(a)
  return config.repo(a.repo, a.pr, ledger).slug
end

local function action(name, title, args, run)
  rex.action({ name = name, title = "Rex Reviewer: " .. title, args = args, run = run })
end

action("reviewer_status", "status", nil, function()
  return watcher.status()
end)

action("reviewer_doctor", "check the setup", nil, function()
  return watcher.doctor()
end)

-- Start or repair the rex-reviewer session and its watcher. A LaunchAgent
-- runs it with auto=true, which leaves a watcher stopped with reviewer_down
-- alone.
action("reviewer_up", "start or repair the watcher", { auto = "boolean?" }, function(_, a)
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

action("reviewer_scan", "check GitHub (dry run unless save=true)", { save = "boolean?" }, function(_, a)
  local evs = watcher.scan({ dry = not a.save })
  return { dry_run = not a.save, events = evs }
end)

action("reviewer_pickup", "review a PR that didn't request you", { pr = "integer", repo = "string?" }, function(_, a)
  return rounds.pickup(repo_of(a), a.pr)
end)

action("reviewer_prep", "prepare a PR's worktree and context", { pr = "integer", repo = "string?" }, function(_, a)
  return rounds.prep(repo_of(a), a.pr)
end)

-- Starting a round takes longer than Rex allows an action (30 s), so it's a
-- script: rex do <rex-reviewer>/scripts/start.lua pr=<n>

action("reviewer_preview", "render the checked review without posting", { pr = "integer", repo = "string?" }, function(_, a)
  return rounds.post(repo_of(a), a.pr, { dry = true })
end)

action("reviewer_post", "post the checked review", { pr = "integer", repo = "string?" }, function(_, a)
  return rounds.post(repo_of(a), a.pr)
end)

action("reviewer_dismiss", "end a round without posting", { pr = "integer", repo = "string?" }, function(_, a)
  return rounds.dismiss(repo_of(a), a.pr)
end)

action("reviewer_cleanup", "clean up a merged or closed PR", { pr = "integer", repo = "string?" }, function(_, a)
  local slug = repo_of(a)
  local e = ledger.load(slug, a.pr)
  return rounds.cleanup(slug, a.pr, e and e.session_id or ledger.load_state().session_id)
end)

action("reviewer_focus", "show a round's tab, or the watcher's", { pr = "integer?", repo = "string?" }, function(_, a)
  if a.pr then
    return watcher.focus(repo_of(a), a.pr)
  end
  return watcher.focus(nil, nil)
end)
