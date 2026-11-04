5. Run `rex do reviewer_preview {{ACTION_ARGS}}` and read the preview. Then
   run `rex do reviewer_post {{ACTION_ARGS}}`.
   - Run each as the bare command, exactly as written, from this worktree:
     no `cd`, pipe, redirect, `;`, or `echo` around it. Only the bare
     commands are pre-approved.
   - If it reports a broken rule, such as first-person text or a verdict that
     doesn't match the findings, fix the draft and run it again.
   - If it reports that the head moved, write `HEAD_MOVED` to
     `.tmp/status.txt` and stop. The watcher sends the reviewer the new
     commits.
   - On success, write `POSTED <review url>` to `.tmp/status.txt`. Then write
     `{{OUT}}/checker.md`: the verdict, and what you changed from the
     reviewer's draft and why.
