-- The watcher's logic: check GitHub, move each PR one step, and keep the
-- watcher running on the host. scripts/watch.lua (Rex) and
-- scripts/watch-herdr.lua (Herdr) run it; the actions call the rest.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")
local rules = require("rex_reviewer.rules")
local github = require("rex_reviewer.github")
local rounds = require("rex_reviewer.rounds")
local host = require("rex_reviewer.host")

local M = {}

-- The sessions (spaces) that exist now, or nil when any may.
function M.live_sessions()
  return host.live_scopes()
end

-- The session a PR's panes are in; see the host's scope.
function M.pr_session(e, fallback, live)
  return host.scope(e, fallback, live)
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
-- One step for every PR. Returns what needs you: { repo, pr, kind, text },
-- plus the PR's round and title, and for a review ready to post, a summary
-- of the checked draft.

-- The checked draft's outcome: its event, its verdict, and how many
-- findings block. Nil when there's no checked draft.
local function draft_summary(e)
  if not e.worktree then
    return nil
  end
  local path = string.format("%s/.tmp/rounds/%d/review.verified.json", e.worktree, e.round or 0)
  local d = util.decode(util.read_file(path) or "")
  if type(d) ~= "table" then
    return nil
  end
  local blocking, non_blocking = 0, 0
  for _, f in ipairs(type(d.findings) == "table" and d.findings or {}) do
    if f.severity == "blocking" then
      blocking = blocking + 1
    else
      non_blocking = non_blocking + 1
    end
  end
  return {
    event = d.event, blocking = blocking, non_blocking = non_blocking,
    verdict = type(d.verdict) == "string" and d.verdict or nil,
  }
end

local function needs(list, e, kind, text)
  list[#list + 1] = {
    repo = e.repo, pr = e.pr, kind = kind, text = text, round = e.round, title = e.title,
    draft = kind == "ready" and draft_summary(e) or nil,
  }
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
  local live = M.live_sessions()
  for _, e in ipairs(entries) do
    local label = ledger.label(e)
    local ok, err = pcall(function()
      local session = M.pr_session(e, session, live)
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
              if p.stale then
                log(string.format("%s round %d: counted %s as done: READY_TO_POST for %d+ min while the pane still says working (a background process?)",
                  label, e.round, table.concat(p.stale, ", "), math.floor(rounds.STALE_WORKING_SECONDS / 60)))
              end
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
            rounds.open_ask(e, session, log)
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
-- The watcher on its host

function M.watch_script()
  return host.watch_script()
end

-- Make sure the watcher runs on the host. Safe to run any time; a
-- LaunchAgent can run it every few minutes. With auto, a watcher stopped
-- with down stays stopped; a plain up starts it again.
function M.up(opts)
  opts = opts or {}
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
    s.host = host.name
  end)
  local res = host.start_watcher()
  res.host = host.name
  return res
end

-- Stop the watcher until the next plain up. Review tabs stay open; their
-- rounds carry on from where they are.
function M.down()
  ledger.update_state(function(s)
    s.stopped = true
  end)
  ledger.append_event({ kind = "stopped" })
  return { stopped = true, closed = host.stop_watcher() }
end

-- Show a round in the host's app, or the watcher with no PR: the checker
-- while it checks, else the first reviewer whose pane is open.
function M.focus(repo, pr)
  local sid, pane
  if pr then
    local e = ledger.load(repo, pr)
    if not e or e.state ~= "reviewing" then
      error(string.format("%s#%d has no round in progress", repo, pr), 0)
    end
    sid = M.pr_session(e, host.home_scope(), M.live_sessions())
    local names = {}
    for _, r in ipairs(rounds.round_reviewers(e)) do
      names[#names + 1] = r.pane
    end
    if e.checker_pane then
      table.insert(names, e.phase == "reviewer" and #names + 1 or 1, e.checker_pane)
    end
    if e.ask_pane then
      table.insert(names, 1, e.ask_pane)
    end
    for i = 1, #names do
      local _, b = rounds.pane_state(sid, names[i])
      if b then
        pane = b
        break
      end
    end
    if not pane then
      error(string.format("%s#%d has no open tab", repo, pr), 0)
    end
  else
    sid = host.home_scope()
    pane = "watcher"
  end
  local shown = sid and host.show(sid, pane)
  if not shown then
    if pr then
      error(string.format("%s#%d has no open tab", repo, pr), 0)
    end
    error("the watcher isn't running; start it with reviewer_up", 0)
  end
  shown.repo, shown.pr = repo, pr
  return shown
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
    host = host.name, stopped = st.stopped == true, paused = st.paused == true, post = config.load().post,
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
  check("host", true, host.name)
  for _, ch in ipairs(host.checks and host.checks() or {}) do
    check(ch.check, ch.ok, ch.detail)
  end
  local programs = util.append(util.append({}, host.programs), { "gh", "git", "jq", "perl", "uuidgen" })
  local agents_used = { c.checker }
  for _, r in ipairs(c.reviewer_list) do
    agents_used[#agents_used + 1] = r.agent
  end
  for _, agent in ipairs(agents_used) do
    programs[#programs + 1] = agent
    if agent == "codex" then
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
    -- Effort functions, on an empty round-1 PR: one that errors or returns
    -- something other than a level shows up here, not as a round that
    -- won't start.
    local sample = { review = rounds.effort_view({ repo = r.slug, pr = 0 }, 1), check = rounds.effort_view({ repo = r.slug, pr = 0 }, 1, {}) }
    for _, slot in ipairs({ "review", "check" }) do
      local eok, err = pcall(config.effort, r, slot, sample[slot])
      if not eok then
        check(r.slug .. " effort." .. slot, false, tostring(err))
      end
    end
    for _, rv in ipairs(c.reviewer_list) do
      if rv.effort ~= nil then
        local eok, err = pcall(config.effort, r, "review", sample.review, rv)
        if not eok then
          check(r.slug .. " reviewers." .. rv.name .. ".effort", false, tostring(err))
        end
      end
    end
  end
  local names = {}
  for _, rv in ipairs(c.reviewer_list) do
    names[#names + 1] = rv.name .. " (" .. rv.agent .. ")"
  end
  check("reviewers", true, table.concat(names, ", ") .. "; the first is the primary")
  local function effort_of(v)
    if type(v) == "function" then
      return "by PR"
    end
    return v or "the agent's own"
  end
  local effort = { "review " .. effort_of(c.effort.review), "check " .. effort_of(c.effort.check) }
  for _, rv in ipairs(c.reviewer_list) do
    if rv.effort ~= nil then
      effort[#effort + 1] = rv.name .. " " .. effort_of(rv.effort)
    end
  end
  check("effort", true, table.concat(effort, "; "))
  local all = true
  for _, ch in ipairs(checks) do
    all = all and ch.ok
  end
  return { ok = all, checks = checks }
end

return M
