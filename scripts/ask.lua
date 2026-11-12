-- The post terminal: a checked review that waits for you, as a program of
-- its own. On Herdr the watcher opens it beside the round's panes when a
-- round reaches AWAITING_APPROVAL (post = "ask"):
--
--   luajit <rex-reviewer>/scripts/ask.lua item=pr/<owner>/<name>/<pr>/<round>
--
-- It shows the verdict and the findings, and reports blocked (a
-- permission) through OSC 7501, so the phone app lists it under needs you
-- and the Herdr app notifies. Then it takes one key:
--
--   p  post the review       d  dismiss it (press d twice)
--   v  the whole review      r  read it again
--
-- It acts through the same actions as the menu bar and the CLI, by item,
-- so it can only act on the round it shows, while that round waits.

-- This checkout, from where this script is, made absolute: the actions run
-- commands from the home folder.
local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
if SRC:sub(1, 1) ~= "/" then
  SRC = (os.getenv("PWD") or ".") .. "/" .. SRC
end
local ROOT = SRC:match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local status = require("rex_reviewer.status")
local actions = require("rex_reviewer.actions")

local item
for i = 1, select("#", ...) do
  item = (select(i, ...)):match("^item=(.+)$") or item
end
if not item then
  io.stderr:write("usage: ask.lua item=pr/<owner>/<name>/<pr>/<round>\n")
  os.exit(1)
end
local repo, pr, round = status.resolve(item, config.load().repo_list)

local ESC = "\27["
local BOLD, DIM, RED, GREEN, YELLOW, RESET = ESC .. "1m", ESC .. "2m", ESC .. "31m", ESC .. "32m", ESC .. "33m", ESC .. "0m"
local WIDTH = 78

local function out(...)
  io.write(...)
  io.flush()
end

local function report(state, kind, title, msg)
  out(status.report({ id = "", app = config.APP, state = state, kind = kind, title = title, msg = msg }))
end

-- Text wrapped to width, each line after the first indented.
local function wrap(s, width, indent)
  local lines, line = {}, ""
  for word in tostring(s or ""):gsub("%s+", " "):gmatch("%S+") do
    if line ~= "" and #line + 1 + #word > width then
      lines[#lines + 1] = line
      line = indent .. word
    else
      line = line == "" and word or (line .. " " .. word)
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

-- One key: in raw mode on a terminal, else a line.
local tty = os.execute("test -t 0") == 0
local function key()
  if tty then
    os.execute("stty -icanon -echo min 1 </dev/tty")
    local ch = io.read(1)
    os.execute("stty icanon echo </dev/tty")
    return ch
  end
  local line = io.read("*l")
  return line and line:sub(1, 1)
end

local function entry()
  return ledger.load(repo, pr)
end

local function waiting(e)
  return e and e.state == "reviewing" and e.round == round and e.phase == "awaiting"
end

local function draft(e)
  return util.decode(util.read_file(string.format("%s/.tmp/rounds/%d/review.verified.json", e.worktree or "", round)) or "")
end

local VERB = { APPROVE = "Approve", REQUEST_CHANGES = "Request changes", COMMENT = "Comment" }

local function summary(d)
  local s = { event = d.event, blocking = 0, non_blocking = 0, verdict = d.verdict }
  for _, f in ipairs(type(d.findings) == "table" and d.findings or {}) do
    if f.severity == "blocking" then
      s.blocking = s.blocking + 1
    else
      s.non_blocking = s.non_blocking + 1
    end
  end
  return s
end

local function render(e, d)
  local _, name = util.split_slug(repo)
  local s = summary(d)
  out(ESC .. "2J" .. ESC .. "H")
  out(DIM, string.format("%s · %s#%d · round %d · head %s", config.APP, repo, pr, round, util.short(e.round_head)), RESET, "\n")
  if e.title then
    out(BOLD, wrap(e.title, WIDTH, ""), RESET, "\n")
  end
  out("\n")
  local counts = {}
  if s.blocking > 0 then
    counts[#counts + 1] = RED .. s.blocking .. " blocking" .. RESET
  end
  if s.non_blocking > 0 then
    counts[#counts + 1] = s.non_blocking .. " non-blocking"
  end
  out(BOLD, YELLOW, VERB[s.event] or tostring(s.event or "?"), RESET)
  if #counts > 0 then
    out(" · ", table.concat(counts, " · "))
  end
  out("\n\n", wrap(s.verdict or "", WIDTH, ""), "\n\n")
  for _, f in ipairs(type(d.findings) == "table" and d.findings or {}) do
    local tag = f.severity == "blocking" and (RED .. "blocking" .. RESET) or (DIM .. "note    " .. RESET)
    local where = f.path and (f.path .. (f.line and (":" .. f.line) or "")) or ""
    out(" ", tag, "  ", where ~= "" and (BOLD .. where .. RESET .. "\n           ") or "",
      wrap(f.title or f.bullet or f.plus_one_label or "", WIDTH - 11, "           "), "\n")
  end
  local by = {}
  for _, r in ipairs(e.round_reviewers or {}) do
    by[#by + 1] = r
  end
  out("\n", DIM, #by > 0 and ("reviewed by " .. table.concat(by, ", ") .. " · ") or "", "checked by ", e.checker_agent or config.load().checker, RESET, "\n\n")
  out(GREEN, "[p]", RESET, " post   ", GREEN, "[v]", RESET, " whole review   ", GREEN, "[d]", RESET, " dismiss   ", GREEN, "[r]", RESET, " read again\n> ")
  report("blocked", "permission", string.format("%s#%d %s", name or repo, pr, e.title or ""), status.ready_msg(s))
end

local function run(action)
  return pcall(actions.by_name[action].run, { item = item })
end

-- Leave with a last word on screen and in the status, for a moment.
local function finish(state, msg)
  report(state, nil, nil, msg)
  out("\n", msg, "\n")
  util.run({ "sleep", "3" }, { check = false })
  os.exit(0)
end

while true do
  local e = entry()
  if not waiting(e) then
    finish("done", string.format("%s#%d round %d isn't waiting for you any more", repo, pr, round))
  end
  local d = draft(e)
  if type(d) ~= "table" then
    finish("error", "the checked review (review.verified.json) can't be read")
  end
  render(e, d)
  local k = key()
  if k == nil then
    os.exit(0)
  elseif k == "p" then
    out("p\nPosting…\n")
    report("working", nil, nil, "Posting the review")
    local ok, res = run("reviewer_post")
    if ok then
      finish("done", "Posted: " .. tostring(res.url or res.state or "done"))
    end
    out(RED, "Not posted: ", tostring(res), RESET, "\nPress a key.")
    key()
  elseif k == "d" then
    out("d\nDismiss it without posting? Press d again, or any other key to go back. ")
    if key() == "d" then
      local ok, res = run("reviewer_dismiss")
      if ok then
        finish("done", "Dismissed; nothing was posted")
      end
      out(RED, "Not dismissed: ", tostring(res), RESET, "\nPress a key.")
      key()
    end
  elseif k == "v" then
    local ok, res = run("reviewer_preview")
    out(ESC .. "2J" .. ESC .. "H", ok and (res.preview or "") or (RED .. tostring(res) .. RESET), "\n\nPress a key to go back. ")
    key()
  end
end
