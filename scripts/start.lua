-- Start the next round of a PR in a new tab of this Rex session.
--
--   rex do <rex-reviewer>/scripts/start.lua pr=602 [repo=owner/name]
--
-- Run reviewer_prep first. This is a script rather than an action because an
-- agent can take about 30 s to start, and Rex cuts actions off at 30 s. The
-- watcher does both steps on its own; this is for starting one by hand.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local ledger = require("rex_reviewer.ledger")
local rounds = require("rex_reviewer.rounds")

local pr = tonumber(rex.args.pr)
if not pr then
  error("usage: rex do start.lua pr=<number> [repo=owner/name]", 0)
end
local repo = config.repo(rex.args.repo, pr, ledger).slug
print(rex.json.encode(rounds.start(repo, pr, rex.args.session or rex.session_id)))
