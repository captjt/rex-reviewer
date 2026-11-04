# Review style (default)

How a rex-reviewer review reads. It's the default for the `style` guide slot.
Point `guides.style` at your own guide to change it.

The posting script renders the draft (see `docs/review-draft.md`) into this
shape, and adds the section headings, the bullets' pointers to inline
comments, and the footer. You don't write those.

```markdown
Changes are needed before merge: the Save button works while settings are
still loading, so a save can overwrite them with the defaults.

**Blocking**
- Save works before settings load; details in the inline comment on `Settings.tsx:200`.

**Non-blocking**
- A fast double-click on Sign in starts two logins; details in the inline comment on `login.tsx:33`.
- +1 to [Sam's point on the docs screenshots](https://github.com/…#discussion_r…): the screenshot still shows the old heading.

Checked at the head: the unit tests (771) and the settings browser tests (46) pass.

---

<div align="right"><sub><i>Codex (GPT-6.1) on behalf of @you · checked by Claude Code (Opus 5.5)</i></sub></div>
```

## Writing it

- **Verdict**: one or two sentences. For a changes request, say what has to
  change and the consequence. For an approval, say why it's safe to merge. On
  a later round, say what changed since the last review.
- **Bullets**: one line each, the defect and its consequence. Don't repeat
  the inline comment.
- **Other reviewers**: when someone already raised a point, don't file it
  again. Add a finding with `plus_one` linking their thread, and add to it
  only what's new.
- **Inline comments**: lead with the ask ("Please …") or the defect. Then
  give the concrete failure: what breaks, for whom, and how. Compare with the
  base branch when it's a regression, then give the fix. Use `suggestion`
  only when it's the exact replacement for lines `start_line` to `line` at
  the head.
- **Checked**: at most one sentence on what was run, such as the tests that
  pass and the probes that reproduce. It isn't an inventory.
- **Voice**: no "I", "my", "we", or "our". The footer says who reviewed, and
  the script refuses first-person text outside code. Refer to earlier reviews
  as "the last review".
- Plain English for the PR author. Never refer to local files or `.tmp/`
  paths, which the author can't see.

## Severity

- **Blocking** needs a concrete failure the PR would ship: a bug, a security
  or privacy hole, data loss, a broken contract or migration, a regression
  against the base branch, or a contradiction of the PR's own description. A
  risk with no demonstrated failure is non-blocking.
- `REQUEST_CHANGES` when at least one finding is blocking, `APPROVE`
  otherwise. The script refuses any other pairing.
