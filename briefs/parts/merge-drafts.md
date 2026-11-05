## Merging the drafts

The {{N}} reviewers worked without seeing each other's drafts. Merge them
into one review as you check them:

- Start from `{{OUT}}/review.json`, the `{{PRIMARY}}` reviewer's draft, and
  bring in every finding from the others. Weigh the candidates each report
  rejected too.
- Findings about the same defect become one. Keep the best evidence and the
  fix that covers the most, and list every reviewer that raised it in
  `found_by`.
- A finding only one reviewer raised meets the same bar as any other:
  confirm it or drop it. Don't drop it for being alone, or keep it for being
  repeated.
- Where one report calls something sound and another reviewer files it,
  settle it in the code.
- A reviewer's probes and builds are in its own worktree, and the paths in
  its report are relative to it. Rerun them there.
- Number the merged findings B1, B2, … and N1, N2, … again, and keep
  `implementation` from the `{{PRIMARY}}` draft unless another describes the
  change better.
- In `checker.md`, add a column to the table naming who found each finding.
