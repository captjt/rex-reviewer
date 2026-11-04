-- The rules. decide() is pure: it takes a ledger entry (or nil) and one
-- observation of the PR on GitHub, and returns the updated entry and the
-- events it produced. scripts/replay.lua drives it with a PR's real history.
--
--   - Only a review request to you by name starts tracking a PR.
--   - A re-request after the last post starts the next round.
--   - A push with no re-request starts nothing; it's only noted.
--   - Merged or closed PRs are cleaned up.

local M = {}

M.TERMINAL = { cleaned = true }

-- e: the entry or nil. o: { repo, pr, title, url, author, state, head,
-- requested, requested_at }.
function M.decide(e, o, now)
  local evs = {}
  local function emit(kind, fields)
    local ev = { kind = kind, repo = o.repo, pr = o.pr }
    for k, v in pairs(fields or {}) do
      ev[k] = v
    end
    evs[#evs + 1] = ev
  end

  if not e then
    if not o.requested then
      return nil, evs
    end
    e = { repo = o.repo, pr = o.pr, round = 0, state = "queued", trigger = "request", history = {}, created_at = now }
    e.requested_at = o.requested_at or now
    emit("requested", { round = 1, head = o.head, author = o.author, title = o.title })
  end

  e.title = o.title or e.title
  e.url = o.url or e.url
  e.author = o.author or e.author

  if o.state == "MERGED" or o.state == "CLOSED" then
    local s = o.state == "MERGED" and "merged" or "closed"
    if e.state ~= s and not M.TERMINAL[e.state] then
      e.state = s
      -- outcome and ended_at outlast cleanup, which sets state to "cleaned".
      e.outcome = s
      e.ended_at = now
      emit(s, { head = o.head })
    end
  elseif e.state == "posted" then
    -- GitHub drops you from the requested reviewers when you review, so being
    -- on the list again after the last post means a re-request.
    local newer = o.requested_at == nil or e.posted_at == nil or o.requested_at > e.posted_at
    if o.requested and newer then
      e.state = "queued"
      e.trigger = "re-request"
      e.requested_at = o.requested_at or now
      emit("re-requested", { round = e.round + 1, head = o.head, reviewed_head = e.reviewed_head })
    elseif o.head and e.head and o.head ~= e.head then
      emit("new-head", { head = o.head, previous_head = e.head, note = "waiting for a re-request" })
    end
  elseif e.state == "queued" and e.trigger ~= "manual" and not o.requested then
    -- The request was withdrawn before a round started.
    e.state = "unrequested"
    emit("unrequested", { head = o.head })
  elseif e.state == "unrequested" and o.requested then
    e.state = "queued"
    e.requested_at = o.requested_at or now
    emit("requested", { round = e.round + 1, head = o.head })
  elseif e.state == "reviewing" and o.head and e.round_head and o.head ~= e.round_head and o.head ~= e.head then
    emit("head-moved", { round = e.round, head = o.head, round_head = e.round_head })
  end

  e.head = o.head or e.head
  return e, evs
end

-- A round started on head.
function M.mark_started(e, head, now)
  e.round = e.round + 1
  e.state = "reviewing"
  e.round_head = head
  e.started_at = now
  return e
end

-- A round ended: a review was posted on head, or you dismissed it. by is
-- "agents" for this tool's rounds and "you" for your own review. The history
-- record is what the recap reads, so it keeps the round's timing, findings,
-- and merge risk after the worktree is gone.
function M.mark_posted(e, fields, now)
  e.state = "posted"
  e.reviewed_head = fields.head or e.round_head
  e.head = e.head or e.reviewed_head
  e.posted_at = now
  e.verdict = fields.verdict
  e.review_id = fields.review_id
  e.review_url = fields.url
  -- Lua writes an empty history as {}, which reads back as a table either way.
  e.history = type(e.history) == "table" and e.history or {}
  e.history[#e.history + 1] = {
    round = e.round,
    trigger = e.trigger,
    head = e.reviewed_head,
    verdict = fields.verdict,
    review_id = fields.review_id,
    url = fields.url,
    by = fields.by or "agents",
    requested_at = e.requested_at,
    started_at = e.started_at,
    at = now,
    blocking = fields.blocking,
    non_blocking = fields.non_blocking,
    merge_risk = fields.merge_risk,
  }
  return e
end

return M
