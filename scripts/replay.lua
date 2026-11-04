-- Replay a PR's real GitHub history through the rules and show what the
-- watcher would have done. Changes nothing.
--
--   rex do <rex-reviewer>/scripts/replay.lua pr=592 [repo=owner/name]
--
-- A review you posted while no round was running counts as your own review.
-- When the rules start a round, the replay assumes it starts at once and that
-- your next review is that round's post.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/scripts/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path
local config = require("rex_reviewer.config")
config.set_root(ROOT)
local util = require("rex_reviewer.util")
local ledger = require("rex_reviewer.ledger")
local rules = require("rex_reviewer.rules")
local github = require("rex_reviewer.github")

local pr = tonumber(rex.args.pr)
if not pr then
  error("usage: rex do replay.lua pr=<number> [repo=owner/name]", 0)
end
local repo = config.repo(rex.args.repo, pr, ledger).slug
local owner, name = util.split_slug(repo)
local query = [[
query($o: String!, $n: String!, $pr: Int!) {
  repository(owner: $o, name: $n) { pullRequest(number: $pr) { title author { login }
    timelineItems(first: 250, itemTypes: [PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, REVIEW_REQUESTED_EVENT,
      REVIEW_REQUEST_REMOVED_EVENT, PULL_REQUEST_REVIEW, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT]) {
      nodes {
        __typename
        ... on PullRequestCommit { commit { oid committedDate } }
        ... on HeadRefForcePushedEvent { createdAt afterCommit { oid } }
        ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
        ... on ReviewRequestRemovedEvent { createdAt requestedReviewer { ... on User { login } } }
        ... on PullRequestReview { databaseId submittedAt state author { login } commit { oid } }
        ... on MergedEvent { createdAt }
        ... on ClosedEvent { createdAt }
        ... on ReopenedEvent { createdAt }
      }
    }
  } }
}]]
local res = util.run({ "gh", "api", "graphql", "-F", "pr=" .. pr, "-f", "o=" .. owner, "-f", "n=" .. name, "-f", "query=" .. query })
local p = rex.json.decode(res.stdout).data.repository.pullRequest

local me = github.login()
local gh = { state = "OPEN", requested = false }
local e
local out = {}
local counts = { rounds = 0, noted = 0, yours = 0 }

local function line(t, what, result)
  out[#out + 1] = string.format("%s  %-32s %s", (t or ""):match("T(%d%d:%d%d)") or "     ", what, result or "")
end

for _, it in ipairs(p.timelineItems.nodes) do
  local kind = it.__typename
  local t, what
  local review
  if kind == "PullRequestCommit" then
    t = it.commit.committedDate
    gh.head = it.commit.oid
    what = "push " .. util.short(gh.head)
  elseif kind == "HeadRefForcePushedEvent" then
    t = it.createdAt
    gh.head = it.afterCommit and it.afterCommit.oid or gh.head
    what = "force-push " .. util.short(gh.head)
  elseif kind == "ReviewRequestedEvent" then
    t = it.createdAt
    local r = it.requestedReviewer or {}
    if r.login == me then
      gh.requested = true
      gh.requested_at = t
      what = "requested you"
    else
      what = "requested " .. (r.login or ("team " .. tostring(r.slug)))
    end
  elseif kind == "ReviewRequestRemovedEvent" then
    t = it.createdAt
    if it.requestedReviewer and it.requestedReviewer.login == me then
      gh.requested = false
    end
    what = "request removed"
  elseif kind == "PullRequestReview" then
    t = it.submittedAt
    if it.author and it.author.login == me then
      gh.requested = false
      review = it
      what = "you: " .. it.state
    else
      what = (it.author and it.author.login or "?") .. ": " .. it.state
    end
  elseif kind == "MergedEvent" then
    t, gh.state, what = it.createdAt, "MERGED", "merged"
  elseif kind == "ClosedEvent" then
    t, what = it.createdAt, "closed"
    if gh.state ~= "MERGED" then
      gh.state = "CLOSED"
    end
  elseif kind == "ReopenedEvent" then
    t, gh.state, what = it.createdAt, "OPEN", "reopened"
  end

  if review then
    local head = review.commit and review.commit.oid or gh.head
    local fields = { head = head, verdict = review.state, review_id = review.databaseId }
    if e and e.state == "reviewing" then
      fields.by = "agents"
      rules.mark_posted(e, fields, t)
      line(t, what, string.format("round %d posted by the agents", e.round))
    else
      e = e or { repo = repo, pr = pr, round = 0, history = {}, created_at = t }
      e.trigger = "you"
      rules.mark_started(e, head, t)
      fields.by = "you"
      rules.mark_posted(e, fields, t)
      counts.yours = counts.yours + 1
      line(t, what, string.format("round %d: your own review, recorded", e.round))
    end
  elseif what then
    local o = { repo = repo, pr = pr, state = gh.state, head = gh.head, requested = gh.requested, requested_at = gh.requested_at }
    local evs
    e, evs = rules.decide(e, o, t)
    local result = {}
    for _, ev in ipairs(evs) do
      if ev.kind == "new-head" then
        counts.noted = counts.noted + 1
        result[#result + 1] = "noted, waiting for a re-request"
      elseif ev.kind == "requested" or ev.kind == "re-requested" or ev.kind == "pickup" then
        counts.rounds = counts.rounds + 1
        result[#result + 1] = string.format("%s → start round %d", ev.kind, ev.round)
      else
        result[#result + 1] = ev.kind
      end
    end
    if e and e.state == "queued" then
      rules.mark_started(e, gh.head, t)
    end
    line(t, what, table.concat(result, "; "))
  end
end

out[#out + 1] = ""
out[#out + 1] = string.format(
  "%s#%d by %s: the watcher would start %d round(s); %d push(es) noted without a round; %d review(s) were yours.",
  repo,
  pr,
  p.author and p.author.login or "?",
  counts.rounds,
  counts.noted,
  counts.yours
)
print(table.concat(out, "\n"))
