-- The user's config, ~/.config/rex-reviewer/config.lua, with defaults filled
-- in and checked. Both Rex's init.lua and the watcher script load it, so it
-- is a Lua file that returns a table: hooks are plain functions.

local util = require("rex_reviewer.util")

local M = {}

local HOME = util.HOME
M.ROOT = nil -- the checkout of rex-reviewer, set by the entry point
M.CONFIG_DIR = HOME .. "/.config/rex-reviewer"
M.STATE_DIR = HOME .. "/.local/state/rex-reviewer"
M.DATA_DIR = HOME .. "/.local/share/rex-reviewer"
M.CACHE_DIR = HOME .. "/.cache/rex-reviewer"

-- Caches reviewers may write to, so no review copies the source or builds a
-- private cache. Only the ones that exist are passed on.
local DEFAULT_CACHES = {
  "~/Library/Caches/go-build",
  "~/.cache/go-build",
  "~/go/pkg/mod",
  "~/.npm",
  "~/Library/pnpm/store",
  "~/.local/share/pnpm/store",
  "~/.cache/uv",
  "~/Library/Caches/ms-playwright",
  "~/.cache/ms-playwright",
  "~/.cargo/registry",
  "~/.cargo/git",
  "~/.cargo/advisory-dbs",
}

-- Guides are pluggable: each slot points the agents at your own skill or
-- instructions. A value is a path to a file (a SKILL.md, a style guide), a
-- string of instructions, a function(pr) that returns either, "bundled" for
-- the guide in guides/, or false for none. A repo's own guides override
-- these slot by slot.
--   review      how the reviewer looks for problems
--   style       how the posted review reads
--   merge_risk  the rubric for the merge-risk assessment (false: no assessment)
--   check       extra instructions for the checker
local DEFAULT_GUIDES = {
  review = false,
  style = "bundled",
  merge_risk = "bundled",
  check = false,
}

local BUNDLED = {
  style = "guides/review-style.md",
  merge_risk = "guides/merge-risk.md",
}

local DEFAULTS = {
  reviewer = "codex",
  checker = "claude",
  post = "ask",
  max_rounds = 3,
  poll_seconds = 180,
  session = "rex-reviewer",
  caches = DEFAULT_CACHES,
  extra_caches = {},
  path = {},
  agents = {},
  hooks = {},
}

local REVIEWERS = { codex = true, claude = true }
local POST_MODES = { ask = true, auto = true }

local loaded

function M.set_root(root)
  M.ROOT = root
end

function M.path()
  return M.CONFIG_DIR .. "/config.lua"
end

local function fail(msg)
  error("rex-reviewer config (" .. M.path() .. "): " .. msg, 0)
end

