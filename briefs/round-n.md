# Round {{ROUND}} of {{REPO}} PR #{{PR}}: {{TITLE}}

You reviewed this PR in round {{PREV_ROUND}}, at head {{PREV_HEAD}}. The author
has re-requested review.

- New head: {{HEAD}} (this worktree)
- Refreshed context: `{{CONTEXT}}/`. `delta.diff` and `delta-commits.txt`
  cover {{PREV_HEAD_SHORT}}..{{HEAD_SHORT}}. `threads.json` and
  `review-comments.json` hold the author's replies, and `pr.diff` and
  `ci.json` are current.
- Your last round's output: `.tmp/rounds/{{PREV_ROUND}}/`
- Your output folder: `{{OUT}}/`

1. For each finding from your last round, decide whether it's fixed, partly
   fixed, or not fixed. Rerun its probe from `.tmp/probes/` on the new head,
   and read the author's reply to it, if there is one.
2. Review the delta and the code it touches. {{REVIEW_GUIDE}} Report new
   findings in full.
3. Write `{{OUT}}/review.json` and `{{OUT}}/report.md`. In `review.json`, add
   one `replies` entry for each of {{LOGIN}}'s earlier inline comments that
   this round settles: `{"comment_id": <id from review-comments.json>,
   "body": "Fixed in <sha>: …"}`, or a short note saying what's still missing.
4. Write `READY_TO_POST` to `.tmp/status.txt`, then stop.
