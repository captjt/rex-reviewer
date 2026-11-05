-- The watcher's logic: check GitHub, move each PR one step, and keep the
-- rex-reviewer session and its watcher pane alive. scripts/watch.lua runs
-- it; the actions in init.lua call the rest.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")
local rules = require("rex_reviewer.rules")
local github = require("rex_reviewer.github")
local rounds = require("rex_reviewer.rounds")

local M = {}

local function rex_cli(args)
  return util.run(util.append({ "rex" }, args))
end

---------------------------------------------------------------------------
-- Checking GitHub

function M.scan(opts)
  opts = opts or {}
  local by, tracked = {}, {}
  for _, e in ipairs(ledger.list()) do
    by[e.repo .. "#" .. e.pr] = e
    if not ledger.FINISHED[e.state] then
      tracked[e.repo] = tracked[e.repo] or {}
      table.insert(tracked[e.repo], e.pr)
    end
  end
  local data, login = github.query(tracked)
  local obs = github.observe(data, tracked, login)
  local now = util.now()
  local all = {}
  for _, r in ipairs(config.load().repo_list) do
    local prs = {}
    for n in pairs(obs[r.slug] or {}) do
      prs[#prs + 1] = n
    end
    table.sort(prs)
    for _, n in ipairs(prs) do
      local e, evs = rules.decide(by[r.slug .. "#" .. n], obs[r.slug][n], now)
      if e and not opts.dry then
        ledger.save(e)
      end
      for _, ev in ipairs(evs) do
        all[#all + 1] = opts.dry and ev or ledger.append_event(ev)
      end
    end
  end
  if not opts.dry then
    ledger.update_state(function(st)
      st.last_scan_at = now
      st.login = login
    end)
  end
  return all
end

---------------------------------------------------------------------------
-- One step for every PR. Returns what needs you: { repo, pr, kind, text }.

local function needs(list, e, kind, text)
  list[#list + 1] = { repo = e.repo, pr = e.pr, kind = kind, text = text }
end

function M.advance(session, log)
  log = log or function() end
  local c = config.load()
  local entries = ledger.list()
  -- Rounds waiting on you don't hold a slot.
  local active = 0
  for _, e in ipairs(entries) do
    if e.state == "reviewing" and e.phase ~= "awaiting" then
      active = active + 1
    end
  end
  local attention = {}
  for _, e in ipairs(entries) do
    local label = ledger.label(e)
    local ok, err = pcall(function()
      local session = e.session_id or session
      if e.state == "merged" or e.state == "closed" then
        rounds.cleanup(e.repo, e.pr, session)
        log(string.format("%s %s: cleaned up", label, e.state))
      elseif e.state == "posted" then
        if (e.pane or e.checker_pane) and rounds.pane_state(session, e.checker_pane) ~= "working" then
          rounds.close_panes(e, session)
          e.pane, e.checker_pane, e.phase = nil, nil, nil
          ledger.save(e)
          log(string.format("%s round %d %s; closed its tab", label, e.round, e.verdict or "ended"))
        end
      elseif e.state == "queued" then
        local waiting = e.start_failed_epoch and os.time() - e.start_failed_epoch < 120
        if waiting then
          needs(attention, e, "start-failed", e.start_error or "the round didn't start")
        elseif not ledger.paused() and active < c.max_rounds then
          local ok_start, err_start = pcall(function()
            rounds.prep(e.repo, e.pr)
            rounds.start(e.repo, e.pr, session)
          end)
          if not ok_start then
            local f = ledger.load(e.repo, e.pr)
            f.start_error = tostring(err_start)
            f.start_failed_epoch = os.time()
            ledger.save(f)
            error(err_start, 0)
          end
          active = active + 1
          log(string.format("%s round %d: opened %s", label, e.round + 1, rounds.reviewer_pane(e)))
        end
      elseif e.state == "reviewing" then
        local st = rounds.status(e)
        local phase = e.phase or "reviewer"
        if phase == "reviewer" then
          -- Every reviewer must finish before the checker starts. Each
          -- reports in its own worktree's status.
          local p = rounds.progress(e, session)
          if e.reviewers_done ~= p.done or e.reviewers_total ~= p.total then
            e.reviewers_done, e.reviewers_total = p.done, p.total
            ledger.save(e)
          end
          local many = p.total > 1
          if p.blocked then
            needs(attention, e, "blocked", many and (p.blocked.name .. ": " .. p.blocked.why) or p.blocked.why)
          elseif p.ready then
            local head = github.live_head(e.repo, e.pr)
            if head == e.round_head then
              rounds.start_checker(e, session)
              log(string.format("%s round %d: reviewed; the checker is checking", label, e.round))
            else
              log(string.format("%s round %d: head moved to %s; %s", label, e.round, util.short(head), rounds.follow_head(e, session, head)))
            end
          elseif p.closed then
            needs(attention, e, "pane-closed", many and string.format("the %s reviewer's pane closed mid-round", p.closed) or "the reviewer's pane closed mid-round")
          end
        elseif st:match("^BLOCKED") then
          needs(attention, e, "blocked", (st:gsub("^BLOCKED:?%s*", "")))
        elseif st == "AWAITING_APPROVAL" then
          if phase ~= "awaiting" then
            e.phase = "awaiting"
            ledger.save(e)
            ledger.append_event({ kind = "awaiting", repo = e.repo, pr = e.pr, round = e.round, head = e.round_head })
          end
          if e.head and e.head ~= e.round_head then
            log(string.format("%s round %d: the head moved while it waited; %s", label, e.round, rounds.follow_head(e, session, e.head)))
          else
            needs(attention, e, "ready", "the checked review is ready to post")
          end
        elseif phase == "checking" and st == "HEAD_MOVED" then
          local head = github.live_head(e.repo, e.pr)
          log(string.format("%s round %d: head moved to %s; %s", label, e.round, util.short(head), rounds.follow_head(e, session, head)))
        elseif phase == "checking" and st:match("^VERIFYING") and not rounds.pane_state(session, e.checker_pane) then
          needs(attention, e, "pane-closed", "the checker's pane closed before it finished")
        end
      end
    end)
    if not ok then
      needs(attention, e, "error", tostring(err):sub(1, 200))
      log(string.format("%s: %s", label, tostring(err)))
    end
  end
  return attention
end

---------------------------------------------------------------------------
-- The session and its watcher pane

function M.watch_script()
  return config.ROOT .. "/scripts/watch.lua"
end

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

-- Make sure the session exists with a running watcher. Safe to run any time;
-- a LaunchAgent can run it every few minutes. With auto, a watcher stopped
-- with down stays stopped; a plain up starts it again. The session is found
-- by the ID in state.json, because agents in its panes can rename it.
function M.up(opts)
  opts = opts or {}
  local label = config.load().session
  local st = ledger.load_state()
  if st.stopped and opts.auto then
    return { stopped = true, note = "stopped with reviewer_down; run reviewer_up to start it" }
  end
  if st.stopped then
    st.stopped = nil
    ledger.save_state(st)
    ledger.append_event({ kind = "started" })
  end
  ledger.update_state(function(s)
    s.watch_script = M.watch_script()
  end)
  local sessions = (rex.call("session.list", {}) or {}).sessions or {}
  local sid
  for _, s in ipairs(sessions) do
    if st.session_id and s.session_id == st.session_id then
      sid = s.session_id
    end
  end
  if not sid then
    for _, s in ipairs(sessions) do
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

-- Stop the watcher until the next plain up. Review tabs stay open; their
-- rounds carry on from where they are.
function M.down()
  local st = ledger.update_state(function(s)
    s.stopped = true
  end)
  ledger.append_event({ kind = "stopped" })
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
  return { stopped = true, closed = closed }
end

local function block_window(sid, bid)
  local blocks = util.decode(rex_cli({ "block", "ls", "-s", sid, "--json" }).stdout).blocks or {}
  for _, b in ipairs(blocks) do
    if b.block_id == bid or (bid == "watcher" and b.label == "watcher") then
      return b.block_id, b.window_id
    end
  end
end

-- Show a round in the Rex app, or the watcher with no PR: focus the pane,
-- then take the app to its session and tab. The app takes that only with
-- Remote Control on (Settings, Rex Server); without it, selected is false.
function M.focus(repo, pr)
  local st = ledger.load_state()
  local sid, bid, wid
  if pr then
    local e = ledger.load(repo, pr)
    if not e or e.state ~= "reviewing" then
      error(string.format("%s#%d has no round in progress", repo, pr), 0)
    end
    sid = e.session_id or st.session_id
    local names = {}
    for _, r in ipairs(rounds.round_reviewers(e)) do
      names[#names + 1] = r.pane
    end
    if e.checker_pane then
      table.insert(names, e.phase == "reviewer" and #names + 1 or 1, e.checker_pane)
    end
    for i = 1, #names do
      local _, b = rounds.pane_state(sid, names[i])
      if b then
        bid, wid = block_window(sid, b)
        if bid then
          break
        end
      end
    end
    if not bid then
      error(string.format("%s#%d has no open tab", repo, pr), 0)
    end
  else
    sid = st.session_id
    if sid then
      bid, wid = block_window(sid, "watcher")
    end
    if not bid then
      error("the watcher isn't running; start it with reviewer_up", 0)
    end
  end
  rex_cli({ "focus", "-s", sid, bid })
  local selected, err = pcall(rex_cli, { "do", "session.select", "session_id=" .. sid, "window_id=" .. wid })
  return {
    repo = repo, pr = pr, session_id = sid, block_id = bid, selected = selected,
    note = not selected and tostring(err):match("Rex%.app is not accepting actions") and "remote control off" or nil,
  }
end

---------------------------------------------------------------------------
-- Status and doctor

function M.status()
  local prs = {}
  for _, e in ipairs(ledger.list()) do
    prs[#prs + 1] = {
      repo = e.repo,
      pr = e.pr,
      title = e.title,
      author = e.author,
      round = e.round,
      state = e.state,
      phase = e.state == "reviewing" and (e.phase or "reviewer") or nil,
      reviewers_done = e.state == "reviewing" and e.reviewers_done or nil,
      reviewers_total = e.state == "reviewing" and e.reviewers_total or nil,
      verdict = e.verdict,
      merge_risk = e.merge_risk,
      head = util.short(e.head),
      worktree = e.worktree,
    }
  end
  local st = ledger.load_state()
  return {
    stopped = st.stopped == true, paused = st.paused == true, post = config.load().post,
    last_scan_at = st.last_scan_at, last_event = st.seq, prs = prs,
  }
end

-- Check what the tool needs, and say what's missing.
function M.doctor()
  local checks = {}
  local function check(name, ok, detail)
    checks[#checks + 1] = { check = name, ok = ok and true or false, detail = detail }
  end
  local ok, c = pcall(config.load)
  check("config", ok, ok and config.path() or tostring(c))
  if not ok then
    return { ok = false, checks = checks }
  end
  local programs = { "rex", "gh", "git", "jq", "perl", "uuidgen", "claude" }
  for _, r in ipairs(c.reviewer_list) do
    programs[#programs + 1] = r.agent
    if r.agent == "codex" then
      programs[#programs + 1] = "sqlite3"
    end
  end
  local seen = {}
  for _, p in ipairs(programs) do
    if not seen[p] then
      seen[p] = true
      local res = util.run({ "/bin/sh", "-c", 'command -v "$1"', "sh", p }, { check = false })
      check(p, res.ok, res.ok and util.trim(res.stdout) or "not on PATH; add its folder to path in the config")
    end
  end
  local gh = util.run({ "gh", "api", "user", "--jq", ".login" }, { check = false })
  check("gh signed in", gh.ok, gh.ok and util.trim(gh.stdout) or util.trim(gh.stderr))
  for _, r in ipairs(c.repo_list) do
    local res = util.run({ "git", "-C", r.checkout, "remote", "get-url", "origin" }, { check = false })
    local url = util.trim(res.stdout)
    local matches = res.ok and (url:find(r.slug, 1, true) ~= nil)
    check(r.slug, matches, res.ok and (matches and r.checkout or ("origin is " .. url .. ", not " .. r.slug)) or (r.checkout .. " isn't a git checkout"))
    for _, slot in ipairs({ "review", "style", "merge_risk", "check" }) do
      local gok, g = pcall(config.guide, r, slot, { repo = r.slug, pr = 0 })
      if not gok then
        check(r.slug .. " guides." .. slot, false, tostring(g))
      end
    end
    for _, rv in ipairs(c.reviewer_list) do
      if rv.guides.review ~= nil then
        local gok, g = pcall(config.guide, r, "review", { repo = r.slug, pr = 0 }, rv)
        if not gok then
          check(r.slug .. " reviewers." .. rv.name .. ".guides.review", false, tostring(g))
        end
      end
    end
  end
  local names = {}
  for _, rv in ipairs(c.reviewer_list) do
    names[#names + 1] = rv.name .. " (" .. rv.agent .. ")"
  end
  check("reviewers", true, table.concat(names, ", ") .. "; the first is the primary")
  local all = true
  for _, ch in ipairs(checks) do
    all = all and ch.ok
  end
  return { ok = all, checks = checks }
end

return M
