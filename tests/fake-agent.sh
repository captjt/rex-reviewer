#!/usr/bin/env bash
# A stand-in for a coding agent, for testing the drivers without one. It
# reports OSC 7501 program status the way Claude Code and Codex do:
#
#   idle         after FAKE_BOOT seconds (default 1), and after each prompt
#   working      for FAKE_WORK seconds (default 2) on each prompt
#   blocked      on the prompt "block", as a permission, until it gets "y"
#
# The prompt "ignore" changes nothing, like a prompt that never landed, and
# "exit" ends it. Each line it reads is a prompt.

osc() { printf '\033]7501;%s\033\\' "$1"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

app=fake-agent
sleep "${FAKE_BOOT:-1}"
osc "state=idle:app=$app"
echo "fake-agent: ready"

while IFS= read -r line; do
	case $line in
	exit)
		echo "fake-agent: bye"
		exit 0
		;;
	ignore) ;;
	block)
		osc "state=blocked:kind=permission:app=$app:msg=$(b64 'Allow the fake command?')"
		echo "fake-agent: allow the fake command? (y)"
		;;
	y)
		osc "state=working:app=$app"
		sleep "${FAKE_WORK:-2}"
		osc "state=idle:app=$app"
		echo "fake-agent: allowed"
		;;
	*)
		osc "state=working:app=$app"
		echo "fake-agent: working on: $line"
		sleep "${FAKE_WORK:-2}"
		osc "state=idle:app=$app"
		echo "fake-agent: done: $line"
		;;
	esac
done
