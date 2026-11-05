# The review draft

The reviewer writes `.tmp/rounds/<n>/review.json`, and the checker edits it
into `review.verified.json`. `bin/post-review` renders that file into a
GitHub review, checks it, and posts it. This format is the contract between
them; how the text reads is up to the `style` guide.

```json
{
  "event": "REQUEST_CHANGES",
  "verdict": "One or two sentences: what has to change and why, or why it's safe to merge.",
  "implementation": "One or two sentences on what the PR changes and how. For the recap; never posted.",
  "findings": [
    {
      "id": "B1",
      "severity": "blocking",
      "title": "Short claim, used as the bullet unless bullet is set",
      "bullet": "Optional one-line bullet text",
      "path": "src/settings/Settings.tsx",
      "line": 200,
      "start_line": 198,
      "body": "The inline comment: the defect, a concrete failure, and the fix.",
      "suggestion": "Optional: the exact replacement for lines start_line..line",
      "evidence": "How it was verified. For the checker; never posted."
    },
    {
      "id": "N1",
      "severity": "non-blocking",
      "plus_one": "https://github.com/owner/repo/pull/12#discussion_r…",
      "plus_one_label": "Sam's point on the docs screenshots",
      "bullet": "What to add to it, if anything"
    }
  ],
  "checked": "Optional: one sentence on what was run.",
  "merge_risk": {
    "alignment": { "verdict": "good", "gaps": [] },
    "impact": { "verdict": "medium", "gaps": ["Changes the shared settings layout, used on every page."] },
    "verification": { "verdict": "decent", "gaps": [] },
    "rollback_cost": { "verdict": "low", "gaps": [] },
    "error_detection": { "verdict": "n/a", "gaps": [] }
  },
  "replies": [
    { "comment_id": 4459718177, "body": "Fixed in 7e4bac7: the button now waits for both queries." }
  ]
}
```

## Rules the script enforces

- `event` is `REQUEST_CHANGES` when at least one finding is `blocking`, and
  `APPROVE` otherwise. Any other pairing is refused.
- Every finding has a `title` or a `bullet`, and the draft has a `verdict`.
- No text speaks in the first person ("I", "my", "we", "our", …) outside
  code spans and code blocks. The footer says who reviewed.
- `path` and `line` are on the PR head, the RIGHT side. A finding whose line
  is outside the diff can't be an inline comment, so its body goes under its
  bullet, with its location.
- `replies` post under the account's own earlier inline comments, before the
  review. Threads are never resolved.
- `merge_risk`, when present, holds the five categories with one of their
  verdicts each, and a list of gaps. The script computes the level (low,
  medium, or high) and shows the block after the "Checked" line. When the
  merge-risk guide is on, a draft without `merge_risk` is refused.
- The PR must still be at the head the round reviewed (exit 3 otherwise).

## Exit status

- `0`: posted, or rendered with `--dry-run`
- `1`: a usage error, or GitHub refused
- `3`: the PR's head moved past `--head`
- `4`: the draft breaks one of the rules above
