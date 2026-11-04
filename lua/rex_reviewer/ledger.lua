-- The ledger: plain files under ~/.local/state/rex-reviewer that the watcher,
-- the actions, and the menu bar app all read. docs/ledger.md is the contract.
--
--   state.json                         switches and the last check
--   watcher.json                       the watcher's last step
--   events.jsonl                       every event, one JSON object a line
--   check-now                          left by a client: check GitHub now
--   repos/<owner>/<name>/pr-<n>.json   one entry per PR

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")

local M = {}

M.SCHEMA = 1

-- Entry states. Only "posted" waits on GitHub; "queued" and "reviewing"
-- wait on the watcher.
M.FINISHED = { merged = true, closed = true, cleaned = true }
M.TERMINAL = { cleaned = true }

local function dir()
  return config.STATE_DIR
end

function M.check_now_path()
  return dir() .. "/check-now"
end

function M.entry_path(repo, pr)
  return string.format("%s/repos/%s/pr-%d.json", dir(), repo, pr)
end

function M.load(repo, pr)
  return util.decode(util.read_file(M.entry_path(repo, pr)))
end

function M.save(e)
  util.mkdirp(dir() .. "/repos/" .. e.repo)
  e.updated_at = util.now()
  util.write_file(M.entry_path(e.repo, e.pr), util.json(e) .. "\n")
end

-- Every entry of the configured repos, by repo, then PR.
function M.list()
  local out = {}
  for _, r in ipairs(config.load().repo_list) do
    local res = util.run({ "find", dir() .. "/repos/" .. r.slug, "-maxdepth", "1", "-name", "pr-*.json" }, { check = false })
    local found = {}
    for path in (res.stdout or ""):gmatch("[^\n]+") do
      local n = tonumber(path:match("pr%-(%d+)%.json$"))
      local e = n and M.load(r.slug, n)
      if e then
        found[#found + 1] = e
      end
    end
    table.sort(found, function(a, b)
      return a.pr < b.pr
    end)
    util.append(out, found)
  end
  return out
end

-- "name#602", for logs and messages.
function M.label(e)
  local _, name = util.split_slug(e.repo)
  return string.format("%s#%d", name or e.repo, e.pr)
end

function M.load_state()
  return util.decode(util.read_file(dir() .. "/state.json")) or { seq = 0 }
end

function M.save_state(st)
  util.mkdirp(dir())
  st.schema = M.SCHEMA
  util.write_file(dir() .. "/state.json", util.json(st) .. "\n")
end

function M.update_state(fn)
  local st = M.load_state()
  fn(st)
  M.save_state(st)
  return st
end

function M.append_event(ev)
  util.mkdirp(dir())
  local st = M.load_state()
  st.seq = (st.seq or 0) + 1
  ev.seq = st.seq
  ev.at = ev.at or util.now()
  util.append_file(dir() .. "/events.jsonl", util.json(ev) .. "\n")
  M.save_state(st)
  return ev
end

function M.events_since(seq)
  local out = {}
  for line in (util.read_file(dir() .. "/events.jsonl") or ""):gmatch("[^\n]+") do
    local ev = util.decode(line)
    if ev and (ev.seq or 0) > (seq or 0) then
      out[#out + 1] = ev
    end
  end
  return out
end

-- What the watcher saw at its last step: when, what needs you (a list of
-- { repo, pr, kind, text }), and any failure.
function M.save_watcher(info)
  util.mkdirp(dir())
  info.at = util.now()
  info.schema = M.SCHEMA
  util.write_file(dir() .. "/watcher.json", util.json(info) .. "\n")
end

function M.paused()
  return M.load_state().paused == true
end

function M.set_paused(v)
  M.update_state(function(st)
    st.paused = v or nil
  end)
  M.append_event({ kind = v and "paused" or "resumed" })
  return { paused = v }
end

function M.format_event(ev)
  local t = ((ev.at or ""):match("T(%d%d:%d%d:%d%d)") or "") .. "Z"
  local who = ev.pr and string.format("%s#%d", select(2, util.split_slug(ev.repo or "")) or "", ev.pr) or ""
  local bits = { t, string.format("%-18s", who), string.format("%-13s", ev.kind) }
  if ev.round then
    bits[#bits + 1] = "round " .. ev.round
  end
  if ev.head then
    bits[#bits + 1] = "head " .. util.short(ev.head)
  end
  if ev.note then
    bits[#bits + 1] = "(" .. ev.note .. ")"
  end
  return table.concat(bits, "  ")
end

return M
