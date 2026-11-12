-- Commands, files, and time: the small helpers the other modules share.

local runtime = require("rex_reviewer.runtime")

local M = {}

local HOME = os.getenv("HOME")
local USER = os.getenv("USER") or ""
M.HOME = HOME

-- Rex runs actions with only the system directories on PATH, so every
-- command gets this PATH. The config's `path` list goes in front.
local base_path = {
  HOME .. "/.local/bin",
  HOME .. "/.bin",
  HOME .. "/bin",
  "/opt/homebrew/bin",
  "/opt/homebrew/sbin",
  HOME .. "/.nix-profile/bin",
  "/etc/profiles/per-user/" .. USER .. "/bin",
  "/run/current-system/sw/bin",
  HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS",
  "/usr/local/bin",
  "/usr/bin",
  "/bin",
  "/usr/sbin",
  "/sbin",
}
M.PATH = table.concat(base_path, ":")

function M.set_extra_path(dirs)
  local all = {}
  for _, d in ipairs(dirs or {}) do
    all[#all + 1] = M.expand(d)
  end
  for _, d in ipairs(base_path) do
    all[#all + 1] = d
  end
  M.PATH = table.concat(all, ":")
end

-- Run argv to the end. Errors unless opts.check is false.
function M.run(argv, opts)
  opts = opts or {}
  local env = { PATH = M.PATH }
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  local res = runtime.exec(argv, { cwd = opts.cwd or HOME, env = env })
  if opts.check ~= false and not res.ok then
    local err = (res.stderr ~= "" and res.stderr) or res.stdout or ""
    error(string.format("%s exited %s: %s", table.concat(argv, " "):sub(1, 120), tostring(res.code), err:sub(1, 600)), 0)
  end
  return res
end

function M.trim(s)
  return ((s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.expand(path)
  if type(path) ~= "string" then
    return path
  end
  return (path:gsub("^~/", HOME .. "/"):gsub("^~$", HOME))
end

function M.exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

function M.mkdirp(path)
  M.run({ "mkdir", "-p", path })
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- Written whole, then renamed, so a reader never sees half a file.
function M.write_file(path, s)
  local tmp = path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(s)
  f:close()
  assert(os.rename(tmp, path))
end

function M.append_file(path, s)
  local f = assert(io.open(path, "a"))
  f:write(s)
  f:close()
end

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.short(sha)
  return sha and sha:sub(1, 7) or "?"
end

function M.split_slug(slug)
  return slug:match("^([^/]+)/([^/]+)$")
end

-- Fill {{NAME}} placeholders. Unknown names stay as they are.
function M.render(template, vars)
  return (template:gsub("{{([%w_]+)}}", function(k)
    local v = vars[k]
    return v ~= nil and tostring(v) or "{{" .. k .. "}}"
  end))
end

function M.append(list, items)
  for _, v in ipairs(items or {}) do
    list[#list + 1] = v
  end
  return list
end

-- Lua writes an empty table as {}. Readers of the ledger accept both.
function M.json(v)
  return runtime.encode(v)
end

function M.decode(s)
  local ok, v = pcall(runtime.decode, s or "")
  return ok and v or nil
end

return M
