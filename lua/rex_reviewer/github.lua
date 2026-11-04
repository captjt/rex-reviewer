-- GitHub, through gh: one GraphQL query per check, and the context each
-- round needs, fetched up front so reviewers never call GitHub themselves.

local util = require("rex_reviewer.util")
local config = require("rex_reviewer.config")

local M = {}

local SEARCH_FIELDS = [[
number title url isDraft headRefOid author { login } repository { nameWithOwner }
timelineItems(last: 20, itemTypes: [REVIEW_REQUESTED_EVENT]) {
  nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } } }
}]]

-- tracked: { [slug] = { pr numbers still open in the ledger } }. Returns the
-- query data and the signed-in login.
function M.query(tracked)
  local c = config.load()
  local parts = {
    "viewer { login }",
    "search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest { " .. SEARCH_FIELDS .. " } } }",
  }
  local q = { "is:pr is:open draft:false user-review-requested:@me" }
  for i, r in ipairs(c.repo_list) do
    q[#q + 1] = "repo:" .. r.slug
    local nums = tracked[r.slug] or {}
    if #nums > 0 then
      local prs = {}
      for _, n in ipairs(nums) do
        prs[#prs + 1] = string.format(
          "p%d: pullRequest(number: %d) { number title url state isDraft headRefOid author { login } }", n, n)
      end
      parts[#parts + 1] = string.format('r%d: repository(owner: "%s", name: "%s") { %s }', i, r.owner, r.name, table.concat(prs, " "))
    end
  end
  local query = "query($q: String!) { " .. table.concat(parts, " ") .. " }"
  local res = util.run({ "gh", "api", "graphql", "-f", "q=" .. table.concat(q, " "), "-f", "query=" .. query })
  local data = util.decode(res.stdout)
  data = data and data.data
  if not data or not data.viewer or not data.viewer.login then
    error("gh returned no signed-in user; run gh auth login", 0)
  end
  return data, data.viewer.login
end

-- One observation per PR, by repo: { repo, pr, title, url, author, state,
-- draft, head, requested, requested_at }.
function M.observe(data, tracked, login)
  local c = config.load()
  local obs = {}
  for i, r in ipairs(c.repo_list) do
    obs[r.slug] = {}
    local repo = data["r" .. i]
    for _, n in ipairs(tracked[r.slug] or {}) do
      local p = repo and repo["p" .. n]
      if p then
        obs[r.slug][n] = {
          repo = r.slug,
          pr = n,
          title = p.title,
          url = p.url,
          author = p.author and p.author.login,
          state = p.state,
          draft = p.isDraft,
          head = p.headRefOid,
          requested = false,
        }
      end
    end
  end
  for _, p in ipairs((data.search and data.search.nodes) or {}) do
    local slug = p.repository and p.repository.nameWithOwner
    if p.number and slug and obs[slug] then
      local o = obs[slug][p.number] or { repo = slug, pr = p.number, state = "OPEN" }
      o.title, o.url, o.draft, o.head = p.title, p.url, p.isDraft, p.headRefOid
      o.author = p.author and p.author.login
      o.requested = true
      for _, ev in ipairs((p.timelineItems and p.timelineItems.nodes) or {}) do
        local who = ev.requestedReviewer and ev.requestedReviewer.login
        if who == login and (o.requested_at == nil or ev.createdAt > o.requested_at) then
          o.requested_at = ev.createdAt
        end
      end
      -- hooks.should_review can pass on a PR, such as one from a bot.
      if c.hooks.should_review and c.hooks.should_review(o) == false then
        o.requested = false
      end
      obs[slug][p.number] = o
    end
  end
  return obs
end

function M.pr(repo, pr)
  local res = util.run({ "gh", "pr", "view", tostring(pr), "-R", repo, "--json", "number,title,url,state,headRefOid,baseRefName,author" })
  return util.decode(res.stdout)
end

function M.live_head(repo, pr)
  return util.trim(util.run({ "gh", "pr", "view", tostring(pr), "-R", repo, "--json", "headRefOid", "--jq", ".headRefOid" }).stdout)
end

function M.login()
  return util.trim(util.run({ "gh", "api", "user", "--jq", ".login" }).stdout)
end

local THREADS_QUERY = [[
query($o: String!, $n: String!, $pr: Int!) {
  repository(owner: $o, name: $n) { pullRequest(number: $pr) {
    reviewThreads(first: 100) { nodes {
      id isResolved isOutdated path line originalLine
      comments(first: 50) { nodes { databaseId author { login } body createdAt url } }
    } }
  } }
}]]

local function gh_to(path, argv)
  local res = util.run(argv, { check = false })
  util.write_file(path, res.stdout or "")
  return res
end

-- Fetch what a round reads into ctx: the PR, its diff, reviews, comments,
-- threads, and checks.
function M.fetch_context(repo, pr, ctx)
  local owner, name = util.split_slug(repo)
  local n = tostring(pr)
  gh_to(ctx .. "/pr.json", {
    "gh", "pr", "view", n, "-R", repo, "--json",
    "number,title,body,author,url,baseRefName,headRefName,headRefOid,isDraft,labels,files,commits",
  })
  gh_to(ctx .. "/pr.diff", { "gh", "pr", "diff", n, "-R", repo })
  gh_to(ctx .. "/reviews.json", { "gh", "api", "--paginate", string.format("repos/%s/pulls/%d/reviews", repo, pr) })
  gh_to(ctx .. "/review-comments.json", { "gh", "api", "--paginate", string.format("repos/%s/pulls/%d/comments", repo, pr) })
  gh_to(ctx .. "/issue-comments.json", { "gh", "api", "--paginate", string.format("repos/%s/issues/%d/comments", repo, pr) })
  gh_to(ctx .. "/threads.json", { "gh", "api", "graphql", "-F", "pr=" .. n, "-f", "o=" .. owner, "-f", "n=" .. name, "-f", "query=" .. THREADS_QUERY })
  gh_to(ctx .. "/ci.json", { "gh", "pr", "checks", n, "-R", repo, "--json", "name,state,bucket,link,workflow" })
  return util.decode(util.read_file(ctx .. "/pr.json")) or {}
end

return M
