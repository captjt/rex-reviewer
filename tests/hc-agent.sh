#!/usr/bin/env bash
# Checks bin/hc-agent against a fake agent (tests/fake-agent.sh) in the
# running herdr-core: the commands rex-reviewer's rounds use, their JSON,
# and the exit codes bin/rex-agent gives for the same cases.
#
#   tests/hc-agent.sh
#
# It starts terminals named rr-hct-*, labeled with their own app so the
# real watcher never sees them, in a space named rr-hct, and closes them.
# The Herdr app, if open, shows them in that space while it runs.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
agent="$root/bin/hc-agent"
fake="$root/tests/fake-agent.sh"
export HC_AGENT_PREFIX=rr-hct-
export HC_AGENT_APP=rr-hct
space=rr-hct

pass=0 fail=0
check() {
	local what=$1 got=$2 want=$3
	if [[ $got == "$want" ]]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n  got:  %s\n  want: %s\n' "$what" "$got" "$want"
	fi
}

# run ARGS...: sets out (stdout) and code (exit status).
run() {
	out=$("$agent" "$@" 2>/dev/null)
	code=$?
}

field() { jq -r ".$1 // empty" <<<"$out"; }

cleanup() {
	for n in one two plain cat quits "a-name-long-enough-to-hash-x0123"; do
		"$agent" close "$n" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT
cleanup

start_fake() {
	run start "$1" -s "$space" --kind env --cwd "$root" --timeout 20 "${@:2}" -- FAKE_BOOT=1 FAKE_WORK=2 bash "$fake"
}

# Starting
start_fake one
check "start: exit" "$code" 0
check "start: state" "$(field state)" idle
check "start: name" "$(field name)" one
check "start: address" "$(field block_id | grep -cE '^t[0-9a-f]+$')" 1
check "start: tab" "$(field tab)" "$space.one"
one=$(field block_id)

start_fake one
check "start: name in use" "$code" 2

start_fake two --anchor one
check "start beside: exit" "$code" 0
check "start beside: same tab" "$(field tab)" "$space.one"

run start quits -s "$space" --kind false --timeout 10
check "start: exits during startup" "$code" 4

run start cat -s "$space" --kind cat --timeout 2
check "start: never ready" "$code" 5
"$agent" close cat >/dev/null 2>&1

run start plain -s "$space" --plain --rm --role plain --kind sh -- -c 'sleep 30'
check "start --plain: exit" "$code" 0
check "start --plain: live" "$(field live)" true

long=a-name-long-enough-to-hash-x0123
start_fake "$long"
check "start: long name" "$code" 0
check "start: long name fits hc" "$(hc get "$(field block_id)" --json | jq -r '.name | length <= 32')" true
run get "$long"
check "get: long name" "$code" 0

# Reading
run get one
check "get: exit" "$code" 0
check "get: state" "$(field state)" idle
check "get: by address" "$("$agent" get "$one" | jq -r .name)" "$one"
check "get: updated_at" "$(field updated_at | grep -cE '^[0-9-]+T[0-9:]+Z$')" 1

run get nobody
check "get: no such agent" "$code" 2

check "read" "$("$agent" read one --lines 40 | grep -c 'fake-agent: ready')" 1
check "list" "$("$agent" list -s "$space" --json | jq -r '[.[].name] | sort | join(",")')" "$long,one,two"

# Prompting
run prompt one "first"
check "prompt: exit" "$code" 0
check "prompt: submitted" "$(field submitted)" true
run wait one --until working --timeout 10
check "wait --until working" "$code" 0
run prompt one "second"
check "prompt: busy" "$code" 7
run wait one --timeout 20
check "wait: settled" "$code" 0
check "wait: idle" "$(field state)" idle

run prompt one "third" --wait --timeout 20
check "prompt --wait: exit" "$code" 0
check "prompt --wait: idle" "$(field state)" idle

run prompt one "block" --wait --timeout 20
check "prompt --wait: blocked" "$code" 3
check "prompt --wait: blocked state" "$(field state)" blocked
check "prompt --wait: kind" "$(field kind)" permission
run prompt one "anything"
check "prompt: refuses blocked" "$code" 3

run keys one y enter
check "keys: exit" "$code" 0
run wait one --until idle --timeout 20
check "keys: answered" "$code" 0

run prompt one "ignore" --wait --timeout 30
check "prompt --wait: stalled" "$code" 6

# Closing
run close two
check "close: exit" "$code" 0
check "close: closed" "$(field closed)" true
run get two
check "close: gone" "$code" 2

"$agent" prompt one exit >/dev/null 2>&1
sleep 2
run get one
check "get: exited" "$code" 4
run close one
check "close: exited" "$code" 0

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail == 0 ]]
