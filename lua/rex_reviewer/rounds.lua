-- A round, step by step: prep the worktree and context, start the reviewer,
-- start the checker, follow a moved head, post or dismiss, and clean up.
--
-- .tmp/status.txt in the worktree carries the round's state:
--   WORKING …            the reviewer is reviewing
--   READY_TO_POST        the reviewer is done; the checker starts next
--   VERIFYING …          the checker is checking
--   AWAITING_APPROVAL    post = "ask": checked, and waiting for you
--   POSTED <url>         posted; the tabs close
--   DISMISSED            you dismissed it; the tabs close
--   HEAD_MOVED           the post was refused; the reviewer gets the new commits
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

function M.reviewer_pane(e)
  local _, name = util.split_slug(e.repo)
  return string.format("%s-%d", name, e.pr)
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

function M.set_status(e, s)
  util.write_file(e.worktree .. "/.tmp/status.txt", s .. "\n")
end

function M.status(e)
  local s = e.worktree and util.read_file(e.worktree .. "/.tmp/status.txt") or ""
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

function M.vars(e, round)
  local c = config.load()
  local repo = c.repos[e.repo]
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
    PORT = 20000 + (e.pr % 10000),
    DRAFT_SCHEMA = config.ROOT .. "/docs/review-draft.md",
    REPO_NOTES = section("Notes for this repo", repo and repo.notes),
  }
  local review = repo and config.guide(repo, "review", e)
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
  return v
end

function M.merge_risk_enabled(e)
  local repo = config.load().repos[e.repo]
  return repo and config.guide(repo, "merge_risk", e) ~= nil
end

---------------------------------------------------------------------------
-- Prep: the worktree at the head, and the context the agents read.

local function worktree_path(e)
  return string.format("%s/worktrees/%s/pr-%d", config.DATA_DIR, e.repo, e.pr)
end

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

