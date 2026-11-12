-- The watcher's loop, on either host. A step checks GitHub when asked,
-- moves each PR one step, writes watcher.json, and reports the watcher's
-- program status (OSC 7501) on its own pane: one record for each PR that
-- needs you (a review ready to post, a stopped agent, a failed start), and
-- the watcher's own record, idle, or error when a check fails.
-- lua/rex_reviewer/status.lua says what the records hold.
--
-- scripts/watch.lua runs it from Rex's timers and events, and
-- scripts/watch-herdr.lua from hc's events and a tick.

local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")
local watcher = require("rex_reviewer.watcher")
local status = require("rex_reviewer.status")

local M = {}

-- A loop for the watcher of session (the session or space its rounds open
-- in). log takes a line.
function M.new(session, log)
  -- What the closures share lives in tables: after pcall catches an error,
  -- Rex's Lua can detach a closure's view of a reassigned outer local.
  local run = { busy = false }
  local shown = {}
  local self = {}

  local function report(root, items)
    local out = status.sync(shown, root, items)
    if #out > 0 then
      io.write(table.concat(out))
      io.flush()
    end
  end

  function self.busy()
    return run.busy
  end

  function self.step(check_github)
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
            log(ledger.format_event(ev), true)
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

  -- A watcher before this one may have left records behind (an error
  -- outlives its process), so start from none.
  function self.clear()
    io.write(status.CLEAR_ALL)
    io.flush()
  end

  -- The first line the watcher logs: what it watches, and how.
  function self.banner(host_name)
    local c = config.load()
    local repos = {}
    for _, r in ipairs(c.repo_list) do
      repos[#repos + 1] = r.slug
    end
    local reviewers = {}
    for _, r in ipairs(c.reviewer_list) do
      reviewers[#reviewers + 1] = r.name == r.agent and r.name or (r.name .. " (" .. r.agent .. ")")
    end
    log(string.format(
      "rex-reviewer watcher%s: %s; %s %s, %s checks, post=%s; every %ds, up to %d rounds%s",
      host_name and (" on " .. host_name) or "",
      table.concat(repos, ", "), table.concat(reviewers, " and "), #reviewers > 1 and "review" or "reviews",
      c.checker, c.post, c.poll_seconds, c.max_rounds,
      ledger.paused() and " (paused)" or ""
    ))
  end

  return self
end

return M
