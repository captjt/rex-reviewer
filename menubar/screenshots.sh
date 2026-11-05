#!/bin/sh
# Render the README's screenshots of the menu bar app from a made-up ledger:
# one repo, example/storefront, with times relative to now, so no real repo
# or PR shows up in them. Run it again after changing the panel's layout.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
images="$here/../docs/images"
demo=$(mktemp -d)
trap 'rm -rf "$demo"' EXIT

swift build --package-path "$here"
bin="$(swift build --package-path "$here" --show-bin-path)/RexReviewer"

# --- The ledger ------------------------------------------------------------

repo="$demo/repos/example/storefront"
mkdir -p "$repo" "$images"

cat >"$demo/ledger.jq" <<'EOF'
# Times are in minutes before now.
def ago($m): (now - $m * 60) | floor | todate;

def pr($n; $title; $author; $additions; $deletions):
  {repo: "example/storefront", pr: $n, title: $title, author: $author,
   url: "https://github.com/example/storefront/pull/\($n)",
   additions: $additions, deletions: $deletions, trigger: "request"};

def round($n; $verdict; $at; $blocking; $non_blocking; $risk):
  {round: $n, trigger: (if $n == 1 then "request" else "re-request" end), verdict: $verdict,
   by: "agents", requested_at: ago($at + 25), started_at: ago($at + 22), at: ago($at),
   blocking: $blocking, non_blocking: $non_blocking, merge_risk: $risk};

# The entry that posted rounds leave behind.
def posted($rounds; $implementation):
  ($rounds | last) as $last
  | {state: "posted", round: $last.round, trigger: $last.trigger, verdict: $last.verdict,
     merge_risk: $last.merge_risk, requested_at: $last.requested_at,
     started_at: $last.started_at, posted_at: $last.at,
     implementation: $implementation, history: $rounds};

def ended($outcome; $at): {state: "cleaned", outcome: $outcome, ended_at: ago($at)};

def reviewing($round; $phase; $started):
  {state: "reviewing", phase: $phase, round: $round, requested_at: ago($started + 3),
   started_at: ago($started), worktree: "\($demo)/worktrees/pr-\(.pr)"};

# Now: one queued, two in progress, one waiting for you.
(pr(148; "feat(cart): keep the carts of signed-out shoppers"; "mira"; 212; 18)
  + {state: "queued", round: 0, requested_at: ago(3)}),

(pr(147; "feat(checkout): add a dark theme to the checkout pages"; "theo"; 486; 97)
  | . + reviewing(1; "reviewer"; 12)),

(pr(145; "perf(search): cache product search results per locale"; "kai"; 158; 41)
  + posted([round(1; "CHANGES_REQUESTED"; 1440; 1; 2; "medium")];
      "Caches search results for ten minutes, keyed by query, locale and price list, and clears a locale's entries when one of its products changes.")
  | . + reviewing(2; "checking"; 38)),

(pr(142; "fix(webhooks): retry failed deliveries with backoff"; "dana"; 133; 12)
  | . + reviewing(1; "awaiting"; 52)),

# This week's reviews, and how their PRs ended.
(pr(141; "fix(orders): keep refund totals in the order's currency"; "dana"; 74; 22)
  + posted([round(1; "CHANGES_REQUESTED"; 3 * 1440; 1; 1; "low"), round(2; "APPROVED"; 1620; 0; 1; "low")];
      "Converts each refund into the order's currency before summing, and stores the rate on the refund line so reports match the receipt.")
  + ended("merged"; 300)),

(pr(139; "feat(admin): bulk-edit product tags"; "mira"; 341; 56)
  + posted([round(1; "APPROVED"; 2 * 1440; 0; 2; "medium")];
      "Adds a bulk tag editor to the product list: pick rows, then add or remove tags in one request that applies in a single transaction.")
  + ended("merged"; 1560)),

(pr(138; "feat(auth): sign in with a magic link"; "theo"; 529; 34)
  + posted([round(1; "CHANGES_REQUESTED"; 1200; 2; 1; "high")];
      "Adds passwordless sign-in: emails a single-use link that expires after 15 minutes and signs the shopper in on whichever device opens it.")),

