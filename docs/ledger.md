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
| `attention` | what needs you: a list of `{repo, pr, kind, text}` |
| `check_failed` | the error, when the GitHub check failed |
| `error` | the error, when the step itself failed |

`kind` is one of `ready` (a checked review waits for you to post or dismiss
it), `blocked` (an agent stopped), `start-failed`, `pane-closed`, or `error`.

## check-now

Any client may create this empty file. The watcher removes it and checks
GitHub within 5 seconds.

## events.jsonl

One JSON object a line, appended: `{seq, at, kind, repo?, pr?, round?, head?, note?, …}`.
Kinds include `requested`, `re-requested`, `unrequested`, `new-head`,
`head-moved`, `pickup`, `started`, `checking`, `delta`, `repointed`,
`awaiting`, `posted`, `dismissed`, `merged`, `closed`, `cleaned`, `paused`,
`resumed`, `started`, and `stopped`.

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
| `review_url` | the posted review |
| `started_at`, `posted_at`, `cleaned_at`, `created_at`, `updated_at` | times |
| `worktree` | the PR's worktree; `.tmp/status.txt` in it is the round's status |
| `session_id`, `pane`, `checker_pane` | the Rex session and the agents' pane names |
| `reviewer`, `reviewer_session`, `checker_session` | which agent reviewed, and the agents' session IDs |
| `start_error` | why the last start failed |
| `history` | one record per finished round: `{round, trigger, head, verdict, review_id, by, at}` |

### The round's status

`<worktree>/.tmp/status.txt` holds one line:

| Status | Meaning |
| --- | --- |
| `WORKING …` | the reviewer is reviewing |
| `READY_TO_POST` | the reviewer is done; the checker starts next |
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