local function normalize_repos(repos)
  if type(repos) ~= "table" then
    fail("repos must be a table, such as { [\"owner/name\"] = { checkout = \"~/src/name\" } }")
  end
  local out, by_slug = {}, {}
  for slug, r in pairs(repos) do
    if type(slug) ~= "string" or not util.split_slug(slug) then
      fail("each repo key must be \"owner/name\", not " .. tostring(slug))
    end
    if type(r) ~= "table" or type(r.checkout) ~= "string" then
      fail(slug .. " needs checkout, the path of a clone whose origin is " .. slug)
    end
    if r.guides ~= nil and type(r.guides) ~= "table" then
      fail(slug .. ".guides must be a table")
    end
    local owner, name = util.split_slug(slug)
    local repo = {
      slug = slug,
      owner = owner,
      name = name,
      checkout = util.expand(r.checkout),
      notes = r.notes or "",
      guides = r.guides or {},
    }
    out[#out + 1] = repo
    by_slug[slug] = repo
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  if #out == 0 then
    fail("add at least one repo to repos")
  end
  return out, by_slug
end

-- Load and check the config once per Lua state.
function M.load()
  if loaded then
    return loaded
  end
  local path = M.path()
  if not util.exists(path) then
    fail("not found. Run `rex-reviewer setup` to create it from the example")
  end
  local ok, user = pcall(dofile, path)
  if not ok then
    fail(tostring(user))
  end
  if type(user) ~= "table" then
    fail("it must return a table")
  end

  local c = {}
  for k, v in pairs(DEFAULTS) do
    c[k] = v
  end
  for k, v in pairs(user) do
    c[k] = v
  end
  c.repo_list, c.repos = normalize_repos(user.repos)

  if not REVIEWERS[c.reviewer] then
    fail("reviewer must be \"codex\" or \"claude\", not " .. tostring(c.reviewer))
  end
  if c.checker ~= "claude" then
    fail("checker must be \"claude\"; it's the only checker so far")
  end
  if not POST_MODES[c.post] then
    fail("post must be \"ask\" or \"auto\", not " .. tostring(c.post))
  end
  if type(c.max_rounds) ~= "number" or c.max_rounds < 1 then
    fail("max_rounds must be a number of 1 or more")
  end
  if type(c.poll_seconds) ~= "number" or c.poll_seconds < 30 then
    fail("poll_seconds must be 30 or more")
  end
  if c.hooks.should_review ~= nil and type(c.hooks.should_review) ~= "function" then
    fail("hooks.should_review must be a function")
  end
  if user.guides ~= nil and type(user.guides) ~= "table" then
    fail("guides must be a table")
  end
  local guides = {}
  for slot, v in pairs(DEFAULT_GUIDES) do
    guides[slot] = v
  end
  for slot, v in pairs(user.guides or {}) do
    if DEFAULT_GUIDES[slot] == nil then
      fail("guides." .. tostring(slot) .. " isn't a guide slot; the slots are review, style, merge_risk, and check")
    end
    guides[slot] = v
  end
  c.guides = guides

  local caches = {}
  for _, d in ipairs(c.caches or {}) do
    caches[#caches + 1] = util.expand(d)
  end
  for _, d in ipairs(c.extra_caches or {}) do
    caches[#caches + 1] = util.expand(d)
  end
  c.caches = caches
  c.agents.codex = c.agents.codex or {}
  c.agents.claude = c.agents.claude or {}
  util.set_extra_path(c.path)

  loaded = c
  return c
end

-- What a guide slot says for this repo and PR, as text for a brief: an
-- instruction to read a file, the instructions themselves, or nil for none.
function M.guide(repo, slot, pr)
  local c = M.load()
  local v = repo.guides[slot]
  if v == nil then
    v = c.guides[slot]
  end
  if type(v) == "function" then
    v = v(pr)
  end
  if v == nil or v == false or v == "" then
    return nil
  end
  if type(v) ~= "string" then
    error(string.format("guides.%s for %s must be a path, instructions, a function, or false", slot, repo.slug), 0)
  end
  if v == "bundled" then
    v = M.ROOT .. "/" .. assert(BUNDLED[slot], "no bundled guide for " .. slot)
  end
  local path = util.expand(v)
  if path:match("^/") and not path:find("\n") then
    if not util.exists(path) then
      error(string.format("guides.%s for %s: %s doesn't exist", slot, repo.slug, path), 0)
    end
    return "Read `" .. path .. "` and follow it."
  end
  return v
end

-- The repo for an action: the one named, or the only one configured, or the
-- only one with that PR in the ledger.
function M.repo(slug, pr, ledger)
  local c = M.load()
  if slug and slug ~= "" then
    local r = c.repos[slug]
    if not r then
      error(slug .. " isn't in repos in " .. M.path(), 0)
    end
    return r
  end
  if #c.repo_list == 1 then
    return c.repo_list[1]
  end
  if pr and ledger then
    local found
    for _, r in ipairs(c.repo_list) do
      if ledger.load(r.slug, pr) then
        if found then
          error(string.format("#%d is in more than one repo; pass repo=owner/name", pr), 0)
        end
        found = r
      end
    end
    if found then
      return found
    end
  end
  error("pass repo=owner/name; more than one repo is configured", 0)
end

return M
