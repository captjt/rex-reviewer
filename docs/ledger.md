# The ledger

Everything rex-reviewer knows lives in plain files under
`~/.local/state/rex-reviewer/`. The watcher and the actions write them; the
menu bar app and anything else you build read them. This page is the
contract. `schema` is 1; a change that breaks readers bumps it.

```
~/.local/state/rex-reviewer/
  state.json
  watcher.json
  events.jsonl
  check-now
  repos/<owner>/<name>/pr-<n>.json
```

Lua writes an empty list as `{}`, so readers should accept `{}` wherever a
list is expected. Times are UTC, as `2026-11-04T19:42:05Z`. Files are
written whole and renamed into place, so a reader never sees half of one.

## state.json

| Field | Meaning |
| --- | --- |
| `schema` | 1 |
| `paused` | `true` while new rounds are paused |
| `stopped` | `true` after `reviewer_down`, until a plain `reviewer_up` |
| `last_scan_at` | the last successful GitHub check |
| `login` | the GitHub account reviews post from |
| `session_id` | the Rex session the watcher runs in |
| `watch_script` | the watcher script's path; `rex do <watch_script>` is its process |
| `seq` | the last event's number |

## watcher.json

Written at every watcher step: after each GitHub check, and whenever a pane
in its session changes status.

| Field | Meaning |
| --- | --- |
| `at` | when the step ran |
| `attention` | what needs you: a list of `{repo, pr, kind, text, round, title, draft?}` |
| `check_failed` | the error, when the GitHub check failed |
| `error` | the error, when the step itself failed |

`kind` is one of `ready` (a checked review waits for you to post or dismiss
it), `blocked` (an agent stopped), `start-failed`, `pane-closed`, or `error`.
`round` and `title` are the PR's. A `ready` item's `draft` sums up the
checked review: `event` (`APPROVE`, `REQUEST_CHANGES`, or `COMMENT`),
`verdict`, and the `blocking` and `non_blocking` finding counts.

## The watcher's status records

The watcher reports the same items as program status (OSC 7501) on its own
pane, so Rex shows them, and so can any tool that follows program status,
such as [rex-inbox](https://github.com/captjt/rex-inbox).
`lua/rex_reviewer/status.lua` builds them.

| Record | Holds |
| --- | --- |
| the root record | `app=rex-reviewer`; `idle` (with `msg` "Paused" while paused), or `error` when a GitHub check or a step failed |
| `pr/<owner>/<name>/<pr>/<round>` | one per `attention` item: `app=rex-reviewer`, `title` "name#pr" and the PR's title, and `msg` |

| `attention` kind | Record state |
| --- | --- |
| `ready` | `blocked`, `kind=permission`; `msg` says the event, the finding counts, and the verdict |
| `blocked`, `pane-closed` | `blocked`, no `kind` |
| `start-failed`, `error` | `error` |

An id segment holds up to 32 characters, so a longer owner or repo name is
cut to 32. Records clear when their item does, and a watcher that starts
clears any its last run left.

## check-now

Any client may create this empty file. The watcher removes it and checks
GitHub within 5 seconds.

## events.jsonl

One JSON object a line, appended: `{seq, at, kind, repo?, pr?, round?, head?, note?, …}`.
Kinds include `requested`, `re-requested`, `unrequested`, `new-head`,
`head-moved`, `pickup`, `started`, `checking`, `delta`, `repointed`,
`awaiting`, `posted`, `dismissed`, `merged`, `closed`, `cleaned`, `paused`,
`resumed`, `started`, and `stopped`. With `effort` set, `started` carries
`effort`, each reviewer's level by name, and `checking` carries the
checker's.

## repos/&lt;owner&gt;/&lt;name&gt;/pr-&lt;n&gt;.json

One entry per PR the tool has seen.

| Field | Meaning |
| --- | --- |
| `repo`, `pr` | `owner/name` and the PR number |
| `title`, `author`, `url` | from GitHub |
| `state` | `queued`, `reviewing`, `posted`, `unrequested`, `merged`, `closed`, or `cleaned` |
| `phase` | while `reviewing`: `reviewer`, `checking`, or `awaiting` (your approval) |
| `round` | the round number, from 1 |
| `trigger` | what started the round: `request`, `re-request`, or `manual` |
| `head` | the PR's head when last seen |
| `round_head` | the head this round reviews |
| `reviewed_head` | the head the last posted review covered |
| `verdict` | the last round's outcome: `APPROVED`, `CHANGES_REQUESTED`, or `DISMISSED` |
| `merge_risk` | `low`, `medium`, or `high`, when assessed |
| `implementation` | what the PR changes, in a sentence or two, from the last round's draft |
| `tokens` | what the agents have spent on the PR so far, as `bin/token-usage` prints it: `codex` and `claude`, each with `input` (not cached), `cache_read`, `cache_write`, `output`, and `total`, and the `total` of both. Counted when a round ends, and once more at cleanup |
| `review_url` | the posted review |
| `outcome` | `merged` or `closed` once the PR ends; it stays after cleanup |
| `ended_at` | when the watcher saw it merged or closed |
| `requested_at` | when the current or last round was requested (or picked up) |
| `additions`, `deletions`, `changed_files` | the PR's size at the last prep |
| `started_at`, `posted_at`, `cleaned_at`, `created_at`, `updated_at` | times |
| `worktree` | the PR's worktree, the primary reviewer's; `.tmp/status.txt` in it is the round's status |
| `session_id`, `pane`, `checker_pane` | the Rex session, the primary reviewer's pane, and the checker's |
| `reviewer`, `reviewer_session`, `checker_session` | the primary reviewer's agent and session, and the checker's session |
| `reviewers` | each reviewer's record, by name: `agent`, `session`, `worktree`, `pane`, `index` and `primary` (its place in the config), `first_round`, `tokens_seen` (its agent's count in its worktree at the last round's end), and `effort` (the level `effort` chose for its last round, absent for the agent's own) |
| `round_reviewers` | the names of the reviewers in the round in progress, primary first |
| `reviewers_done`, `reviewers_total` | while `reviewing`: how many of the round's reviewers are done |
| `checker_effort` | the level `effort` chose for the round's checker, absent for its own |
| `extra_worktrees` | the other reviewers' worktrees, kept for cleanup and token counts |
| `start_error` | why the last start failed |
| `history` | one record per finished round, below |