(pr(136; "refactor(api): split the order service by domain"; "kai"; 912; 870)
  + posted([round(1; "CHANGES_REQUESTED"; 4 * 1440; 1; 0; "medium"), round(2; "APPROVED"; 360; 0; 1; "medium")];
      "Splits the order service into creation, payment and fulfilment modules behind the same API, with no change in behavior.")),

(pr(133; "chore(deps): replace moment with date-fns"; "kai"; 288; 301)
  + posted([round(1; "CHANGES_REQUESTED"; 5 * 1440; 1; 1; "medium")];
      "Swaps moment for date-fns across the storefront and admin, rewriting each date format and time zone conversion.")
  + ended("closed"; 3 * 1440)),

# Earlier this month, and the month before, for the sparkline and the deltas.
(pr(129; "feat(catalog): show stock per warehouse"; "dana"; 198; 40)
  + posted([round(1; "APPROVED"; 12 * 1440; 0; 1; "low")];
      "Adds a per-warehouse stock table to the product page, read from the inventory service's existing endpoint.")
  + ended("merged"; 11 * 1440)),

(pr(126; "fix(search): match accented product names"; "theo"; 61; 9)
  + posted([round(1; "CHANGES_REQUESTED"; 20 * 1440; 1; 0; "low"), round(2; "APPROVED"; 18 * 1440; 0; 0; "low")];
      "Folds accents out of both the indexed names and the query, so a search for creme finds Crème brûlée.")
  + ended("merged"; 17 * 1440)),

(pr(118; "feat(admin): export orders as CSV"; "mira"; 140; 4)
  + posted([round(1; "APPROVED"; 37 * 1440; 0; 0; "low")]; null) + ended("merged"; 36 * 1440)),

(pr(115; "fix(cart): stop double-applying discount codes"; "dana"; 45; 17)
  + posted([round(1; "CHANGES_REQUESTED"; 47 * 1440; 1; 0; "medium"), round(2; "APPROVED"; 45 * 1440; 0; 0; "medium")]; null)
  + ended("merged"; 44 * 1440))
EOF

jq -n -c --arg demo "$demo" -f "$demo/ledger.jq" | while IFS= read -r entry; do
	n=$(printf '%s\n' "$entry" | jq -r .pr)
	printf '%s\n' "$entry" | jq . >"$repo/pr-$n.json"
done

# Each round in progress has a status line in its worktree, as its agents write it.
for s in "147 WORKING" "145 VERIFYING" "142 AWAITING_APPROVAL"; do
	n=${s%% *}
	mkdir -p "$demo/worktrees/pr-$n/.tmp"
	echo "${s#* }" >"$demo/worktrees/pr-$n/.tmp/status.txt"
done

jq -n '{schema: 1, login: "you", last_scan_at: (now - 60 | floor | todate), watch_script: "scripts/watch.lua"}' >"$demo/state.json"
jq -n '{schema: 1, at: (now | floor | todate), attention: []}' >"$demo/watcher.json"

# --- The screenshots -------------------------------------------------------

for look in light dark; do
	REX_REVIEWER_STATE_DIR="$demo" "$bin" --snapshot "$images/now-$look.png" --tab Now --appearance "$look"
	REX_REVIEWER_STATE_DIR="$demo" "$bin" --snapshot "$images/recap-$look.png" --tab Recap --range "30 days" --appearance "$look"
done
echo "wrote $(cd "$images" && pwd)/{now,recap}-{light,dark}.png"

# The social preview card shows now-dark.png, so render it again too. It
# needs Chrome; upload the result in the repo's Settings, under Social preview.
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$chrome" ]; then
	"$chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1280,640 \
		--screenshot="$images/social-preview.png" "file://$(cd "$images" && pwd)/social-preview.html" >/dev/null 2>&1
	echo "wrote $(cd "$images" && pwd)/social-preview.png"
fi
