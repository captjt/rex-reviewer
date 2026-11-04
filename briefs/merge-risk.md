# Merge risk for {{REPO}} PR #{{PR}}, round {{ROUND}}

Assess the risk of merging {{REPO}} PR #{{PR}}, "{{TITLE}}" by {{AUTHOR}}, at
head {{HEAD}}. {{MERGE_RISK_GUIDE}} Use its five categories and verdicts.

A code review of this PR runs alongside you. Stay independent of it: don't
read `.tmp/rounds/`, `.tmp/probes/`, or `.tmp/report.md`. Judge the PR as its
author submitted it: the description, the diff, its tests, and its CI.

## What to read

- `{{CONTEXT}}/pr.json`: the title, the description (including any
  screenshots or recordings it embeds), and the files.
- `{{CONTEXT}}/pr.diff`: the change against `{{BASE}}`.
- `{{CONTEXT}}/ci.json`: the checks at this head.
- `{{CONTEXT}}/reviews.json`, `review-comments.json`, and
  `issue-comments.json`: what other reviewers raised.
- The code at this head, in this worktree, and the base branch's with
  `git show origin/{{BASE}}:<path>`.
- If the description links an issue and you have read-only access to its
  tracker, read it to judge Alignment. If you can't, judge against the
  description alone and say so in that category's gaps.

## Rules

- Read only. Don't edit files, run builds or tests, start servers, or contact
  GitHub.
- Gaps are what raise the risk, one succinct line each, in plain English,
  without "I" or "we". A category with no gaps has an empty list.
- Link files as GitHub URLs at the head, such as
  `https://github.com/{{REPO}}/blob/{{HEAD}}/<path>#L<line>`. Never local paths.
- Don't compute the score or the level. The posting script does that from
  your verdicts.

## Output

Write `{{OUT}}/merge-risk.json`:

```json
{
  "alignment": { "verdict": "poor | decent | good", "gaps": [] },
  "impact": { "verdict": "large | medium | small", "gaps": ["Changes the shared settings layout, used on every page."] },
  "verification": { "verdict": "poor | decent | good", "gaps": [] },
  "rollback_cost": { "verdict": "high | medium | low", "gaps": [] },
  "error_detection": { "verdict": "poor | decent | good | n/a", "gaps": [] }
}
```

Then reply with one line: `merge-risk.json written`.
