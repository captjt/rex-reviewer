-- Checks how lua/rex_reviewer/agents.lua passes folders to each reviewer:
-- Claude Code gets git's metadata as --add-dir and the caches through
-- --settings (an --add-dir folder you haven't trusted stops it at a trust
-- prompt), and Codex gets both as --add-dir, its sandbox's writable roots.
-- Run it with LuaJIT: `luajit tests/agents.lua`.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path

local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp .. "/config")
local f = assert(io.open(tmp .. "/config/config.lua", "w"))
f:write('return { repos = { ["acme/api"] = { checkout = "' .. tmp .. '" } } }\n')
f:close()

-- config reads these when it loads. LuaJIT has no setenv: a stand-in
-- os.getenv answers for them.
local real_getenv = os.getenv
local env = { REX_REVIEWER_CONFIG_DIR = tmp .. "/config", REX_REVIEWER_STATE_DIR = tmp .. "/state" }
os.getenv = function(k)
  return env[k] or real_getenv(k)
end

local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local agents = require("rex_reviewer.agents")

local count = { pass = 0, fail = 0 }
local function check(name, got, want)
  if got == want then
    count.pass = count.pass + 1
  else
    count.fail = count.fail + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", name, tostring(got), tostring(want)))
  end
end

-- The values after each --add-dir, and the decoded --settings, if any.
local function parse(argv)
  local added, settings, n = {}, nil, 0
  for i, a in ipairs(argv) do
    if a == "--add-dir" then
      added[#added + 1] = argv[i + 1]
    elseif a == "--settings" then
      n = n + 1
      settings = util.decode(argv[i + 1])
    end
  end
  return added, settings, n
end

local e = { repo = "acme/api", pr = 12, round = 1 }
local dirs = { "/repo/.git/worktrees" }
local caches = { "/home/.cache/rex-reviewer", "/home/.npm", "/home/go/pkg/mod" }

-- Claude Code: git metadata as --add-dir, every cache in the setting.
local added, settings, n = parse(agents.reviewers.claude:command(e, { name = "claude", primary = true }, dirs, caches, {}))
check("claude adds only git metadata", table.concat(added, " "), "/repo/.git/worktrees")
check("claude passes one --settings", n, 1)
local extra = settings and settings.permissions and settings.permissions.additionalDirectories or {}
check("claude caches in additionalDirectories", table.concat(extra, " "), table.concat(caches, " "))

-- With no caches, no --settings at all.
_, settings, n = parse(agents.reviewers.claude:command(e, { name = "claude", primary = true }, dirs, {}, {}))
check("claude without caches has no --settings", n, 0)

-- A resumed session takes the same folders.
added, settings = parse(agents.reviewers.claude:command(e, { name = "claude", session = "abc" }, dirs, caches, {}))
check("resumed claude adds only git metadata", table.concat(added, " "), "/repo/.git/worktrees")
check("resumed claude keeps the caches", settings and #settings.permissions.additionalDirectories, #caches)

-- Codex: both as --add-dir, its sandbox's writable roots; no --settings.
added, _, n = parse(agents.reviewers.codex:command(e, { name = "codex", worktree = "/wt" }, dirs, caches, {}))
check("codex adds git metadata and caches", table.concat(added, " "), table.concat(util.append({ "/repo/.git/worktrees" }, caches), " "))
check("codex has no --settings", n, 0)

os.execute("rm -rf " .. tmp)
print(string.format("%d passed, %d failed", count.pass, count.fail))
os.exit(count.fail == 0 and 0 or 1)
