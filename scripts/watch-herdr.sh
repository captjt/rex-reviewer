#!/bin/sh
# The watcher on Herdr. reviewer_up runs it in the watcher's terminal, in
# the control tab of the rex-reviewer space:
#
#   sh <rex-reviewer>/scripts/watch-herdr.sh
#
# It feeds scripts/watch-herdr.lua one JSON line per event hc reports for
# rex-reviewer's terminals, and a tick line every 5 seconds, its clock. If
# the script stops, or hc's event stream ends (the core restarted), it
# starts both again after 10 seconds.

root=$(cd "$(dirname "$0")/.." && pwd)
app=${REX_REVIEWER_APP:-rex-reviewer}

while :; do
	{
		# A tick that can't be written means the script stopped: end the
		# stream rather than die of SIGPIPE before killing hc.
		trap '' PIPE
		hc events --json --label "$app=1" &
		events=$!
		while kill -0 "$events" 2>/dev/null && echo '{"tick":true}'; do
			sleep 5
		done 2>/dev/null
		kill "$events" 2>/dev/null
	} | luajit "$root/scripts/watch-herdr.lua"
	echo "watcher stopped ($?); restarting in 10s"
	sleep 10
done
