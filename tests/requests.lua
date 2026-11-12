-- Checks lua/rex_reviewer/requests.lua: what the watcher runs for an agent
-- on Herdr, and what it refuses. It needs no herdr-core or GitHub: the
-- action is a stand-in. Run it with LuaJIT: `luajit tests/requests.lua`.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path

-- A folder of its own for the config, the ledger, and a worktree.
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p " .. tmp .. "/config " .. tmp .. "/state " .. tmp .. "/wt/.tmp/requests")
local f = assert(io.open(tmp .. "/config/config.lua", "w"))
f:write('return { host = "herdr", post = "ask", repos = { ["acme/api"] = { checkout = "' .. tmp .. '" } } }\n')
f:close()

-- config reads these when it loads, so set them first. LuaJIT has no
-- setenv: a stand-in os.getenv answers for them.
local real_getenv = os.getenv
local env = { REX_REVIEWER_CONFIG_DIR = tmp .. "/config", REX_REVIEWER_STATE_DIR = tmp .. "/state" }
os.getenv = function(k)
  return env[k] or real_getenv(k)
end

local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local requests = require("rex_reviewer.requests")

local count = { pass = 0, fail = 0 }
local function check(name, got, want)
  if got == want then
    count.pass = count.pass + 1
  else
    count.fail = count.fail + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", name, tostring(got), tostring(want)))
  end
end

local wt = tmp .. "/wt"
local function entry(phase)
  ledger.save({ repo = "acme/api", pr = 12, round = 2, state = "reviewing", phase = phase, worktree = wt })
end

local function request(id, req)
  util.write_file(wt .. "/.tmp/requests/" .. id .. ".json", util.json(req))
end

local function result(id)
  return util.decode(util.read_file(wt .. "/.tmp/requests/" .. id .. ".result.json") or "")
end

local ran = {}
local function run_action(name, args)
  ran[#ran + 1] = name .. " " .. args.repo .. "#" .. args.pr
  if name == "reviewer_preview" then
    return { preview = "the review" }
  end
  error("GitHub refused it", 0)
end

-- While the checker checks, a preview runs, for the round's own PR.
entry("checking")
request("a", { action = "reviewer_preview", args = { repo = "evil/repo", pr = 1 } })
requests.serve(run_action)
check("preview ran", ran[1], "reviewer_preview acme/api#12")
check("preview result", result("a") and result("a").ok, true)
check("preview text", result("a") and result("a").result.preview, "the review")
check("request removed", util.exists(wt .. "/.tmp/requests/a.json"), false)

-- An action that fails reports why.
config.load().post = "auto"
request("b", { action = "reviewer_post" })
requests.serve(run_action)
check("post error", result("b") and result("b").error, "GitHub refused it")
config.load().post = "ask"

-- With post = "ask", post waits for you.
request("c", { action = "reviewer_post" })
requests.serve(run_action)
check("post refused with ask", result("c") and result("c").error:match("^post = \"ask\"") ~= nil, true)

-- Only preview and post.
request("d", { action = "reviewer_dismiss" })
requests.serve(run_action)
check("dismiss refused", result("d") and result("d").ok, false)
check("submit refuses dismiss", pcall(requests.submit, wt, "reviewer_dismiss", {}), false)

-- Not while the reviewers review, or once it waits for you.
for _, phase in ipairs({ "reviewer", "awaiting" }) do
  entry(phase)
  request("e", { action = "reviewer_preview" })
  requests.serve(run_action)
  check("refused in phase " .. phase, result("e") and result("e").error:match("isn't being checked") ~= nil, true)
  os.remove(wt .. "/.tmp/requests/e.result.json")
end
check("ran nothing else", #ran, 2)

-- The agent's side reads the result the watcher left. With none, it gives up.
check("submit times out", select(2, pcall(requests.submit, wt, "reviewer_preview", {}, 1)):match("didn't answer") ~= nil, true)

os.execute("rm -rf " .. tmp)
print(string.format("%d passed, %d failed", count.pass, count.fail))
os.exit(count.fail == 0 and 0 or 1)
