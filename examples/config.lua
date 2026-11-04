-- ~/.config/rex-reviewer/config.lua
--
-- rex-reviewer reviews the PRs that request you by name in these repos. The
-- reviewer drafts each review, the checker verifies it, and with post = "ask"
-- nothing posts until you approve it.

return {
  repos = {
    ["your-org/your-repo"] = {
      -- A clone whose origin is the repo. Worktrees for each PR hang off it.
      checkout = "~/src/your-repo",
      -- Anything the agents should know about this repo that its own docs
      -- (README, CONTRIBUTING, AGENTS.md, CLAUDE.md) don't say.
      notes = [[
- Run `make test` for unit tests; the e2e suite needs Docker, so skip it.
]],
      -- Guides for this repo only, slot by slot. See guides below.
      -- guides = { review = "~/.agents/skills/my-review/SKILL.md" },
    },
  },

  -- Who reviews: "codex" or "claude". The checker is Claude Code.
  reviewer = "codex",
  checker = "claude",

  -- "ask": the checked review waits for you to post or dismiss it.
  -- "auto": the checker posts it, with a footer naming both agents.
  post = "ask",

  -- Rounds running at once, and how often to check GitHub.
  max_rounds = 3,
  poll_seconds = 180,

  -- Guides point the agents at your own skills or instructions. Each is a
  -- path to a file, a string of instructions, a function(pr) returning
  -- either, "bundled" for the default in guides/, or false for none.
  guides = {
    -- How the reviewer looks for problems. false: the built-in method.
    review = false,
    -- review = "Run the $review-swarm skill on the diff.",
    -- How the posted review reads.
    style = "bundled",
    -- The merge-risk rubric. false: no merge-risk assessment.
    merge_risk = "bundled",
    -- Extra instructions for the checker.
    check = false,
  },

  -- Extra folders for PATH, such as where codex or claude live.
  path = {},

  -- Extra caches the agents may write to (common ones are already on).
  extra_caches = {},

  -- Agent arguments. args replaces an agent's defaults; extra_args adds to them.
  agents = {
    codex = {
      -- Turn off MCP servers the reviewer shouldn't use:
      -- extra_args = { "-c", "mcp_servers.linear.enabled=false" },
    },
    claude = {},
  },

  hooks = {
    -- Return false to pass on a PR, such as one from a bot.
    -- should_review = function(pr) return not pr.author:match("%[bot%]$") end,
  },
}
