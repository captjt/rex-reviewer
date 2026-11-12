-- The Lua that runs rex-reviewer: Rex's own, inside the Rex server, or
-- LuaJIT on its own, as on Herdr. Both give the rest of the code the same
-- few things: run a command, read and write JSON, log a line, and the
-- arguments a script was given.

local M = {}

local rex = rawget(_G, "rex")
M.name = rex and "rex" or "luajit"

if rex then
  function M.exec(argv, opts)
    return rex.exec.start(argv, opts):wait()
  end
  M.encode = rex.json.encode
  M.decode = rex.json.decode
  M.log = rex.log

  function M.args()
    return rex.args or {}
  end

  return M
end

---------------------------------------------------------------------------
-- LuaJIT on its own

local json = require("rex_reviewer.json")
M.encode = json.encode
M.decode = json.decode

function M.log(line)
  io.stderr:write(line, "\n")
  io.stderr:flush()
end

-- Set by the entry point from its command line, as key=value pairs.
M.ARGS = {}

function M.args()
  return M.ARGS
end

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Run argv to the end, with no input, and return what rex.exec does:
-- { ok, code, stdout, stderr }. LuaJIT's popen doesn't report an exit
-- status, so the shell prints it, and the output goes through files.
function M.exec(argv, opts)
  opts = opts or {}
  local out, err = os.tmpname(), os.tmpname()
  local cmd = {}
  if opts.cwd then
    cmd[#cmd + 1] = "cd " .. quote(opts.cwd) .. " &&"
  end
  cmd[#cmd + 1] = "exec"
  local env = {}
  for k, v in pairs(opts.env or {}) do
    env[#env + 1] = k .. "=" .. quote(v)
  end
  if #env > 0 then
    table.sort(env)
    cmd[#cmd + 1] = "env " .. table.concat(env, " ")
  end
  for _, a in ipairs(argv) do
    cmd[#cmd + 1] = quote(a)
  end
  local line = string.format("( %s ) </dev/null >%s 2>%s; echo $?", table.concat(cmd, " "), quote(out), quote(err))
  local p = assert(io.popen(line, "r"))
  local status = p:read("*a")
  p:close()
  local res = { stdout = slurp(out), stderr = slurp(err) }
  os.remove(out)
  os.remove(err)
  res.code = tonumber(status:match("%d+")) or -1
  res.ok = res.code == 0
  return res
end

return M
