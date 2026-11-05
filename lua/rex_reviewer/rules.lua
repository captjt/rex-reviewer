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

M.TOKEN_FIELDS = { "input", "cache_read", "cache_write", "output", "total" }

-- bin/token-usage's counts, summed across agents.
function M.flat_tokens(t)
  local out = {}
  for _, k in ipairs(M.TOKEN_FIELDS) do
    out[k] = 0
    for _, agent in pairs(t) do
      if type(agent) == "table" then
        out[k] = out[k] + (agent[k] or 0)
      end
    end
  end
  return out
end

-- Add one bin/token-usage result t into sum, agent by agent, as when a PR's
-- agents ran in several worktrees. Returns sum.
function M.add_tokens(sum, t)
  for agent, counts in pairs(t or {}) do
    if type(counts) == "table" then
      local into = sum[agent] or {}
      for _, k in ipairs(M.TOKEN_FIELDS) do
        into[k] = (into[k] or 0) + (counts[k] or 0)
      end
      sum[agent] = into
    end
  end
  sum.total = (sum.total or 0) + ((t or {}).total or 0)
  return sum
end

-- What after adds to before, count by count, as flat_tokens gives them.
function M.token_delta(before, after)
  local out = {}
  for _, k in ipairs(M.TOKEN_FIELDS) do
    out[k] = math.max(0, after[k] - before[k])
  end
  return out
end

-- A round ended: a review was posted on head, or you dismissed it. by is
-- "agents" for this tool's rounds and "you" for your own review. The history
-- record is what the recap reads, so it keeps the round's timing, findings,
-- and merge risk after the worktree is gone.
function M.mark_posted(e, fields, now)
  -- fields.tokens is what the agents have spent on the PR so far, and the
  -- round's share is what it added since the last round. With no earlier
  -- count, that's only known for round 1.
  local before = e.tokens and M.flat_tokens(e.tokens) or (e.round == 1 and M.flat_tokens({}) or nil)
  local round_tokens = fields.tokens and before and M.token_delta(before, M.flat_tokens(fields.tokens)) or nil
  e.tokens = fields.tokens or e.tokens
  e.state = "posted"
  e.reviewed_head = fields.head or e.round_head
  e.head = e.head or e.reviewed_head
  e.posted_at = now
  e.verdict = fields.verdict
  e.review_id = fields.review_id
  e.review_url = fields.url
  e.implementation = fields.implementation or e.implementation
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
    tokens = round_tokens,
    reviewers = fields.reviewers,
  }
  return e
end

return M
