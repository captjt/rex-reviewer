-- Agent adapters: how to start or resume each agent, find its session, and
-- name it, with its model, for the review's footer. Adding an agent means
-- adding an adapter here, and to AGENTS in config.lua.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local host = require("rex_reviewer.host")

local M = {}

local HOME = util.HOME

local function uuid()
  return util.trim(util.run({ "uuidgen" }).stdout):lower()
end

local function add_dirs(argv, dirs)
  for _, d in ipairs(dirs or {}) do
    argv[#argv + 1] = "--add-dir"
    argv[#argv + 1] = d
  end
  return argv
end

-- The adapter's own args, replaced by agents.<name>.args when set, plus
-- what the host needs (Codex's --no-daemon on Herdr), plus
-- agents.<name>.extra_args.
local function args_for(name, defaults)
  local a = config.load().agents[name] or {}
  local out = {}
  util.append(out, a.args or defaults)
  util.append(out, host.agent_args(name))
  util.append(out, a.extra_args)
  return out
end

-- Each agent's flag for an effort level, and how many args of the user's
-- an arg starts that set effort too (0 when it doesn't), so the round's
-- level wins over one in args or extra_args.
local EFFORT = {
  claude = {
    flag = function(level)
      return { "--effort", level }
    end,
    sets = function(a)
      return a == "--effort" and 2 or (a:match("^%-%-effort=") and 1 or 0)
    end,
  },
  codex = {
    flag = function(level)
      return { "-c", 'model_reasoning_effort="' .. level .. '"' }
    end,
    sets = function(a, b)
      if (a == "-c" or a == "--config") and b and b:match("^model_reasoning_effort=") then
        return 2
      end
      return a:match("^%-%-config=model_reasoning_effort=") and 1 or 0
    end,
  },
}

-- args with the agent's effort flag for level in place of any it had. With
-- no level, args as they are, so the agent's own setting holds.
local function with_effort(agent, args, level)
  local e = EFFORT[agent]
  if not level or not e then
    return args
  end
  local out, i = {}, 1
  while i <= #args do
    local n = e.sets(args[i], args[i + 1])
    if n > 0 then
      i = i + n
    else
      out[#out + 1] = args[i]
      i = i + 1
    end
  end
  return util.append(out, e.flag(level))
end

---------------------------------------------------------------------------
-- Claude Code

-- Claude Code keeps transcripts in ~/.claude/projects/<cwd with every
-- character that isn't a letter or digit replaced by ->/<session>.jsonl.
local function claude_transcript(cwd, session)
  return HOME .. "/.claude/projects/" .. (cwd:gsub("[^%w]", "-")) .. "/" .. session .. ".jsonl"
end

-- "claude-opus-5-5" → "Opus 5.5".
function M.claude_model_name(id)
  local family, rest = (id or ""):match("^claude%-(%a+)%-(.+)$")
  if not family then
    return id ~= "" and id or nil
  end
  local version = {}
  for part in rest:gmatch("[^-]+") do
    if not part:match("^%d%d?$") then
      break
    end
    version[#version + 1] = part
  end
  local name = family:sub(1, 1):upper() .. family:sub(2)
  if #version > 0 then
    name = name .. " " .. table.concat(version, ".")
  end
  return name
end

-- "Claude Code (Opus 5.5)": the model in the session's transcript.
function M.claude_name(cwd, session)
  local res = util.run({ "/bin/sh", "-c",
    [[grep -o '"model":"claude-[^"]*"' "$1" 2>/dev/null | tail -1 | cut -d'"' -f4]],
    "sh", claude_transcript(cwd, session or "none") }, { check = false })
  local model = M.claude_model_name(util.trim(res.stdout))
  return model and "Claude Code (" .. model .. ")" or "Claude Code"
end

-- The effort the session last ran at: Claude Code writes it on each reply.
function M.claude_effort(cwd, session)
  local res = util.run({ "/bin/sh", "-c",
    [[jq -r 'select(.type == "assistant") | .effort // empty' "$1" 2>/dev/null | tail -1]],
    "sh", claude_transcript(cwd, session or "none") }, { check = false })
  local level = util.trim(res.stdout)
  return level ~= "" and level or nil
end

---------------------------------------------------------------------------
-- Codex

local function codex_db()
  local res = util.run({ "/bin/sh", "-c", [[ls -t "$1"/state_*.sqlite 2>/dev/null | head -1]], "sh", HOME .. "/.codex" }, { check = false })
  local path = util.trim(res.stdout)
  return path ~= "" and path or nil
end

local function sql_quote(s)
  return "'" .. (s or ""):gsub("'", "''") .. "'"
end

-- Codex keeps its state in a WAL-mode database. A read-only connection
-- needs its -shm file, which exists only while Codex has the database open.
-- When it doesn't, the WAL is already in the file, so an immutable read of
-- the file alone is complete.
local function codex_query(db, sql)
  local res = util.run({ "sqlite3", "-readonly", db, sql }, { check = false })
  if not res.ok then
    res = util.run({ "sqlite3", "file:" .. db .. "?immutable=1", sql }, { check = false })
  end
  return res.ok and util.trim(res.stdout) or ""
end

-- The newest top-level Codex thread whose cwd is this worktree, started at
-- or after since (epoch seconds) when given, so a thread left by a failed
-- start isn't taken for a new one. Subagent threads share the cwd; their
-- source is JSON, so they're skipped.
function M.codex_thread(cwd, since)
  local db = codex_db()
  if not db then
    return nil
  end
  local sql = "select id from threads where cwd = " .. sql_quote(cwd)
    .. (since and (" and created_at >= " .. math.floor(since)) or "")
    .. " and archived = 0 and source not like '{%' order by created_at desc limit 1"
  local id = codex_query(db, sql)
  return id ~= "" and id or nil
end

-- "Codex (GPT-6.1-Sol)": the thread's model, by Codex's display name.
function M.codex_name(thread)
  local db = codex_db()
  local model = db and thread and codex_query(db, "select model from threads where id = " .. sql_quote(thread)) or ""
  if model == "" then
    return "Codex"
  end
  local models = util.decode(util.read_file(HOME .. "/.codex/models_cache.json"))
  for _, m in ipairs(models and models.models or {}) do
    if m.slug == model and m.display_name then
      return "Codex (" .. m.display_name .. ")"
    end
  end
  return "Codex (" .. model .. ")"
end

-- The effort the thread last ran at: its rollout records each turn's, and
-- the thread's row the latest when the rollout can't be read.
function M.codex_effort(thread)
  local db = codex_db()
  if not db or not thread then
    return nil
  end
  local rollout = codex_query(db, "select rollout_path from threads where id = " .. sql_quote(thread))
  local level = ""
  if rollout ~= "" then
    local res = util.run({ "/bin/sh", "-c",
      [[grep -F '"type":"turn_context"' "$1" 2>/dev/null | tail -1 | jq -r '.payload.effort // empty' 2>/dev/null]],
      "sh", rollout }, { check = false })
    level = util.trim(res.stdout)
  end
  if level == "" then
    level = codex_query(db, "select reasoning_effort from threads where id = " .. sql_quote(thread))
  end
  return level ~= "" and level or nil
end

---------------------------------------------------------------------------
-- Reviewers: one agent per reviewer in the config, resumed every round. An
-- adapter works on the reviewer's record r in the ledger entry's reviewers:
-- its worktree, pane, session, and the round's effort level (r.effort, nil
-- for the agent's own). extra is the reviewer's own extra_args.

M.reviewers = {}

M.reviewers.codex = {
  program = "codex",
  -- --approve-for-me also sets the workspace-write sandbox. Codex's app
  -- connectors and its GitHub plugin are off, so the reviewer can't write
  -- to GitHub.
  defaults = {
    "--approve-for-me",
    "--no-alt-screen",
    "--disable", "apps",
    "-c", 'plugins."github@openai-curated".enabled=false',
  },
  command = function(self, _, r, dirs, extra)
    local argv = { "codex" }
    if r.session then
      util.append(argv, { "resume", r.session })
    end
    local args = util.append(args_for("codex", self.defaults), extra)
    util.append(argv, with_effort("codex", args, r.effort))
    add_dirs(argv, dirs)
    return util.append(argv, { "-C", r.worktree })
  end,
  -- Codex names its thread after the first prompt; find it by cwd. Each
  -- reviewer has its own worktree, so the cwd is the reviewer's.
  session_after_start = function(_, r, since)
    for _ = 1, 15 do
      local id = r.session or M.codex_thread(r.worktree, since)
      if id then
        return id
      end
      util.run({ "sleep", "2" })
    end
  end,
  name = function(_, r)
    return M.codex_name(r.session)
  end,
  effort = function(_, r)
    return M.codex_effort(r.session)
  end,
  archive = function(_, r)
    if r.session then
      util.run({ "codex", "archive", r.session }, { check = false })
    end
  end,
}

M.reviewers.claude = {
  program = "claude",
  defaults = { "--permission-mode", "auto" },
  command = function(self, e, r, dirs, extra)
    local argv = { "claude" }
    if r.session then
      util.append(argv, { "--resume", r.session })
    else
      r.session = uuid()
      util.append(argv, { "--session-id", r.session })
    end
    local args = util.append(args_for("claude", self.defaults), extra)
    util.append(argv, with_effort("claude", args, r.effort))
    add_dirs(argv, dirs)
    local label = string.format("%s %s#%d", config.APP, e.repo, e.pr)
    if not r.primary then
      label = label .. " " .. r.name
    end
    return util.append(argv, { "-n", label })
  end,
  session_after_start = function(_, r)
    return r.session
  end,
  name = function(_, r)
    return M.claude_name(r.worktree, r.session)
  end,
  effort = function(_, r)
    return M.claude_effort(r.worktree, r.session)
  end,
}

-- The footer's byline for the reviewers, in order, without repeats:
-- "Codex (GPT-6.1-Sol) and Claude Code (Opus 5.5)".
function M.byline(rs)
  local names, seen = {}, {}
  for _, r in ipairs(rs) do
    local adapter = M.reviewers[r.agent]
    local n = adapter and adapter:name(r) or r.agent
    if n and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end
  if #names <= 1 then
    return names[1] or config.APP
  end
  return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

---------------------------------------------------------------------------
-- The checker: a fresh agent each round (config.checker), at the round's
-- check effort (e.checker_effort) when there is one. It may run the preview
-- action, and the post action only when post = "auto". dirs are the other
-- reviewers' worktrees, where their probes and builds are.

local function checker_label(e)
  return string.format("%s %s#%d round %d check", config.APP, e.repo, e.pr, e.round)
end

M.checkers = {}

-- Claude Code: deny rules hold in every permission mode, so dismiss is
-- always denied and post is denied unless post = "auto". rounds.post also
-- refuses a post with post = "ask" until the round waits for you, whatever
-- the checker's agent.
M.checkers.claude = {
  program = "claude",
  command = function(_, e, dirs)
    local c = config.load()
    e.checker_session = uuid()
    local argv = { "claude", "--session-id", e.checker_session }
    local args = util.append(args_for("claude", { "--permission-mode", "auto" }), c.checker_extra_args)
    util.append(argv, with_effort("claude", args, e.checker_effort))
    add_dirs(argv, dirs)
    local allowed = { host.allow("reviewer_preview") }
    local denied = { host.allow("reviewer_dismiss") }
    if c.post == "auto" then
      allowed[#allowed + 1] = host.allow("reviewer_post")
    else
      denied[#denied + 1] = host.allow("reviewer_post")
    end
    argv[#argv + 1] = "--allowedTools"
    util.append(argv, allowed)
    argv[#argv + 1] = "--disallowedTools"
    util.append(argv, denied)
    return util.append(argv, { "-n", checker_label(e) })
  end,
  session_after_start = function(_, e)
    return e.checker_session
  end,
  name = function(_, e)
    return M.claude_name(e.worktree, e.checker_session)
  end,
  effort = function(_, e)
    return e.checker_session and M.claude_effort(e.worktree, e.checker_session) or nil
  end,
}

-- Codex: the reviewers' flags, plus network in the sandbox, which preview
-- and post need: the rex CLI reaches the Rex server's socket, and on Herdr
-- the action runs here and calls GitHub. Codex
-- can't deny one command per session; rounds.post holds the review with
-- post = "ask" instead. Its thread is found by cwd, like a reviewer's; the
-- primary's thread in the same worktree is older than since.
M.checkers.codex = {
  program = "codex",
  command = function(_, e, dirs)
    e.checker_session = nil
    local args = args_for("codex", M.reviewers.codex.defaults)
    util.append(args, { "-c", "sandbox_workspace_write.network_access=true" })
    util.append(args, config.load().checker_extra_args)
    local argv = { "codex" }
    util.append(argv, with_effort("codex", args, e.checker_effort))
    add_dirs(argv, dirs)
    return util.append(argv, { "-C", e.worktree })
  end,
  session_after_start = function(_, e, since)
    for _ = 1, 15 do
      local id = M.codex_thread(e.worktree, since)
      if id then
        return id
      end
      util.run({ "sleep", "2" })
    end
  end,
  name = function(_, e)
    return M.codex_name(e.checker_session)
  end,
  effort = function(_, e)
    return e.checker_session and M.codex_effort(e.checker_session) or nil
  end,
  archive = function(_, id)
    util.run({ "codex", "archive", id }, { check = false })
  end,
}

-- The adapter for a round's checker: the agent it started as
-- (e.checker_agent), so a change to config.checker mid-round doesn't read
-- its session as another agent's. A round from before checker_agent was
-- recorded falls back to the config.
local function checker(e)
  return M.checkers[e.checker_agent or config.load().checker]
end

function M.checker_program(e)
  return checker(e).program
end

-- Starts the round's checker as config.checker and records it in
-- e.checker_agent.
function M.checker_command(e, dirs)
  e.checker_agent = config.load().checker
  return checker(e):command(e, dirs)
end

-- The checker's session once it has taken its first prompt; since is when
-- it started (epoch seconds).
function M.checker_session_after_start(e, since)
  return checker(e):session_after_start(e, since)
end

function M.checker_name(e)
  return checker(e):name(e)
end

function M.checker_effort(e)
  return checker(e):effort(e)
end

-- Archive the Codex threads of a PR's checkers, as cleanup does the
-- reviewers'. Claude Code keeps no list to archive.
function M.archive_checkers(e)
  for _, id in ipairs(type(e.checker_threads) == "table" and e.checker_threads or {}) do
    M.checkers.codex:archive(id)
  end
end

return M
