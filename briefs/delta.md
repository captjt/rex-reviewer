# Round {{ROUND}} of {{REPO}} PR #{{PR}}, continued: the head moved

You reviewed {{MOVED_FROM}} in this round. The author pushed since then, and
the worktree is now at {{HEAD}}, the PR's current head. The new commits change
the PR's own diff, so they need a review.

- The new commits: `{{CONTEXT}}/delta-head-commits.txt`
- Their diff: `{{CONTEXT}}/delta-head.diff` ({{MOVED_FROM_SHORT}}..{{HEAD_SHORT}}).
  If the author merged `{{BASE}}` along the way, this diff includes its
  changes too. Review only what touches this PR.
- `{{CONTEXT}}/` is refreshed for {{HEAD_SHORT}}, so `pr.diff`, `ci.json`, and
  the comment files are current.

1. Review the new commits and the code they touch, at the same bar as before.
2. Recheck each finding in `{{OUT}}/review.json` at the new head. Lines may
   have moved, and a finding may be fixed. Rerun your probes.
3. Update `{{OUT}}/review.json` and `{{OUT}}/report.md` for {{HEAD_SHORT}},
   with line numbers on the new head.
4. Write `READY_TO_POST` to `.tmp/status.txt`, then stop.
