-- ~/.config/rex-reviewer/config.lua
--
-- rex-reviewer reviews the PRs that request you by name in these repos. Each
-- reviewer drafts a review, the checker merges and verifies them, and with
-- post = "ask" nothing posts until you approve it.

return {
  -- Where the panes run: "rex", or "herdr" for herdr-core with the Herdr app
  -- and phone app. On Herdr, the actions run under LuaJIT instead of Rex.
  -- See docs/hosts.md, which also says how to switch.
  host = "rex",
  -- The Rex session the watcher and the review tabs open in, or on Herdr the
  -- space (lowercase letters, digits, dots, dashes; up to 24).
  -- session = "rex-reviewer",

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

  -- Who reviews and who checks: "codex" or "claude" for each, in any mix.
  reviewer = "codex",
  checker = "claude",
  -- Or the checker's table form, with its own args (after
  -- agents.<agent>.extra_args) and effort (over effort.check):
  -- checker = { agent = "codex", extra_args = { "-c", 'model="gpt-6.1-sol"' }, effort = "high" },

  -- Or several reviewers side by side, each in its own worktree and pane,
  -- blind to the others; the checker merges their drafts. The first is the
  -- primary. Use reviewers or reviewer, not both. Up to four.
  -- reviewers = {
  --   { name = "codex", agent = "codex" },
  --   { name = "claude", agent = "claude",
  --     -- For this reviewer only: more agent arguments, and its own review guide.
  --     extra_args = { "--model", "claude-opus-5-5" },
  --     guides = { review = "~/.config/rex-reviewer/guides/deep-review.md" } },
  -- },

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

  -- How hard the agents think, round by round: review for the reviewers,
  -- check for the checker. A level (low, medium, high, xhigh, max), a
  -- function(pr) that returns one, or false for the agent's own setting.
  -- It replaces any effort in agents.<agent>.extra_args; a nil return
  -- leaves those. A repo or a reviewer can set its own. The README lists
  -- what pr holds.
  -- effort = {
  --   review = function(pr)
  --     if pr.round > 1 then
  --       if pr.last_merge_risk == "high" then return "xhigh" end
  --       if pr.delta_lines and pr.delta_lines < 100 then return "medium" end
  --     end
  --     if pr.touches({ "migrations/", "auth/", ".github/workflows/" }) then return "xhigh" end
  --     if pr.lines < 150 then return "medium" end
  --     if pr.lines > 1500 then return "xhigh" end
  --     return "high"
  --   end,
  --   check = "high",
  -- },

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
