-- Actions an agent asks the watcher to run, on hosts without a server to
-- run them (Herdr). In Rex, the checker's `rex do reviewer_post` reaches the
-- Rex server, which runs the action outside the agent's sandbox, with your
-- gh login. Here the checker runs `rex-reviewer request reviewer_post …`
-- from its worktree instead: that leaves a request in the worktree, which
-- the agent can write, and waits. The watcher, outside the sandbox, runs it
-- on its next tick and leaves the result beside it.
--
--   <worktree>/.tmp/requests/<id>.json          { action, args, at }
--   <worktree>/.tmp/requests/<id>.result.json   { ok, result | error }
--
-- The watcher runs only the preview and post actions, only for the round
-- whose worktree holds the request, and only while its checker checks. Post
-- still needs post = "auto", as the checker's brief and permissions do.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")
local ledger = require("rex_reviewer.ledger")

local M = {}

M.ALLOWED = { reviewer_preview = true, reviewer_post = true }

local function dir_of(worktree)
  return worktree .. "/.tmp/requests"
end

---------------------------------------------------------------------------
-- The agent's side

-- Leave a request in worktree and wait up to timeout seconds for its
-- result. Returns the result, or raises its error.
function M.submit(worktree, action, args, timeout)
  if not M.ALLOWED[action] then
    error(string.format("%s can't be requested; only reviewer_preview and reviewer_post can", action), 0)
  end
  local dir = dir_of(worktree)
  util.mkdirp(dir)
  local id = string.format("%d-%06d", os.time(), math.floor((os.clock() * 1e6) % 1e6))
  local path = dir .. "/" .. id
  util.write_file(path .. ".json", util.json({ action = action, args = args or {}, at = util.now() }) .. "\n")
  local waited, told = 0, false
  timeout = timeout or 600
  while waited < timeout do
    local res = util.decode(util.read_file(path .. ".result.json") or "")
    if type(res) == "table" then
      os.remove(path .. ".result.json")
      if not res.ok then
        error(tostring(res.error or "the watcher couldn't run it"), 0)
      end
      return res.result
    end
    if waited >= 10 and not told then
      io.stderr:write("waiting for the watcher to run it…\n")
      told = true
    end
    util.run({ "sleep", "1" })
    waited = waited + 1
  end
  os.remove(path .. ".json")
  error(string.format("the watcher didn't answer within %ds; is it running? (rex-reviewer status)", timeout), 0)
end

---------------------------------------------------------------------------
-- The watcher's side

local function refuse(path, msg)
  util.write_file(path .. ".result.json", util.json({ ok = false, error = msg }) .. "\n")
  os.remove(path .. ".json")
end

-- Run the requests waiting in each round's worktree. run_action(name, args)
-- runs an action and returns its result. log takes a line.
function M.serve(run_action, log)
  local c = config.load()
  for _, e in ipairs(ledger.list()) do
    if e.state == "reviewing" and e.worktree then
      local dir = dir_of(e.worktree)
      local res = util.run({ "find", dir, "-maxdepth", "1", "-name", "*.json", "!", "-name", "*.result.json" }, { check = false })
      for file in (res.stdout or ""):gmatch("[^\n]+") do
        local path = file:gsub("%.json$", "")
        local req = util.decode(util.read_file(file) or "")
        local label = ledger.label(e)
        if type(req) ~= "table" or not M.ALLOWED[req.action] then
          refuse(path, "only reviewer_preview and reviewer_post can be requested")
        elseif e.phase ~= "checking" then
          refuse(path, string.format("%s round %d isn't being checked (its phase is %s); nothing was done", label, e.round, e.phase or "reviewer"))
        elseif req.action == "reviewer_post" and c.post ~= "auto" then
          refuse(path, string.format("post = \"%s\": %s waits for you to post it; nothing was posted", c.post, label))
        else
          -- The round's own PR, whatever the request named.
          local ok, out = pcall(run_action, req.action, { repo = e.repo, pr = e.pr })
          util.write_file(path .. ".result.json",
            util.json(ok and { ok = true, result = out } or { ok = false, error = tostring(out) }) .. "\n")
          os.remove(path .. ".json")
          if log then
            log(string.format("%s round %d: ran %s for the checker%s", label, e.round, req.action, ok and "" or (": " .. tostring(out))))
          end
        end
      end
    end
  end
end

return M