function M.prep(repo, pr)
  local e = load(repo, pr)
  if ledger.FINISHED[e.state] then
    error(string.format("%s is %s", ledger.label(e), e.state), 0)
  end
  local checkout = config.load().repos[repo].checkout
  local round = e.state == "reviewing" and e.round or e.round + 1
  local wt = worktree_path(e)
  local ref = round_ref(e, round)
  local git = function(args, opts)
    return util.run(util.append({ "git", "-C", checkout }, args), opts)
  end

  git({ "fetch", "--no-tags", "--quiet", "origin", string.format("+refs/pull/%d/head:%s", pr, ref) })
  local head = util.trim(git({ "rev-parse", ref }).stdout)
  if util.exists(wt .. "/.git") then
    util.run({ "git", "-C", wt, "checkout", "--detach", "--quiet", head })
  else
    util.mkdirp(wt:match("^(.*)/[^/]+$"))
    git({ "worktree", "add", "--detach", "--quiet", wt, head })
  end

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
local function env_args(e)
  util.mkdirp(e.worktree .. "/.tmp/gh-empty")
  return {
    "-u", "GH_TOKEN", "-u", "GITHUB_TOKEN",
    "GH_CONFIG_DIR=" .. e.worktree .. "/.tmp/gh-empty",
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

-- Open the PR's reviewer in a new tab, resuming its session if it has one,
-- and send it the prompt. Returns the session ID.
local function open_reviewer(e, session, prompt)
  local adapter = agents.reviewer()
  local name = M.reviewer_pane(e)
  local argv = rex_agent({ "start", name, "-s", session, "--tab", "--cwd", e.worktree, "--timeout", "180", "--kind", "env", "--" })
  util.append(argv, env_args(e))
  util.append(argv, adapter:command(e, writable_dirs(e)))
  local res = util.run(argv, { check = false })
  if not res.ok then
    M.close_pane(session, name)
    if ((res.stdout or "") .. (res.stderr or "")):find("Hooks need review", 1, true) then
      error("Codex is waiting for its hooks to be trusted. Run codex once, open /hooks, and trust them; the round retries on its own.", 0)
    end
    error(adapter.program .. " didn't start: " .. util.trim(res.stderr):sub(1, 300), 0)
  end
  M.deliver(name, session, prompt)
  return adapter:session_after_start(e)
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
  local vars = M.vars(e, round)
  util.mkdirp(e.worktree .. "/" .. vars.OUT)
  util.mkdirp(e.worktree .. "/.tmp/probes")
  util.write_file(e.worktree .. "/.tmp/ground-rules.md", util.render(brief("ground-rules.md"), vars))
  util.write_file(e.worktree .. "/" .. vars.OUT .. "/task.md", util.render(brief(round == 1 and "round-1.md" or "round-n.md"), vars))
  M.set_status(e, "WORKING round " .. round)

  local id = open_reviewer(e, session, string.format("Read .tmp/ground-rules.md, then %s/task.md, and do the task.", vars.OUT))

  rules.mark_started(e, e.round_head, util.now())
  e.reviewer = config.load().reviewer
  e.reviewer_session = id
  e.pane = M.reviewer_pane(e)
  e.phase = "reviewer"
  e.session_id = session
  e.start_error, e.start_failed_epoch = nil, nil
  ledger.save(e)
  ledger.append_event({ kind = "started", repo = repo, pr = pr, round = round, head = e.round_head })
  return { repo = repo, pr = pr, round = round, pane = e.pane, session = id, worktree = e.worktree }
end

function M.start_checker(e, session)
  local vars = M.vars(e, e.round)
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
  util.append(argv, env_args(e))
  util.append(argv, agents.checker_command(e))
  local res = util.run(argv, { check = false })
  if not res.ok then
    M.close_pane(session, name)
    error("Claude didn't start: " .. util.trim(res.stderr):sub(1, 300), 0)
  end
  M.deliver(name, session, string.format("Read %s/check.md and do it.", vars.OUT))
  e.phase = "checking"
  e.checker_pane = name
  ledger.save(e)
  ledger.append_event({ kind = "checking", repo = e.repo, pr = e.pr, round = e.round, head = e.round_head })
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

function M.send_delta(e, session, moved_from)
  local vars = M.vars(e, e.round)
  vars.MOVED_FROM = moved_from
  vars.MOVED_FROM_SHORT = util.short(moved_from)
  local task = string.format("%s/delta-%s.md", vars.OUT, util.short(e.round_head))
  util.write_file(e.worktree .. "/" .. task, util.render(brief("delta.md"), vars))
  M.set_status(e, "WORKING round " .. e.round .. " delta")
  local prompt = string.format("The PR's head moved while you reviewed. Read %s and do it.", task)
  if M.pane_state(session, e.pane) then
    util.run(rex_agent({ "prompt", e.pane, "-s", session, "--force", prompt }))
  else
    e.reviewer_session = open_reviewer(e, session, prompt)
    e.pane = M.reviewer_pane(e)
  end
  e.phase = "reviewer"
  ledger.save(e)
  ledger.append_event({ kind = "delta", repo = e.repo, pr = e.pr, round = e.round, head = e.round_head, from = moved_from })
end

-- The head moved past the round's head: check again when only the base came
-- in, otherwise send the reviewer the new commits. Returns what it did.
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

-- Render the checked review with bin/post-review, and post it unless dry.
-- The footer names the reviewer and the checker, with their models.
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
  local adapter = agents.reviewers[e.reviewer or config.load().reviewer]
  local argv = {
    config.ROOT .. "/bin/post-review", "--repo", repo, "--pr", tostring(pr), "--head", e.round_head,
    "--by", adapter:name(e), "--checked-by", agents.checker_name(e),
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
  local blocking, non_blocking = 0, 0
  for _, f in ipairs((util.decode(util.read_file(draft)) or {}).findings or {}) do
    if f.severity == "blocking" then
      blocking = blocking + 1
    else
      non_blocking = non_blocking + 1
    end
  end
  rules.mark_posted(e, {
    head = e.round_head, verdict = posted.state, review_id = posted.review_id, url = posted.url,
    blocking = blocking, non_blocking = non_blocking, merge_risk = posted.merge_risk,
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
  rules.mark_posted(e, { head = e.round_head, verdict = "DISMISSED", by = "you" }, util.now())
  ledger.save(e)
  M.set_status(e, "DISMISSED")
  ledger.append_event({ kind = "dismissed", repo = repo, pr = pr, round = e.round, head = e.round_head })
  nudge_watcher()
  return { repo = repo, pr = pr, round = e.round, dismissed = true }
end

---------------------------------------------------------------------------
-- Cleanup after a merge or close

function M.cleanup(repo, pr, session)
  local e = ledger.load(repo, pr)
  if not e then
    return nil
  end
  local checkout = config.load().repos[repo].checkout
  if session then
    M.close_pane(session, e.checker_pane)
    M.close_pane(session, e.pane)
  end
  if e.worktree and util.exists(e.worktree .. "/.git") then
    -- A base checkout an agent added under .tmp goes first.
    local list = util.run({ "git", "-C", checkout, "worktree", "list", "--porcelain" }).stdout
    for path in list:gmatch("worktree ([^\n]+)") do
      if path ~= e.worktree and path:sub(1, #e.worktree + 1) == e.worktree .. "/" then
        util.run({ "git", "-C", checkout, "worktree", "remove", "--force", path }, { check = false })
      end
    end
    util.run({ "git", "-C", checkout, "worktree", "remove", "--force", e.worktree })
    util.run({ "git", "-C", checkout, "worktree", "prune" }, { check = false })
    -- Claude Code's scratch folder for sessions started in the worktree.
    local uid = util.trim(util.run({ "id", "-u" }).stdout)
    local scratch = "/private/tmp/claude-" .. uid .. "/" .. (e.worktree:gsub("[^%w]", "-"))
    if util.exists(scratch) then
      util.run({ "rm", "-rf", scratch }, { check = false })
    end
  end
  local refs = util.run({ "git", "-C", checkout, "for-each-ref", "--format=%(refname)", string.format("refs/rex-reviewer/pr-%d/", pr) }).stdout
  for ref in refs:gmatch("[^\n]+") do
    util.run({ "git", "-C", checkout, "update-ref", "-d", ref })
  end
  local adapter = agents.reviewers[e.reviewer or config.load().reviewer]
  if adapter and adapter.archive then
    adapter:archive(e)
  end
  e.state = "cleaned"
  e.pane, e.checker_pane, e.phase = nil, nil, nil
  e.cleaned_at = util.now()
  ledger.save(e)
  ledger.append_event({ kind = "cleaned", repo = repo, pr = pr })
  return e
end

return M
