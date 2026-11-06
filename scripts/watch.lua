-- The watcher. reviewer_up runs it in the control tab of the rex-reviewer
-- session, inside a loop that restarts it:
--
--   rex do <rex-reviewer>/scripts/watch.lua
--
-- Every poll_seconds it checks GitHub once and applies the rules. Whenever a
-- pane in the session changes status, and after every check, it moves each
-- PR one step. It spends no tokens.
--
-- It reports its pane's status (OSC 7501), so Rex shows what needs you: one
-- record for each PR that does (a review ready to post, a stopped agent, a
-- failed start), and the watcher's own record, idle, or error when a check
-- fails. lua/rex_reviewer/status.lua says what the records hold. It also
-- writes watcher.json, which the menu bar app reads.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local ledger = require("rex_reviewer.ledger")
local watcher = require("rex_reviewer.watcher")
local status = require("rex_reviewer.status")

local c = config.load()
local session = rex.session_id
-- What the closures share lives in tables: after pcall catches an error,
-- Rex's Lua can detach a closure's view of a reassigned outer local.
local run = { busy = false }
local shown = {}

local function log(line)
  rex.log(os.date("!%H:%M:%SZ") .. "  " .. line)
end

local function report(root, items)
  local out = status.sync(shown, root, items)
  if #out > 0 then
    io.write(table.concat(out))
    io.flush()
  end
end

local function step(check_github)
  if run.busy then
    return
  end
  run.busy = true
  local ok, err = pcall(function()
    local check_failed
    if check_github then
      local ok_scan, evs = pcall(watcher.scan)
      if not ok_scan then
        check_failed = tostring(evs)
        log("GitHub check failed: " .. check_failed)
      else
        for _, ev in ipairs(evs) do
          rex.log(ledger.format_event(ev))
        end
      end
    end
    local attention = watcher.advance(session, log)
    ledger.save_watcher({ attention = attention, check_failed = check_failed })
    for _, a in ipairs(attention) do
      log(string.format("needs you: %s#%d: %s", a.repo, a.pr, a.text))
    end
    report(status.root({
      error = check_failed and ("GitHub check failed: " .. check_failed) or nil,
      paused = ledger.paused(),
    }), attention)
  end)
  run.busy = false
  if not ok then
    log("step failed: " .. tostring(err))
    -- Keep the items already shown; only the watcher's own record changes.
    pcall(report, status.root({ error = "step failed: " .. tostring(err) }), nil)
    pcall(ledger.save_watcher, { attention = {}, error = tostring(err):sub(1, 200) })
  end
end

-- A pane's status changing can move a round on. The watcher's own records
-- changing can't, so its own pane is left out.
rex.on("com.superlogical.terminal.program_status_changed", function(ctx)
  if ctx and rex.block_id and ctx.block_id == rex.block_id then
    return
  end
  step(false)
end)

local repos = {}
for _, r in ipairs(c.repo_list) do
  repos[#repos + 1] = r.slug
end
local reviewers = {}
for _, r in ipairs(c.reviewer_list) do
  reviewers[#reviewers + 1] = r.name == r.agent and r.name or (r.name .. " (" .. r.agent .. ")")
end
log(string.format(
  "rex-reviewer watcher: %s; %s %s, %s checks, post=%s; every %ds, up to %d rounds%s",
  table.concat(repos, ", "), table.concat(reviewers, " and "), #reviewers > 1 and "review" or "reviews",
  c.checker, c.post, c.poll_seconds, c.max_rounds,
  ledger.paused() and " (paused)" or ""
))
-- A watcher before this one may have left records behind (an error outlives
-- its process), so start from none.
io.write(status.CLEAR_ALL)
io.flush()
step(true)
rex.every(c.poll_seconds, function()
  step(true)
end)

-- A client's "check now" leaves this file; it's picked up within 5 seconds.
rex.every(5, function()
  if not run.busy and os.remove(ledger.check_now_path()) then
    step(true)
  end
end)
