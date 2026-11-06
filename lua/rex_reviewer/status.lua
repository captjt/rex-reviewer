-- The watcher's program status (OSC 7501): the record its pane reports, and
-- one child record for each PR that needs you. Rex shows them on the
-- watcher's tab. Any tool that follows program status, such as rex-inbox,
-- gets each PR as an item of its own and can act on it through the actions.
--
--   (root)                      the watcher: idle, or error when a check or a step failed
--   pr/<owner>/<name>/<n>/<r>   round r of PR n: what watcher.json's attention says
--
-- A child record's id names the PR and the round. The actions take it as
-- item=, so a client acts on exactly the round it showed:
--
--   rex do reviewer_post item=pr/acme/api/12/2
--
-- This module only builds strings, so it runs anywhere Lua does.

local M = {}

M.APP = "rex-reviewer"

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.b64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local function at(shift)
      local k = math.floor(n / shift) % 64 + 1
      return B64:sub(k, k)
    end
    out[#out + 1] = at(262144) .. at(4096) .. (b and at(64) or "=") .. (c and at(1) or "=")
  end
  return table.concat(out)
end

-- One line of text, without control characters (the protocol refuses
-- them), cut to at most max bytes without splitting a UTF-8 character.
function M.line(s, max)
  s = tostring(s or ""):gsub("[%c]+", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s <= max then
    return s
  end
  local cut = max - 3
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return s:sub(1, cut) .. "..."
end

-- An id segment: the protocol allows [A-Za-z0-9_.+-], 1 to 32 of them.
local function segment(s)
  s = tostring(s or ""):gsub("[^%w_.+-]", "-"):sub(1, 32)
  return s ~= "" and s or "-"
end

function M.item_id(repo, pr, round)
  local owner, name = tostring(repo):match("^([^/]+)/(.+)$")
  return string.format("pr/%s/%s/%d/%d", segment(owner or repo), segment(name or repo), pr, round or 0)
end

-- The repo, PR and round an item id names, from the configured repos
-- (each { slug = "owner/name" }). Errors when it names none of them.
function M.resolve(item, repos)
  local owner, name, pr, round = tostring(item or ""):match("^pr/([^/]+)/([^/]+)/(%d+)/(%d+)$")
  if not owner then
    error(string.format("%s isn't a rex-reviewer item; items look like pr/<owner>/<name>/<pr>/<round>", tostring(item)), 0)
  end
  pr, round = tonumber(pr), tonumber(round)
  local found
  for _, r in ipairs(repos or {}) do
    if M.item_id(r.slug, pr, round) == item then
      if found then
        error(string.format("%s matches more than one repo; pass pr= and repo= instead", item), 0)
      end
      found = r.slug
    end
  end
  if not found then
    error(string.format("%s names no configured repo", item), 0)
  end
  return found, pr, round
end

local VERB = {
  APPROVE = "Approve",
  REQUEST_CHANGES = "Request changes",
  COMMENT = "Comment",
}

-- What a checked review waiting to post says, in one line.
function M.ready_msg(draft)
  if type(draft) ~= "table" then
    return "The checked review is ready to post"
  end
  local bits = {}
  local counts = {}
  if (draft.blocking or 0) > 0 then
    counts[#counts + 1] = string.format("%d blocking", draft.blocking)
  end
  if (draft.non_blocking or 0) > 0 then
    counts[#counts + 1] = string.format("%d non-blocking", draft.non_blocking)
  end
  local head = "Ready to post: " .. (VERB[draft.event] or "the checked review")
  if #counts > 0 then
    head = head .. " (" .. table.concat(counts, ", ") .. ")"
  end
  bits[#bits + 1] = head
  if type(draft.verdict) == "string" and draft.verdict ~= "" then
    bits[#bits + 1] = draft.verdict
  end
  return table.concat(bits, ". ")
end

-- The record for one attention item: { repo, pr, round, kind, text,
-- title?, draft? }. ready is a permission (post it, or dismiss it), an
-- agent's BLOCKED or a closed pane needs you without a kind, and a start
-- that failed or a step's error is an error.
function M.record(a)
  local name = tostring(a.repo):match("/(.+)$") or tostring(a.repo)
  local label = string.format("%s#%d", name, a.pr)
  local title = (type(a.title) == "string" and a.title ~= "") and (label .. " " .. a.title) or label
  local r = { id = M.item_id(a.repo, a.pr, a.round), app = M.APP, title = M.line(title, 190) }
  if a.kind == "ready" then
    r.state, r.kind, r.msg = "blocked", "permission", M.ready_msg(a.draft)
  elseif a.kind == "blocked" or a.kind == "pane-closed" then
    r.state, r.msg = "blocked", a.text
  else
    r.state, r.msg = "error", a.text
  end
  r.msg = M.line(r.msg, 600)
  return r
end

-- The root record: idle while the watcher runs, error when a GitHub check
-- or a step failed. health = { error = text?, paused = bool? }.
function M.root(health)
  health = health or {}
  if health.error then
    return { id = "", app = M.APP, state = "error", msg = M.line(health.error, 300) }
  end
  return { id = "", app = M.APP, state = "idle", msg = health.paused and "Paused" or nil }
end

-- The OSC 7501 report for a record.
function M.report(r)
  local fields = { "state=" .. r.state }
  if r.id and r.id ~= "" then
    fields[#fields + 1] = "id=" .. r.id
  end
  if r.kind then
    fields[#fields + 1] = "kind=" .. r.kind
  end
  if r.app then
    fields[#fields + 1] = "app=" .. r.app
  end
  if r.title and r.title ~= "" then
    fields[#fields + 1] = "title=" .. M.b64(r.title)
  end
  if r.msg and r.msg ~= "" then
    fields[#fields + 1] = "msg=" .. M.b64(r.msg)
  end
  return "\27]7501;" .. table.concat(fields, ":") .. "\27\\"
end

-- Clear every record on the pane, for a watcher that just started.
M.CLEAR_ALL = "\27]7501;state=clear\27\\"

-- The reports that take the pane from what shown says it last reported to
-- the root and the items given. shown maps id to report and is updated.
-- Items that left are cleared; unchanged ones aren't sent again.
function M.sync(shown, root, items)
  local out, want = {}, {}
  local records = { root }
  for _, a in ipairs(items or {}) do
    records[#records + 1] = M.record(a)
  end
  for _, r in ipairs(records) do
    local id = r.id or ""
    if not want[id] then
      local s = M.report(r)
      want[id] = s
      if shown[id] ~= s then
        out[#out + 1] = s
      end
    end
  end
  local gone = {}
  for id in pairs(shown) do
    if not want[id] then
      gone[#gone + 1] = id
    end
  end
  table.sort(gone)
  for _, id in ipairs(gone) do
    out[#out + 1] = "\27]7501;state=clear:id=" .. id .. "\27\\"
    shown[id] = nil
  end
  for id, s in pairs(want) do
    shown[id] = s
  end
  return out
end

return M
