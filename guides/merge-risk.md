# Merge risk (default)

The default rubric for the `merge_risk` guide slot. Point `guides.merge_risk`
at your own rubric to change it, or set it to `false` to skip the assessment.
A different rubric still has to produce these five categories and verdicts,
because the posting script weighs them.

Adapted from the `pr` skill in [mattpocock/skills](https://github.com/mattpocock/skills/blob/main/skills/engineering/pr/SKILL.md),
Copyright (c) 2026 Matt Pocock, under the MIT License. See
`THIRD_PARTY_NOTICES.md`.

Merge risk informs; it never blocks. It doesn't change the review's event,
and a high-risk PR with no concrete failure is still approved.

## Categories and verdicts

Each category's description says what low risk looks like.

- **Alignment (poor ⚠️ / decent 👀 / good ✅):** The code matches the
  description and the source issue, when there is one. Behavior assumptions
  and drive-by changes are documented.
- **Impact (large ⚠️ / medium 👀 / small ✅):** The scope is contained and
  away from sensitive code paths.
  - Consider the blast radius: what the change could affect, such as layout
    shifts, breakage for consumers, or mobile layouts.
  - Sensitive areas carry outsized risk whatever the diff's size: auth,
    permissions, payments, personal data, secrets, data migrations,
    dependency bumps, and infra or config changes. Flag any that are touched,
    and call out anything that widens access, weakens validation, or logs
    sensitive data.
- **Verification (poor ⚠️ / decent 👀 / good ✅):** The behavior is verified,
  where that applies.
  - Changes to the user experience need end-to-end proof, as screenshots or
    recordings. Changes that could affect performance need profiling. Prefer
    before-and-after evidence. Missing coverage here is a failure.
  - Edge cases are tested, or documented when they aren't. When only
    documentation covers one, link the relevant code.
- **Rollback cost (high ⚠️ / medium 👀 / low ✅):** The change can be undone
  once merged. A two-way door can be walked back; a one-way door can't.
  Destructive actions and hard-to-reverse decisions are one-way doors.
- **Error detection (poor ⚠️ / decent 👀 / good ✅ / n/a ✅):** If this breaks
  in production, someone finds out before users report it. Look for
  swallowed errors, and fallbacks that hide breakage.

## Gaps

For each category, list the gaps that raise the risk: one succinct line
each, with links to the relevant files. A category with no gaps has an empty
list.

## The level

The posting script computes it; don't. Each verdict scores ⚠️ 3, 👀 2, ✅ 1,
weighted Impact 2, Verification 2, Rollback cost 1.5, Error detection 1, and
Alignment 1. The weighted average is low below 1.5, medium below 2.25, and
high from 2.25.
