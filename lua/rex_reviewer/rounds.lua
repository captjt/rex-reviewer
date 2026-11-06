-- A round, step by step: prep the worktrees and context, start the
-- reviewers, start the checker, follow a moved head, post or dismiss, and
-- clean up.
--
-- A round runs every reviewer in the config, each in its own worktree and
-- pane, blind to the others. The first is the primary: its worktree is the
-- PR's (e.worktree, pr-<n>) and its pane is <repo>-<pr>, as with one
-- reviewer. Each other reviewer gets pr-<n>-<name> and <repo>-<pr>-<name>.
-- The checker starts once every reviewer is done, in the primary's worktree.
--
-- .tmp/status.txt in each reviewer's worktree carries that reviewer's state,
-- and the primary's carries the round's:
--   WORKING …            the reviewer is reviewing
--   READY_TO_POST        the reviewer is done; the checker starts when all are
--   VERIFYING …          the checker is checking
--   AWAITING_APPROVAL    post = "ask": checked, and waiting for you
--   POSTED <url>         posted; the tabs close
--   DISMISSED            you dismissed it; the tabs close
--   HEAD_MOVED           the post was refused; the reviewers get the new commits
--   BLOCKED: <why>       an agent stopped and needs you

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")
local rules = require("rex_reviewer.rules")
local github = require("rex_reviewer.github")
local agents = require("rex_reviewer.agents")

local M = {}

local HOME = util.HOME

local function rex_agent(args)
  local argv = { config.ROOT .. "/bin/rex-agent" }
  return util.append(argv, args)
end

-- The pane of the primary reviewer, or of the reviewer named.
function M.reviewer_pane(e, name)
  local _, repo_name = util.split_slug(e.repo)
  local pane = string.format("%s-%d", repo_name, e.pr)
  return name and (pane .. "-" .. name) or pane
end

function M.checker_pane(e)
  return M.reviewer_pane(e) .. "-check"
end

-- The pane's state (idle, working, done, blocked, error) and block ID, or
-- nil when it's gone.
function M.pane_state(session, name)
  if not name or not session then
    return nil
  end
  local res = util.run(rex_agent({ "get", name, "-s", session }), { check = false })
  if not res.ok then
    return nil
  end
  local j = util.decode(res.stdout) or {}
  return j.state, j.block_id
end

function M.close_pane(session, name)
  if name and session then
    util.run(rex_agent({ "close", name, "-s", session }), { check = false })
  end
end

-- The status in a worktree: the primary's (the round's) unless wt is given.
function M.set_status(e, s, wt)
  util.write_file((wt or e.worktree) .. "/.tmp/status.txt", s .. "\n")
end

function M.status(e, wt)
  wt = wt or e.worktree
  local s = wt and util.read_file(wt .. "/.tmp/status.txt") or ""
  return util.trim(s:match("^[^\n]*") or "")
end

local function load(repo, pr)
  local e = ledger.load(repo, pr)
  if not e then
    error(string.format("%s#%d isn't in the ledger", repo, pr), 0)
  end
  return e
end

---------------------------------------------------------------------------
-- Worktrees and reviewers

-- The primary reviewer's worktree, which is the PR's, or the named
-- reviewer's beside it.
function M.worktree_path(e, name)
  local wt = string.format("%s/worktrees/%s/pr-%d", config.DATA_DIR, e.repo, e.pr)
  return name and (wt .. "-" .. name) or wt
end

