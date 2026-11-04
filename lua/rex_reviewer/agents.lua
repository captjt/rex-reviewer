-- Agent adapters: how to start or resume each agent, find its session, and
-- name it, with its model, for the review's footer. Adding an agent means
-- adding an adapter here.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")

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
-- agents.<name>.extra_args.
local function args_for(name, defaults)
  local a = config.load().agents[name] or {}
  local out = {}
  util.append(out, a.args or defaults)
  util.append(out, a.extra_args)
  return out
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

-- The newest top-level Codex thread whose cwd is this worktree. Subagent
-- threads share the cwd; their source is JSON, so they're skipped.
function M.codex_thread(cwd)
  local db = codex_db()
  if not db then
    return nil
  end
  local sql = "select id from threads where cwd = " .. sql_quote(cwd)
    .. " and archived = 0 and source not like '{%' order by created_at desc limit 1"
  local id = util.trim(util.run({ "sqlite3", "-readonly", db, sql }, { check = false }).stdout)
  return id ~= "" and id or nil
end

-- "Codex (GPT-6.1-Sol)": the thread's model, by Codex's display name.
function M.codex_name(thread)
  local db = codex_db()
  local model = db and thread and util.trim(util.run({ "sqlite3", "-readonly", db,
    "select model from threads where id = " .. sql_quote(thread) }, { check = false }).stdout) or ""
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

---------------------------------------------------------------------------
-- Reviewers: one agent per PR, resumed every round.

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
  command = function(self, e, dirs)
    local argv = { "codex" }
    if e.reviewer_session then
      util.append(argv, { "resume", e.reviewer_session })
    end
    util.append(argv, args_for("codex", self.defaults))
    add_dirs(argv, dirs)
    return util.append(argv, { "-C", e.worktree })
  end,
  -- Codex names its thread after the first prompt; find it by cwd.
  session_after_start = function(_, e)
    for _ = 1, 15 do
      local id = e.reviewer_session or M.codex_thread(e.worktree)
      if id then
        return id
      end
      util.run({ "sleep", "2" })
    end
  end,
  name = function(_, e)
    return M.codex_name(e.reviewer_session)
  end,
  archive = function(_, e)
    if e.reviewer_session then
      util.run({ "codex", "archive", e.reviewer_session }, { check = false })
    end
  end,
}

M.reviewers.claude = {
  program = "claude",
  defaults = { "--permission-mode", "auto" },
  command = function(self, e, dirs)
    local argv = { "claude" }
    if e.reviewer_session then
      util.append(argv, { "--resume", e.reviewer_session })
    else
      e.reviewer_session = uuid()
      util.append(argv, { "--session-id", e.reviewer_session })
    end
    util.append(argv, args_for("claude", self.defaults))
    add_dirs(argv, dirs)
    return util.append(argv, { "-n", string.format("rex-reviewer %s", e.repo .. "#" .. e.pr) })
  end,
  session_after_start = function(_, e)
    return e.reviewer_session
  end,
  name = function(_, e)
    return M.claude_name(e.worktree, e.reviewer_session)
  end,
}

function M.reviewer()
  return M.reviewers[config.load().reviewer]
end

---------------------------------------------------------------------------
-- The checker: a fresh Claude Code each round. It may run the preview
-- action, and the post action only when post = "auto". Deny rules hold in
-- every permission mode.

function M.checker_command(e)
  local c = config.load()
  e.checker_session = uuid()
  local argv = { "claude", "--session-id", e.checker_session }
  util.append(argv, args_for("claude", { "--permission-mode", "auto" }))
  local allowed = { "Bash(rex do reviewer_preview:*)" }
  local denied = { "Bash(rex do reviewer_dismiss:*)" }
  if c.post == "auto" then
    allowed[#allowed + 1] = "Bash(rex do reviewer_post:*)"
  else
    denied[#denied + 1] = "Bash(rex do reviewer_post:*)"
  end
  argv[#argv + 1] = "--allowedTools"
  util.append(argv, allowed)
  argv[#argv + 1] = "--disallowedTools"
  util.append(argv, denied)
  return util.append(argv, { "-n", string.format("rex-reviewer %s#%d round %d check", e.repo, e.pr, e.round) })
end

function M.checker_name(e)
  return M.claude_name(e.worktree, e.checker_session)
end

return M