Each `history` record: `round`, `trigger`, `head`, `verdict`, `review_id`,
`url`, `by` (`agents`, or `you` for a dismissal or your own review),
`requested_at`, `started_at`, `at` (when it posted or was dismissed),
`blocking` and `non_blocking` (finding counts), `merge_risk`, and `tokens`:
what the agents spent in the round, with the same five counts summed across
agents and worktrees. From 0.4, `reviewers` holds each reviewer's part, by
name: `drafted` (findings in its draft), `kept` and `only` (findings in the
checked review whose `found_by` names it, and names only it; absent when
nothing was checked), and `tokens` (what its agent logged in its worktree
in the round; the primary's includes the checker's when both are Claude
Code). From 0.5, each reviewer's part also has `effort`, and the record has
`checker_effort`: the level each agent ran at, as its session recorded it
(Claude Code's transcript, Codex's rollout), or the level `effort` chose
when the session can't be read. Records written before 0.2 have only the first six and `at`. The menu bar app's recap
reads these records, with the `merged` and `closed` events in `events.jsonl`
for entries that predate `outcome`.

### The round's status

`<worktree>/.tmp/status.txt` holds one line. Each reviewer writes its own
in its worktree; the primary's also carries the checker's states, so it's
the round's:

| Status | Meaning |
| --- | --- |
| `WORKING …` | the reviewer is reviewing |
| `READY_TO_POST` | the reviewer is done; the checker starts once every reviewer is |
| `VERIFYING …` | the checker is checking |
| `AWAITING_APPROVAL` | checked; waiting for you to post or dismiss it |
| `POSTED <url>` | posted |
| `DISMISSED` | you dismissed it |
| `HEAD_MOVED` | the post was refused because the PR moved |
| `BLOCKED: <why>` | an agent stopped and needs you |

## Acting on it

Clients act through the Rex actions, never by writing entries:

```sh
rex do reviewer_post pr=12 repo=owner/name      # post a checked review
rex do reviewer_dismiss pr=12 repo=owner/name   # end the round without posting
rex do reviewer_preview pr=12 repo=owner/name   # render it; writes .tmp/rounds/<n>/preview.md
rex do reviewer_focus pr=12 repo=owner/name     # show its tab in the Rex app
rex do reviewer_pause | reviewer_resume | reviewer_up | reviewer_down | reviewer_check
```

A client that shows the status records can pass a record's id as `item=`
in place of `pr=` and `repo=`:

```sh
rex do reviewer_post item=pr/owner/name/12/2
```

The action then acts only if that round is still in progress, and
`reviewer_post` only if the round waits for you (phase `awaiting`).
Otherwise it does nothing and says why, so a client never acts on a round
that moved on after it showed it.