-- The reviewers of the round in progress, or of the next round, primary
-- first. Each is its record in e.reviewers, which keeps its session across
-- rounds: { name, agent, index, primary, worktree, pane, session, … }. A
-- round in progress keeps the reviewers it started with; a new round takes
-- the config's.
function M.round_reviewers(e)
  e.reviewers = type(e.reviewers) == "table" and e.reviewers or {}
  local out = {}
  if e.state == "reviewing" and type(e.round_reviewers) == "table" and #e.round_reviewers > 0 then
    for _, name in ipairs(e.round_reviewers) do
      if type(e.reviewers[name]) == "table" then
        out[#out + 1] = e.reviewers[name]
      end
    end
    if #out > 0 then
      return out
    end
  end
  -- A round in progress that doesn't list its reviewers ran only one.
  local list = config.load().reviewer_list
  if e.state == "reviewing" then
    list = { list[1] }
  end
  for i, cr in ipairs(list) do
    local r = e.reviewers[cr.name]
    -- A reviewer whose agent changed starts over.
    if type(r) ~= "table" or r.agent ~= cr.agent then
      r = { agent = cr.agent }
      e.reviewers[cr.name] = r
    end
    r.name, r.index, r.primary = cr.name, i, i == 1
    r.worktree = M.worktree_path(e, not r.primary and cr.name or nil)
    r.pane = M.reviewer_pane(e, not r.primary and cr.name or nil)
    out[#out + 1] = r
  end
  return out
end

-- Every worktree the PR's agents have run in: the PR's own, then each
-- other reviewer's, including ones from an earlier config.
function M.worktrees(e)
  local out, seen = {}, {}
  local function add(p)
    if type(p) == "string" and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add(e.worktree)
  for _, p in ipairs(type(e.extra_worktrees) == "table" and e.extra_worktrees or {}) do
    add(p)
  end
  for _, r in pairs(type(e.reviewers) == "table" and e.reviewers or {}) do
    if type(r) == "table" then
      add(r.worktree)
    end
  end
  return out
end

local function remember_worktree(e, wt)
  e.extra_worktrees = type(e.extra_worktrees) == "table" and e.extra_worktrees or {}
  for _, p in ipairs(e.extra_worktrees) do
    if p == wt then
      return
    end
  end
  e.extra_worktrees[#e.extra_worktrees + 1] = wt
end

---------------------------------------------------------------------------
-- Briefs: briefs/<name> in this checkout, or the same name in
-- ~/.config/rex-reviewer/briefs/, which wins.

local function brief(name)
  local own = config.CONFIG_DIR .. "/briefs/" .. name
  local t = util.read_file(own) or util.read_file(config.ROOT .. "/briefs/" .. name)
  return assert(t, "missing brief " .. name)
end

local function login()
  local st = ledger.load_state()
  if st.login then
    return st.login
  end
  local l = github.login()
  ledger.update_state(function(s)
    s.login = l
  end)
  return l
end

local function section(title, text)
  if not text or text == "" then
    return ""
  end
  return "## " .. title .. "\n\n" .. util.trim(text) .. "\n"
end

-- The brief variables for the round, as one reviewer sees them when r is
-- given (its port and review guide), or as the checker does.
function M.vars(e, round, r)
  local c = config.load()
  local repo = c.repos[e.repo]
  local rs = M.round_reviewers(e)
  local index = r and r.index or 1
  local own = r and c.reviewers_by_name[r.name] or nil
  local v = {
    ROOT = config.ROOT,
    REPO = e.repo,
    PR = e.pr,
    TITLE = e.title,
    AUTHOR = e.author,
    LOGIN = login(),
    BASE = e.base or "main",
    ROUND = round,
    HEAD = e.round_head,
    HEAD_SHORT = util.short(e.round_head),
    PREV_ROUND = round - 1,
    PREV_HEAD = e.reviewed_head,
    PREV_HEAD_SHORT = util.short(e.reviewed_head),
    CONTEXT = string.format(".tmp/context/round-%d", round),
    OUT = string.format(".tmp/rounds/%d", round),
    -- 10000 apart, so reviewers running servers at once don't collide.
    PORT = 20000 + 10000 * (index - 1) + (e.pr % 10000),
    DRAFT_SCHEMA = config.ROOT .. "/docs/review-draft.md",
    REPO_NOTES = section("Notes for this repo", repo and repo.notes),
    N = #rs,
    PRIMARY = rs[1] and rs[1].name or c.reviewer,
  }
  local review = repo and config.guide(repo, "review", e, own)
  v.REVIEW_GUIDE = review or util.trim(util.render(brief("parts/review-default.md"), v):gsub("%s*\n%s*", " "))
  local style = repo and config.guide(repo, "style", e)
  v.STYLE_GUIDE = style or "Write for the PR author, plainly and briefly."
  local risk = repo and config.guide(repo, "merge_risk", e)
  v.MERGE_RISK_GUIDE = risk or ""
  v.CHECK_GUIDE = section("More instructions", repo and config.guide(repo, "check", e))
  v.ACTION_ARGS = string.format("repo=%s pr=%d", e.repo, e.pr)
  v.MERGE_RISK_START = risk and util.render(brief("parts/merge-risk-start.md"), v) or ""
  v.MERGE_RISK_ADD = risk and util.render(brief("parts/merge-risk-add.md"), v) or ""
  v.POST_STEP = util.render(brief(c.post == "auto" and "parts/post-auto.md" or "parts/post-ask.md"), v)
  v.PARALLEL = #rs > 1 and util.trim(util.render(brief("parts/parallel.md"), v)) or ""
  local names = {}
  for _, x in ipairs(rs) do
    names[#names + 1] = '"' .. x.name .. '"'
  end
  v.FOUND_BY_EXAMPLE = "`[" .. table.concat(names, ", ") .. "]`"
  v.THE_REVIEWERS = #rs > 1 and "the reviewers" or "the reviewer"
  return v
end

function M.merge_risk_enabled(e)
  local repo = config.load().repos[e.repo]
  return repo and config.guide(repo, "merge_risk", e) ~= nil
end

---------------------------------------------------------------------------
-- Effort

-- The lines a diff adds or removes, counting only inside its hunks, so a
-- removed line that starts with -- isn't taken for a file header. Nil when
-- there's no diff.
local function diff_lines(path)
  local d = util.read_file(path)
  if not d then
    return nil
  end
  local n, in_hunk = 0, false
  for line in (d .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 2) == "@@" then
      in_hunk = true
    elseif line:sub(1, 5) == "diff " then
      in_hunk = false
    elseif in_hunk then
      local c = line:sub(1, 1)
      if c == "+" or c == "-" then
        n = n + 1
      end
    end
  end
  return n
end

-- What an effort function sees of the PR when a round starts: its size,
-- files, and labels, how much changed since the last round, and how the
-- last round the agents posted ended (not one you dismissed or reviewed). The checker's adds the findings the
-- reviewers drafted. Works on an entry with no worktree yet, as doctor's.
function M.effort_view(e, round, rs)
  local ctx = e.worktree and string.format("%s/.tmp/context/round-%d", e.worktree, round)
  local p = ctx and util.decode(util.read_file(ctx .. "/pr.json") or "") or {}
  local files, labels = {}, {}
  for _, f in ipairs(type(p.files) == "table" and p.files or {}) do
    files[#files + 1] = f.path
  end
  for _, l in ipairs(type(p.labels) == "table" and p.labels or {}) do
    labels[#labels + 1] = l.name
  end
  local last
  local history = type(e.history) == "table" and e.history or {}
  for i = #history, 1, -1 do
    if history[i].by ~= "you" then
      last = history[i]
      break
    end
  end
  local additions, deletions = e.additions or 0, e.deletions or 0
  local view = {
    repo = e.repo,
    pr = e.pr,
    title = e.title,
    author = e.author,
    round = round,
    additions = additions,
    deletions = deletions,
    lines = additions + deletions,
    changed_files = e.changed_files or #files,
    files = files,
    labels = labels,
    delta_lines = ctx and round > 1 and diff_lines(ctx .. "/delta.diff") or nil,
    last_verdict = last and last.verdict,
    last_blocking = last and last.blocking,
    last_merge_risk = last and last.merge_risk,
  }
  -- True when a file's path contains any of the strings given, as a list
  -- or as arguments: pr.touches({ "migrations/", "auth/" }).
  view.touches = function(...)
    local subs = {}
    for _, a in ipairs({ ... }) do
      if type(a) == "table" then
        util.append(subs, a)
      elseif type(a) == "string" then
        subs[#subs + 1] = a
      end
    end
    for _, f in ipairs(files) do
      for _, s in ipairs(subs) do
        if f:find(s, 1, true) then
          return true
        end
      end
    end
    return false
  end
  if rs then
    view.drafted, view.drafted_blocking = 0, 0
    for _, r in ipairs(rs) do
      local d = util.decode(util.read_file(string.format("%s/.tmp/rounds/%d/review.json", r.worktree, round)) or "") or {}
      for _, f in ipairs(type(d.findings) == "table" and d.findings or {}) do
        view.drafted = view.drafted + 1
        if f.severity == "blocking" then
          view.drafted_blocking = view.drafted_blocking + 1
        end
      end
    end
  end
  return view
end

---------------------------------------------------------------------------
-- Prep: every reviewer's worktree at the head, and the context the agents
-- read.

local function round_ref(e, round)
  return string.format("refs/rex-reviewer/pr-%d/round-%d", e.pr, round)
end

-- Ask for a round on this PR, requested or not.
function M.pickup(repo, pr)
  local e = ledger.load(repo, pr)
  if e and (e.state == "queued" or e.state == "reviewing") then
    return { repo = repo, pr = pr, state = e.state, note = "already " .. e.state }
  end
  local p = github.pr(repo, pr)
  if p.state ~= "OPEN" then
    error(string.format("%s#%d is %s", repo, pr, p.state), 0)
  end
  local now = util.now()
  e = e or { repo = repo, pr = pr, round = 0, history = {}, created_at = now }
  e.state = "queued"
  e.trigger = "manual"
  e.requested_at = now
  e.head = p.headRefOid
  e.title = p.title
  e.url = p.url
  e.author = p.author and p.author.login
  ledger.save(e)
  ledger.append_event({ kind = "pickup", repo = repo, pr = pr, round = e.round + 1, head = e.head })
  return e
end

local function copy_dir(src, dst)
  util.run({ "rm", "-rf", dst })
  util.mkdirp(dst:match("^(.*)/[^/]+$"))
  util.run({ "cp", "-R", src, dst })
end

function M.prep(repo, pr)
  local e = load(repo, pr)
  if ledger.FINISHED[e.state] then
    error(string.format("%s is %s", ledger.label(e), e.state), 0)
  end
  local checkout = config.load().repos[repo].checkout
  local round = e.state == "reviewing" and e.round or e.round + 1
  local ref = round_ref(e, round)
  local git = function(args, opts)
    return util.run(util.append({ "git", "-C", checkout }, args), opts)
  end

  git({ "fetch", "--no-tags", "--quiet", "origin", string.format("+refs/pull/%d/head:%s", pr, ref) })
  local head = util.trim(git({ "rev-parse", ref }).stdout)
  local rs = M.round_reviewers(e)
  for _, r in ipairs(rs) do
    if util.exists(r.worktree .. "/.git") then
      util.run({ "git", "-C", r.worktree, "checkout", "--detach", "--quiet", head })
    else
      util.mkdirp(r.worktree:match("^(.*)/[^/]+$"))
      git({ "worktree", "add", "--detach", "--quiet", r.worktree, head })
    end
    if not r.primary then
      remember_worktree(e, r.worktree)
    end
  end
  local wt = rs[1].worktree

  local ctx = string.format("%s/.tmp/context/round-%d", wt, round)
  util.mkdirp(ctx)
  local p = github.fetch_context(repo, pr, ctx)
  e.base = p.baseRefName or e.base or "main"
  e.additions, e.deletions, e.changed_files = p.additions, p.deletions, p.changedFiles

  local delta
  if round > 1 then
    local prev = round_ref(e, round - 1)
    if git({ "rev-parse", "--verify", "--quiet", prev }, { check = false }).ok then
      util.write_file(ctx .. "/delta.diff", git({ "diff", prev, ref }).stdout)
      util.write_file(ctx .. "/delta-commits.txt", git({ "log", "--oneline", prev .. ".." .. ref }).stdout)
      delta = prev .. ".." .. ref
    end
  end

  local moved_from
  if e.state == "reviewing" and e.round_head and e.round_head ~= head then
    moved_from = e.round_head
    util.write_file(ctx .. "/delta-head.diff", git({ "diff", moved_from, head }).stdout)
    util.write_file(ctx .. "/delta-head-commits.txt", git({ "log", "--oneline", moved_from .. ".." .. head }).stdout)
  end

  -- The other reviewers get the same context; agents never call GitHub.
  for i = 2, #rs do
    copy_dir(ctx, string.format("%s/.tmp/context/round-%d", rs[i].worktree, round))
  end

  e.worktree = wt
  e.round_head = head
  e.prepared_round = round
  ledger.save(e)
  return { repo = repo, pr = pr, round = round, head = head, worktree = wt, context = ctx, delta = delta, moved_from = moved_from }
end

---------------------------------------------------------------------------
-- Agents

-- Shared caches the agents may write to, and git's worktree metadata, so
-- git in the worktree can update its index.
local function writable_dirs(e)
  local c = config.load()
  local out = {}
  local dirs = { c.repos[e.repo].checkout .. "/.git/worktrees", config.CACHE_DIR }
  util.append(dirs, c.caches)
  for _, d in ipairs(dirs) do
    if util.exists(d) then
      out[#out + 1] = d
    end
  end
  return out
end

-- Cargo's home also holds installed binaries, so agents get a small
-- CARGO_HOME that links only its caches.
local function cargo_home()
  local dir = config.CACHE_DIR .. "/cargo"
  util.mkdirp(dir)
  for _, name in ipairs({ "registry", "git", "advisory-dbs" }) do
    local target = HOME .. "/.cargo/" .. name
    if util.exists(target) and not util.exists(dir .. "/" .. name) then
      util.run({ "ln", "-s", target, dir .. "/" .. name })
    end
  end
  return dir
end

-- Agents run with gh signed out: everything they need from GitHub is in
-- .tmp/context, and only the tool's own actions post.
local function env_args(wt)
  util.mkdirp(wt .. "/.tmp/gh-empty")
  return {
    "-u", "GH_TOKEN", "-u", "GITHUB_TOKEN",
    "GH_CONFIG_DIR=" .. wt .. "/.tmp/gh-empty",
    "CARGO_HOME=" .. cargo_home(),
  }
end

-- Send a prompt once the agent settles. Some agents report idle at startup,
-- then work again while their hooks run, so a prompt sent right away can be
-- refused as busy (rex-agent exit 7).
function M.deliver(name, session, prompt)
  for _ = 1, 8 do
    util.run(rex_agent({ "wait", name, "-s", session, "--until", "idle", "--timeout", "60" }), { check = false })
    local res = util.run(rex_agent({ "prompt", name, "-s", session, prompt }), { check = false })
    if res.ok then
      return
    end
    if res.code ~= 7 then
      M.close_pane(session, name)
      error(name .. " didn't take its task: " .. util.trim(res.stderr):sub(1, 300), 0)
    end
    util.run({ "sleep", "3" })
  end
  M.close_pane(session, name)
  error(name .. " stayed busy and never took its task", 0)
end

-- Open a reviewer, resuming its session if it has one, and send it the
-- prompt: in a new tab, or split beside anchor (the primary's block).
-- Returns the session ID.
local function open_reviewer(e, r, session, prompt, anchor)
  local adapter = agents.reviewers[r.agent]
  local own = config.load().reviewers_by_name[r.name]
  local argv = rex_agent({ "start", r.pane, "-s", session, "--cwd", r.worktree, "--timeout", "180", "--kind", "env" })
  if anchor then
    util.append(argv, { "--anchor", anchor })
  else
    argv[#argv + 1] = "--tab"
  end
  argv[#argv + 1] = "--"
  util.append(argv, env_args(r.worktree))
  local since = os.time()
  util.append(argv, adapter:command(e, r, writable_dirs(e), own and own.extra_args or {}))
  local res = util.run(argv, { check = false })
  if not res.ok then
    M.close_pane(session, r.pane)
    if ((res.stdout or "") .. (res.stderr or "")):find("Hooks need review", 1, true) then
      error("Codex is waiting for its hooks to be trusted. Run codex once, open /hooks, and trust them; the round retries on its own.", 0)
    end
    error(string.format("the %s reviewer (%s) didn't start: %s", r.name, adapter.program, util.trim(res.stderr):sub(1, 300)), 0)
  end
  M.deliver(r.pane, session, prompt)
  return adapter:session_after_start(r, since)
end

function M.start(repo, pr, session)
  local e = load(repo, pr)
  if e.state ~= "queued" then
    error(string.format("%s is %s, not queued", ledger.label(e), e.state), 0)
  end
  local round = e.round + 1
  if e.prepared_round ~= round or not e.worktree then
    error(string.format("%s: run reviewer_prep for round %d first", ledger.label(e), round), 0)
  end
  if not session then
    error("start needs a Rex session; run scripts/start.lua with rex do", 0)
  end
  local rs = M.round_reviewers(e)
  for _, r in ipairs(rs) do
    if not util.exists(r.worktree .. "/.git") then
      error(string.format("%s: run reviewer_prep for round %d first; the %s reviewer has no worktree", ledger.label(e), round, r.name), 0)
    end
  end

  -- Each reviewer's effort for the round, chosen before any pane opens, so
  -- an effort function that fails leaves nothing to close.
  local c = config.load()
  local view = M.effort_view(e, round)
  local efforts = {}
  for _, r in ipairs(rs) do
    r.effort = config.effort(c.repos[e.repo], "review", view, c.reviewers_by_name[r.name])
    efforts[r.name] = r.effort
  end
  e.checker_effort = nil

  -- Each reviewer gets its task in its own worktree. One that's new to the
  -- PR reviews it whole; the others pick up from their last round. If any
  -- fails to start, every pane this attempt opened closes, and nothing is
  -- saved, so the retry starts clean.
  local opened = {}
  local ok, err = pcall(function()
    local anchor
    for _, r in ipairs(rs) do
      local vars = M.vars(e, round, r)
      local wt = r.worktree
      util.mkdirp(wt .. "/" .. vars.OUT)
      util.mkdirp(wt .. "/.tmp/probes")
      util.write_file(wt .. "/.tmp/ground-rules.md", util.render(brief("ground-rules.md"), vars))
      local fresh = round == 1 or not r.session
      util.write_file(wt .. "/" .. vars.OUT .. "/task.md", util.render(brief(fresh and "round-1.md" or "round-n.md"), vars))
      M.set_status(e, "WORKING round " .. round, wt)
      if not r.session then
        r.first_round = round
        r.tokens_seen = nil
      end
      r.session = open_reviewer(e, r, session, string.format("Read .tmp/ground-rules.md, then %s/task.md, and do the task.", vars.OUT), anchor)
      opened[#opened + 1] = r.pane
      if not anchor then
        local _, block = M.pane_state(session, r.pane)
        anchor = block
      end
    end
  end)
  if not ok then
    for _, name in ipairs(opened) do
      M.close_pane(session, name)
    end
    error(err, 0)
  end

  rules.mark_started(e, e.round_head, util.now())
  local names, panes = {}, {}
  for _, r in ipairs(rs) do
    names[#names + 1] = r.name
    panes[#panes + 1] = r.pane
  end
  e.round_reviewers = names
  e.reviewers_total, e.reviewers_done = #rs, 0
  -- The primary's, for readers that know one reviewer.
  e.reviewer = rs[1].agent
  e.reviewer_session = rs[1].session
  e.pane = rs[1].pane
  e.phase = "reviewer"
  e.session_id = session
  e.start_error, e.start_failed_epoch = nil, nil
  ledger.save(e)
  ledger.append_event({
    kind = "started", repo = repo, pr = pr, round = round, head = e.round_head,
    note = #rs > 1 and (#rs .. " reviewers: " .. table.concat(names, ", ")) or nil,
    effort = next(efforts) and efforts or nil,
  })
  return { repo = repo, pr = pr, round = round, pane = e.pane, panes = panes, session = rs[1].session, worktree = e.worktree }
end

-- Where the round's reviewers are: how many are done, the first that's
-- blocked, and the first whose pane closed while it was working.
function M.progress(e, session)
  local rs = M.round_reviewers(e)
  local p = { total = #rs, done = 0 }
  for _, r in ipairs(rs) do
    local st = M.status(e, r.worktree)
    local pane = M.pane_state(session, r.pane)
    if st:match("^BLOCKED") then
      p.blocked = p.blocked or { name = r.name, why = (st:gsub("^BLOCKED:?%s*", "")) }
    elseif st == "READY_TO_POST" and pane ~= "working" then
      p.done = p.done + 1
    elseif st:match("^WORKING") and not pane then
      p.closed = p.closed or r.name
    end
  end
  p.ready = p.total > 0 and p.done == p.total
  return p
end

-- How check.md introduces the drafts: one reviewer's, or each reviewer's
-- with where its probes and builds are.
local function drafts_intro(rs, vars)
  if #rs == 1 then
    return string.format("A reviewer reviewed head %s in this worktree and drafted `%s/review.json` and `%s/report.md`.", vars.HEAD, vars.OUT, vars.OUT),
      string.format("`%s/review.json`, `%s/report.md`", vars.OUT, vars.OUT)
  end
  local lines = { string.format("%d reviewers reviewed head %s, each on its own in its own worktree, and each drafted a review:", #rs, vars.HEAD), "" }
  for _, r in ipairs(rs) do
    local program = agents.reviewers[r.agent] and agents.reviewers[r.agent].program or r.agent
    if r.primary then
      lines[#lines + 1] = string.format("- `%s` (%s), in this worktree: `%s/review.json` and `%s/report.md`.", r.name, program, vars.OUT, vars.OUT)
    else
      lines[#lines + 1] = string.format("- `%s` (%s), in `%s`: copied to `%s/reviewers/%s/review.json` and `report.md`. Its probes and builds are in its worktree.", r.name, program, r.worktree, vars.OUT, r.name)
    end
  end
  return table.concat(lines, "\n"), "each draft and report above"
end

function M.start_checker(e, session)
  local vars = M.vars(e, e.round)
  local rs = M.round_reviewers(e)
  -- The other reviewers' drafts, next to the primary's, and their worktrees,
  -- where the checker reruns their probes.
  local dirs = {}
  for _, r in ipairs(rs) do
    if not r.primary then
      local src = r.worktree .. "/" .. vars.OUT
      local dst = e.worktree .. "/" .. vars.OUT .. "/reviewers/" .. r.name
      util.mkdirp(dst)
      for _, f in ipairs({ "review.json", "report.md" }) do
        if util.exists(src .. "/" .. f) then
          util.run({ "cp", "-f", src .. "/" .. f, dst .. "/" .. f })
        end
      end
      dirs[#dirs + 1] = r.worktree
    end
  end
  local c = config.load()
  e.checker_effort = config.effort(c.repos[e.repo], "check", M.effort_view(e, e.round, rs))
  vars.DRAFTS, vars.DRAFT_FILES = drafts_intro(rs, vars)
  vars.MERGE_DRAFTS = #rs > 1 and util.render(brief("parts/merge-drafts.md"), vars) or ""
  util.write_file(e.worktree .. "/" .. vars.OUT .. "/check.md", util.render(brief("check.md"), vars))
  if M.merge_risk_enabled(e) then
    util.write_file(e.worktree .. "/" .. vars.OUT .. "/merge-risk.md", util.render(brief("merge-risk.md"), vars))
  end
  M.set_status(e, "VERIFYING round " .. e.round)
  local name = M.checker_pane(e)
  M.close_pane(session, name)
  local _, reviewer_block = M.pane_state(session, e.pane)
  local argv = rex_agent({ "start", name, "-s", session, "--cwd", e.worktree, "--timeout", "120", "--kind", "env" })
  if reviewer_block then
    util.append(argv, { "--anchor", reviewer_block, "--split", "left" })
  else
    argv[#argv + 1] = "--tab"
  end
  argv[#argv + 1] = "--"
  util.append(argv, env_args(e.worktree))
  util.append(argv, agents.checker_command(e, dirs))
  local res = util.run(argv, { check = false })
  if not res.ok then
    M.close_pane(session, name)
    error("Claude didn't start: " .. util.trim(res.stderr):sub(1, 300), 0)
  end
  M.deliver(name, session, string.format("Read %s/check.md and do it.", vars.OUT))
  e.phase = "checking"
  e.checker_pane = name
  e.reviewers_done = #rs
  ledger.save(e)
  ledger.append_event({ kind = "checking", repo = e.repo, pr = e.pr, round = e.round, head = e.round_head, effort = e.checker_effort })
end

---------------------------------------------------------------------------
-- A moved head

local function pr_diff(e, head)
  local checkout = config.load().repos[e.repo].checkout
  local base = util.trim(util.run({ "git", "-C", checkout, "merge-base", "origin/" .. (e.base or "main"), head }).stdout)
  local d = util.run({ "git", "-C", checkout, "diff", base, head }).stdout
  return (d:gsub("\nindex [^\n]*", ""))
end

-- True when two heads carry the same PR diff against the base, as after the
-- author merges the base branch in.
function M.same_pr_diff(e, old, new)
  local checkout = config.load().repos[e.repo].checkout
  util.run({ "git", "-C", checkout, "fetch", "--no-tags", "--quiet", "origin", e.base or "main" })
  util.run({ "git", "-C", checkout, "fetch", "--no-tags", "--quiet", "origin", new }, { check = false })
  return pr_diff(e, old) == pr_diff(e, new)
end

-- Send every reviewer the new commits, reopening any whose pane is gone.
function M.send_delta(e, session, moved_from)
  local rs = M.round_reviewers(e)
  local anchor
  for _, r in ipairs(rs) do
    local vars = M.vars(e, e.round, r)
    vars.MOVED_FROM = moved_from
    vars.MOVED_FROM_SHORT = util.short(moved_from)
    local task = string.format("%s/delta-%s.md", vars.OUT, util.short(e.round_head))
    util.write_file(r.worktree .. "/" .. task, util.render(brief("delta.md"), vars))
    M.set_status(e, "WORKING round " .. e.round .. " delta", r.worktree)
    local prompt = string.format("The PR's head moved while you reviewed. Read %s and do it.", task)
    if M.pane_state(session, r.pane) then
      util.run(rex_agent({ "prompt", r.pane, "-s", session, "--force", prompt }))
    else
      r.session = open_reviewer(e, r, session, prompt, anchor)
    end
    if not anchor then
      local _, block = M.pane_state(session, r.pane)
      anchor = block
    end
  end
  e.reviewer_session = rs[1].session
  e.pane = rs[1].pane
  e.reviewers_done = 0
  e.phase = "reviewer"
  ledger.save(e)
  ledger.append_event({ kind = "delta", repo = e.repo, pr = e.pr, round = e.round, head = e.round_head, from = moved_from })
end

-- The head moved past the round's head: check again when only the base came
-- in, otherwise send the reviewers the new commits. Returns what it did.
function M.follow_head(e, session, head)
  local same = M.same_pr_diff(e, e.round_head, head)
  local r = M.prep(e.repo, e.pr)
  e = ledger.load(e.repo, e.pr)
  if same then
    ledger.append_event({ kind = "repointed", repo = e.repo, pr = e.pr, round = e.round, head = e.round_head, from = r.moved_from })
    M.start_checker(e, session)
    return "repointed"
  end
  M.close_pane(session, e.checker_pane)
  e.checker_pane = nil
  M.send_delta(e, session, r.moved_from)
  return "delta"
end

---------------------------------------------------------------------------
-- Posting

-- Ask the watcher for a step now, so the round's tabs close and clients
-- update without waiting for the next poll.
local function nudge_watcher()
  util.mkdirp(config.STATE_DIR)
  util.write_file(ledger.check_now_path(), "")
end

-- The draft's account of what the PR changes, on one line, for the recap.
-- It's never posted.
local function implementation(d)
  local s = type(d.implementation) == "string" and util.trim(d.implementation:gsub("%s+", " ")) or ""
  return s ~= "" and s or nil
end

-- What the agents have logged in each of the PR's worktrees, by worktree,
-- from bin/token-usage. A worktree it can't read is left out.
local function usage_by_worktree(e)
  local out = {}
  if not e.worktree then
    return out
  end
  for _, wt in ipairs(M.worktrees(e)) do
    local res = util.run({ config.ROOT .. "/bin/token-usage", wt }, { check = false })
    out[wt] = res.ok and util.decode(res.stdout) or nil
  end
  return out
end

-- What the agents have spent on the PR so far, summed over its worktrees.
-- Nil when bin/token-usage can't tell.
local function tokens_spent(by_wt)
  local sum, any = { total = 0 }, false
  for _, t in pairs(by_wt) do
    rules.add_tokens(sum, t)
    any = true
  end
  return any and sum or nil
end

-- Each reviewer's part in the round, for the history: the findings it
-- drafted and, from found_by in the checked review when there is one, how
-- many the checker kept and how many only it found. tokens is what its
-- agent logged in its worktree this round; the primary's includes the
-- checker's when both are Claude Code. effort is the level its agent ran
-- at, as its session recorded it, or the round's when it can't be read.
-- Updates each record's tokens_seen.
local function scoreboard(e, rs, checked, by_wt)
  local board = {}
  for _, r in ipairs(rs) do
    local d = util.decode(util.read_file(string.format("%s/.tmp/rounds/%d/review.json", r.worktree, e.round)) or "") or {}
    local adapter = agents.reviewers[r.agent]
    local s = {
      drafted = type(d.findings) == "table" and #d.findings or 0,
      effort = (adapter and adapter.effort and adapter:effort(r)) or r.effort,
    }
    if checked then
      s.kept, s.only = 0, 0
    end
    local t = by_wt[r.worktree]
    local spent = t and type(t[r.agent]) == "table" and t[r.agent].total or nil
    if spent then
      if r.tokens_seen then
        s.tokens = math.max(0, spent - r.tokens_seen)
      elseif r.first_round == e.round then
        s.tokens = spent
      end
      r.tokens_seen = spent
    end
    board[r.name] = s
  end
  for _, f in ipairs(checked and type(checked.findings) == "table" and checked.findings or {}) do
    local by = type(f.found_by) == "table" and f.found_by or {}
    for _, name in ipairs(by) do
      if board[name] and board[name].kept then
        board[name].kept = board[name].kept + 1
      end
    end
    if #by == 1 and board[by[1]] and board[by[1]].only then
      board[by[1]].only = board[by[1]].only + 1
    end
  end
  return board
end

-- Render the checked review with bin/post-review, and post it unless dry.
-- The footer names the reviewers and the checker, with their models.
function M.post(repo, pr, opts)
  opts = opts or {}
  local e = load(repo, pr)
  if e.state ~= "reviewing" then
    error(string.format("%s has no round in progress", ledger.label(e)), 0)
  end
  local out = string.format("%s/.tmp/rounds/%d", e.worktree, e.round)
  local draft = out .. "/review.verified.json"
  if not util.exists(draft) then
    error("write " .. draft .. " first: the checked review, in the format of docs/review-draft.md", 0)
  end
  local rs = M.round_reviewers(e)
  local argv = {
    config.ROOT .. "/bin/post-review", "--repo", repo, "--pr", tostring(pr), "--head", e.round_head,
    "--by", agents.byline(rs), "--checked-by", agents.checker_name(e),
    "--marker", string.format("round=%d head=%s", e.round, e.round_head),
  }
  if M.merge_risk_enabled(e) then
    argv[#argv + 1] = "--require-merge-risk"
  end
  if opts.dry then
    argv[#argv + 1] = "--dry-run"
  end
  argv[#argv + 1] = draft
  local res = util.run(argv, { check = false })
  if res.code == 3 then
    error(string.format("%s moved since this round started at %s; review the new commits first", ledger.label(e), util.short(e.round_head)), 0)
  elseif not res.ok then
    error(util.trim(res.stderr ~= "" and res.stderr or res.stdout), 0)
  end
  if opts.dry then
    util.write_file(out .. "/preview.md", res.stdout)
    return { dry_run = true, preview = res.stdout, preview_path = out .. "/preview.md" }
  end
  local posted = util.decode(res.stdout) or {}
  local checked = util.decode(util.read_file(draft)) or {}
  local blocking, non_blocking = 0, 0
  for _, f in ipairs(checked.findings or {}) do
    if f.severity == "blocking" then
      blocking = blocking + 1
    else
      non_blocking = non_blocking + 1
    end
  end
  local by_wt = usage_by_worktree(e)
  rules.mark_posted(e, {
    head = e.round_head, verdict = posted.state, review_id = posted.review_id, url = posted.url,
    blocking = blocking, non_blocking = non_blocking, merge_risk = posted.merge_risk,
    implementation = implementation(checked), tokens = tokens_spent(by_wt),
    reviewers = scoreboard(e, rs, checked, by_wt), checker_effort = agents.checker_effort(e) or e.checker_effort,
  }, util.now())
  e.merge_risk = posted.merge_risk
  ledger.save(e)
  M.set_status(e, "POSTED " .. (posted.url or ""))
  ledger.append_event({
    kind = "posted", repo = repo, pr = pr, round = e.round, head = e.round_head, verdict = posted.state,
    review_id = posted.review_id, note = posted.merge_risk and ("merge risk " .. posted.merge_risk) or nil,
  })
  nudge_watcher()
  return {
    repo = repo, pr = pr, round = e.round, review_id = posted.review_id, state = posted.state, url = posted.url,
    inline = posted.inline, replies = posted.replies, merge_risk = posted.merge_risk,
  }
end

-- End the round without posting. The next re-request starts a new round.
function M.dismiss(repo, pr)
  local e = load(repo, pr)
  if e.state ~= "reviewing" then
    error(string.format("%s has no round in progress", ledger.label(e)), 0)
  end
  -- The PR's description still holds when you dismiss the review, so keep
  -- the checked draft's, or the primary reviewer's if the checker hasn't run.
  local out = string.format("%s/.tmp/rounds/%d", e.worktree, e.round)
  local verified = util.decode(util.read_file(out .. "/review.verified.json") or "")
  local d = verified or util.decode(util.read_file(out .. "/review.json") or "") or {}
  local by_wt = usage_by_worktree(e)
  -- The checker's effort only when this round's checker ran.
  local checked = e.phase == "checking" or e.phase == "awaiting"
  rules.mark_posted(e, {
    head = e.round_head, verdict = "DISMISSED", by = "you", implementation = implementation(d),
    tokens = tokens_spent(by_wt), reviewers = scoreboard(e, M.round_reviewers(e), verified, by_wt),
    checker_effort = checked and (agents.checker_effort(e) or e.checker_effort) or nil,
  }, util.now())
  ledger.save(e)
  M.set_status(e, "DISMISSED")
  ledger.append_event({ kind = "dismissed", repo = repo, pr = pr, round = e.round, head = e.round_head })
  nudge_watcher()
  return { repo = repo, pr = pr, round = e.round, dismissed = true }
end

---------------------------------------------------------------------------
-- Closing panes, and cleanup after a merge or close

-- Close the checker's pane and every reviewer's.
function M.close_panes(e, session)
  if not session then
    return
  end
  M.close_pane(session, e.checker_pane)
  local seen = {}
  local function close(name)
    if name and not seen[name] then
      seen[name] = true
      M.close_pane(session, name)
    end
  end
  close(e.pane)
  for _, r in pairs(type(e.reviewers) == "table" and e.reviewers or {}) do
    if type(r) == "table" then
      close(r.pane)
    end
  end
end

local function remove_worktree(checkout, wt)
  if not util.exists(wt .. "/.git") then
    return
  end
  -- A base checkout an agent added under .tmp goes first.
  local list = util.run({ "git", "-C", checkout, "worktree", "list", "--porcelain" }).stdout
  for path in list:gmatch("worktree ([^\n]+)") do
    if path ~= wt and path:sub(1, #wt + 1) == wt .. "/" then
      util.run({ "git", "-C", checkout, "worktree", "remove", "--force", path }, { check = false })
    end
  end
  util.run({ "git", "-C", checkout, "worktree", "remove", "--force", wt })
  -- Claude Code's scratch folder for sessions started in the worktree.
  local uid = util.trim(util.run({ "id", "-u" }).stdout)
  local scratch = "/private/tmp/claude-" .. uid .. "/" .. (wt:gsub("[^%w]", "-"))
  if util.exists(scratch) then
    util.run({ "rm", "-rf", scratch }, { check = false })
  end
end

function M.cleanup(repo, pr, session)
  local e = ledger.load(repo, pr)
  if not e then
    return nil
  end
  local checkout = config.load().repos[repo].checkout
  -- The final count, while the agents' logs are all at hand: Codex
  -- compresses archived threads, and Claude Code deletes old transcripts.
  e.tokens = tokens_spent(usage_by_worktree(e)) or e.tokens
  M.close_panes(e, session)
  for _, wt in ipairs(M.worktrees(e)) do
    remove_worktree(checkout, wt)
  end
  util.run({ "git", "-C", checkout, "worktree", "prune" }, { check = false })
  local refs = util.run({ "git", "-C", checkout, "for-each-ref", "--format=%(refname)", string.format("refs/rex-reviewer/pr-%d/", pr) }).stdout
  for ref in refs:gmatch("[^\n]+") do
    util.run({ "git", "-C", checkout, "update-ref", "-d", ref })
  end
  for _, r in pairs(type(e.reviewers) == "table" and e.reviewers or {}) do
    local adapter = type(r) == "table" and agents.reviewers[r.agent]
    if adapter and adapter.archive then
      adapter:archive(r)
    end
  end
  e.state = "cleaned"
  e.pane, e.checker_pane, e.phase = nil, nil, nil
  e.cleaned_at = util.now()
  ledger.save(e)
  ledger.append_event({ kind = "cleaned", repo = repo, pr = pr })
  return e
end

return M
