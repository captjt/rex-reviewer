5. Run `rex do reviewer_preview {{ACTION_ARGS}}` and read the preview.
   {{LOGIN}} reads it and decides whether to post it.
   - Run it as the bare command, exactly as written, from this worktree: no
     `cd`, pipe, redirect, `;`, or `echo` around it. Only the bare command is
     pre-approved.
   - If it reports a broken rule, such as first-person text or a verdict that
     doesn't match the findings, fix the draft and run it again.
   - If it reports that the head moved, write `HEAD_MOVED` to
     `.tmp/status.txt` and stop. The watcher sends the reviewer the new
     commits.
   - When the preview is right, write `{{OUT}}/checker.md`: the verdict, and
     what you changed from the reviewer's draft and why. Then write
     `AWAITING_APPROVAL` to `.tmp/status.txt` and stop. Don't post or dismiss
     the review yourself.
