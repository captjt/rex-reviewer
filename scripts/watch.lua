-- The watcher. reviewer_up runs it in the control tab of the rex-reviewer
-- session, inside a loop that restarts it:
--
--   rex do <rex-reviewer>/scripts/watch.lua
--
-- Every poll_seconds it checks GitHub once and applies the rules. Whenever a
-- pane in the session changes status, and after every check, it moves each
-- PR one step. It spends no tokens.
--
-- It sets its own pane's status, so the Rex app notifies you: blocked when a
-- round needs you, error when a check fails, idle otherwise. It also writes
-- watcher.json, which the menu bar app reads.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local ledger = require("rex_reviewer.ledger")
local watcher = require("rex_reviewer.watcher")

local c = config.load()
local session = rex.session_id
local last_status

local function log(line)
  rex.log(os.date("!%H:%M:%SZ") .. "  " .. line)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, cc = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (cc or 0)
    out[#out + 1] = B64:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
      .. B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
      .. (b and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
      .. (cc and B64:sub(n % 64 + 1, n % 64 + 1) or "=")
  end
  return table.concat(out)
end

-- Set this pane's status (OSC 7501), so the Rex app's own notifications
-- cover the watcher.
local function set_status(state, msg)
  local key = state .. "|" .. (msg or "")
  if key == last_status then
    return
  end
  local fields = "state=" .. state
  if msg and msg ~= "" then
    fields = fields .. ":msg=" .. b64(msg)
  end
  io.write("\27]7501;" .. fields .. "\27\\")
  io.flush()
  last_status = key
end

local function summary(attention)
  local bits = {}
  for _, a in ipairs(attention) do
    bits[#bits + 1] = string.format("%s#%d: %s", a.repo:match("/(.+)$") or a.repo, a.pr, a.text)
  end
  return table.concat(bits, "; ")
end

local busy = false
local function step(check_github)
  if busy then
    return
  end
  busy = true
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
    if #attention > 0 then
      for _, a in ipairs(attention) do
        log(string.format("needs you: %s#%d: %s", a.repo, a.pr, a.text))
      end
      set_status("blocked", "rex-reviewer: " .. summary(attention))
    elseif check_failed then
      set_status("error", "rex-reviewer: GitHub check failed")
    else
      set_status("idle")
    end
  end)
  busy = false
  if not ok then
    log("step failed: " .. tostring(err))
    set_status("error", "rex-reviewer: " .. tostring(err):sub(1, 120))
    pcall(ledger.save_watcher, { attention = {}, error = tostring(err):sub(1, 200) })
  end
end

rex.on("com.superlogical.terminal.program_status_changed", function()
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
step(true)
rex.every(c.poll_seconds, function()
  step(true)
end)

-- A client's "check now" leaves this file; it's picked up within 5 seconds.
rex.every(5, function()
  if not busy and os.remove(ledger.check_now_path()) then
    step(true)
  end
end)
