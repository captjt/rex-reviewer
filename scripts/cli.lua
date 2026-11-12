-- rex-reviewer's actions outside Rex, under LuaJIT. bin/rex-reviewer runs
-- it when the config's host isn't Rex:
--
--   luajit scripts/cli.lua <action> [key=value ...] [--json]
--   luajit scripts/cli.lua <script.lua> [key=value ...]
--   luajit scripts/cli.lua --host        the config's host; rex if it can't say
--   luajit scripts/cli.lua --list        the actions, one a line
--   luajit scripts/cli.lua --request <action> [key=value ...]
--                                        ask the watcher to run it, from a
--                                        round's worktree (see requests.lua)
--
-- An action's result prints as JSON, except a preview, which prints as the
-- review. An error prints as "Error: <what>" on stderr and exits 1, as
-- `rex do` does.

-- This checkout, from where this script is, made absolute: the actions run
-- commands from the home folder.
local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
if SRC:sub(1, 1) ~= "/" then
  SRC = (os.getenv("PWD") or ".") .. "/" .. SRC
end
local ROOT = SRC:match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local runtime = require("rex_reviewer.runtime")
local config = require("rex_reviewer.config")
config.set_root(ROOT)

local function fail(msg)
  io.stderr:write("Error: ", tostring(msg), "\n")
  os.exit(1)
end

local words = {}
for i = 1, select("#", ...) do
  words[i] = select(i, ...)
end
local name = table.remove(words, 1)

if name == "--host" then
  local ok, c = pcall(config.load)
  print(ok and c.host or "rex")
  return
end

if not name or name == "-h" or name == "--help" then
  io.stderr:write("usage: cli.lua <action> [key=value ...] [--json] | <script.lua> [key=value ...] | --host | --list\n")
  os.exit(name and 0 or 1)
end

-- --json is what Rex's `rex do` takes for JSON output; it's always JSON here.
local args = {}
for _, w in ipairs(words) do
  if w ~= "--json" then
    args[#args + 1] = w
  end
end

local util = require("rex_reviewer.util")

-- A preview prints as the review, as an agent reads it; anything else as
-- JSON.
local function show(res)
  if type(res) == "table" and type(res.preview) == "string" then
    io.write(res.preview, res.preview:sub(-1) == "\n" and "" or "\n")
    return
  end
  print(util.json(res == nil and {} or res))
end

if name == "--request" then
  local requests = require("rex_reviewer.requests")
  local action = table.remove(args, 1)
  if not action then
    fail("give an action: --request reviewer_preview repo=owner/name pr=12")
  end
  local parsed = {}
  for _, w in ipairs(args) do
    local k, v = w:match("^([%w_]+)=(.*)$")
    if not k then
      fail("arguments look like key=value, not " .. w)
    end
    parsed[k] = v
  end
  local ok, res = pcall(requests.submit, os.getenv("PWD") or ".", action, parsed)
  if not ok then
    fail(res)
  end
  show(res)
  return
end

if name:match("%.lua$") then
  local parsed = {}
  for _, w in ipairs(args) do
    local k, v = w:match("^([%w_]+)=(.*)$")
    if not k then
      fail("arguments look like key=value, not " .. w)
    end
    parsed[k] = v
  end
  runtime.ARGS = parsed
  local ok, err = pcall(dofile, name)
  if not ok then
    fail(err)
  end
  return
end

local actions = require("rex_reviewer.actions")

if name == "--list" then
  for _, a in ipairs(actions.list) do
    print(a.name .. "\t" .. a.title)
  end
  return
end

local a = actions.by_name[name]
if not a then
  fail(string.format("no action named %s; `--list` shows them", name))
end
local ok, res = pcall(function()
  return a.run(actions.parse(a.args, args))
end)
if not ok then
  fail(res)
end
-- With --json, a preview prints as JSON too, as `rex do --json` does.
local json_out = false
for _, w in ipairs(words) do
  json_out = json_out or w == "--json"
end
if json_out then
  print(util.json(res == nil and {} or res))
else
  show(res)
end
