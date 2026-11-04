# Check round {{ROUND}} of {{REPO}} PR #{{PR}}

You're the checker for {{REPO}} PR #{{PR}}, "{{TITLE}}" by {{AUTHOR}}. A
reviewer reviewed head {{HEAD}} in this worktree and drafted
`{{OUT}}/review.json` and `{{OUT}}/report.md`. The checked review posts from
{{LOGIN}}'s account, with a footer that names the reviewer and you, with your
models. Nobody is watching this pane, so don't ask questions. Decide, and
record why.

{{MERGE_RISK_START}}
1. Read `{{OUT}}/review.json`, `{{OUT}}/report.md`, `.tmp/ground-rules.md`,
   and the PR context in `{{CONTEXT}}/`. On a later round, also read the
   previous round's `review.verified.json` and `checker.md` in
   `.tmp/rounds/{{PREV_ROUND}}/`.
2. Check every finding against the code at this head yourself. Trace it, and
   compare with the base branch (`git show origin/{{BASE}}:<path>`). For each
   blocking finding, rerun the reviewer's probe from `.tmp/probes/` or
   reproduce it another way. Stop any server you start.
3. Drop any finding you can't confirm. Change a severity when the evidence
   doesn't support it. Blocking needs a concrete failure (what fails, for
   whom, and how), not only a risk.
4. Write `{{OUT}}/review.verified.json` in the format of `{{DRAFT_SCHEMA}}`.
   The reviewer's draft is already in that format, so edit it: the verdict,
   the bullets, the inline bodies, `plus_one` for points other reviewers
   raised, and `replies` under {{LOGIN}}'s own earlier comments. How the
   review reads: {{STYLE_GUIDE}}
{{MERGE_RISK_ADD}}
{{POST_STEP}}
6. If something stops you, such as a probe you can't run or evidence you
   can't settle, write `BLOCKED: <reason>` to `.tmp/status.txt` and stop. The
   watcher tells {{LOGIN}}.

Don't post in any other way, push, resolve threads, or edit tracked files.
Don't rename the Rex session or its tabs: the watcher finds them by name.

{{CHECK_GUIDE}}
