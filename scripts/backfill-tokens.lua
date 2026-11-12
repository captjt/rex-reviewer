-- Count the tokens of PRs reviewed before rex-reviewer counted them, from
-- the agents' logs that are still on disk. A dry run unless save=true:
--
--   rex do <rex-reviewer>/scripts/backfill-tokens.lua [save=true] [also=<path>]
--
-- A round's share is what the agents had logged by the time it ended, less
-- the rounds before it. Counts already in the ledger stay as they are, and a
-- round in progress is left to the watcher, which counts it when it ends.
-- A round whose share comes to nothing keeps no count, since its logs are
-- likely gone.
--
-- also= adds a worktree path from an earlier setup, with {owner}, {name},
-- and {pr} filled in: also=~/.local/share/pr-review/{name}/review-pr-{pr}

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local rules = require("rex_reviewer.rules")
local rounds = require("rex_reviewer.rounds")

local args = require("rex_reviewer.runtime").args()
local save = args.save == true or args.save == "true"
local also = args.also and util.expand(args.also)

-- The worktrees the PR's agents may have run in: every reviewer's.
local function worktrees(e)
  local out, seen = {}, {}
  local function add(path)
    if path and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  add(rounds.worktree_path(e))
  for _, path in ipairs(rounds.worktrees(e)) do
    add(path)
  end
  if also then
    local owner, name = util.split_slug(e.repo)
    add((also:gsub("{owner}", owner):gsub("{name}", name):gsub("{pr}", tostring(e.pr))))
  end
  return out
end

-- bin/token-usage over each worktree, by the cutoff when given, with each
-- agent's counts added up.
local function usage(e, cutoff)
  local sum = { total = 0 }
  for _, path in ipairs(worktrees(e)) do
    local argv = { config.ROOT .. "/bin/token-usage" }
    if cutoff then
      util.append(argv, { "--until", cutoff })
    end
    argv[#argv + 1] = path
    local res = util.run(argv, { check = false })
    local t = res.ok and util.decode(res.stdout)
    if not t then
      error(string.format("%s: token-usage failed on %s: %s", ledger.label(e), path, util.trim(res.stderr)), 0)
    end
    rules.add_tokens(sum, t)
  end
  return sum
end

local report = {}
for _, e in ipairs(ledger.list()) do
  if e.state ~= "reviewing" and e.state ~= "queued" then
    local history = type(e.history) == "table" and e.history or {}
    local total = usage(e)
    local found = { repo = e.repo, pr = e.pr, total = total.total, rounds = {} }
    local fill = {}
    if total.total > 0 then
      local before = rules.flat_tokens({})
      for i, r in ipairs(history) do
        if r.at then
          local upto = rules.flat_tokens(usage(e, r.at))
          local share = rules.token_delta(before, upto)
          if not r.tokens and share.total > 0 then
            fill[i] = share
          end
          found.rounds[#found.rounds + 1] = { round = r.round, at = r.at, total = share.total, kept = r.tokens ~= nil }
          before = upto
        end
      end
    end
    found.saves_total = e.tokens == nil and total.total > 0
    found.saves_rounds = 0
    for _ in pairs(fill) do
      found.saves_rounds = found.saves_rounds + 1
    end
    if save and (found.saves_total or found.saves_rounds > 0) then
      -- The watcher may have written the entry since it was read; apply the
      -- counts to the copy on disk now, unless a round has started.
      local fresh = ledger.load(e.repo, e.pr)
      if fresh and fresh.state ~= "reviewing" and fresh.state ~= "queued" then
        if fresh.tokens == nil and total.total > 0 then
          fresh.tokens = total
        end
        for i, share in pairs(fill) do
          local r = type(fresh.history) == "table" and fresh.history[i]
          if r and r.at == history[i].at and not r.tokens then
            r.tokens = share
          end
        end
        ledger.save(fresh)
        found.saved = true
      end
    end
    report[#report + 1] = found
  end
end

print(util.json({ dry_run = not save, prs = report }))
