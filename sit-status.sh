#!/bin/bash
# Quick local Go/No-go check for both halves of the GPS time-transfer setup:
# the SiT5721 register-save loop (SiT5721 repo) and the SiT-calib capture
# (mbt-ubx-apps repo) - plus their last known output/state, without
# hand-running journalctl/screen -X hardcopy each time. Output is sized for
# an 80x24 terminal.
#
# `systemctl is-active` is not a reliable health check here: these are
# Type=oneshot units that go "inactive" again once a successful run
# completes (see restart-sit5721-pull.service right after a fresh install/
# reboot with nothing to do yet). `is-failed` is what actually distinguishes
# a real failure from normal oneshot idle/inactive state.

SIT5721_DIR=~/project/SiT5721
CALIB_STATEFILE=~/SiT-calib_state.json
SAVE_STATUS_FILE="$SIT5721_DIR/SiT-save_status.txt"

# Colors only for a real terminal - not when redirected/piped (e.g. into a
# log or journalctl) and not when NO_COLOR is set (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	BOLD=$'\033[1m'; DIM=$'\033[2m'
	RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
	RESET=$'\033[0m'
else
	BOLD=; DIM=; RED=; GREEN=; YELLOW=; CYAN=; RESET=
fi

rule() { printf '%s' "$DIM"; printf '\xe2\x94\x80%.0s' {1..80}; printf '%s\n' "$RESET"; }

overall_ok=1

ok()   { printf "  %s%-4s%s %s\n" "$GREEN" "OK" "$RESET" "$1"; }
fail() { printf "  %s%-4s%s %s\n" "$RED" "FAIL" "$RESET" "$1"; overall_ok=0; }

check_unit() {
	local unit="$1" label="$2"
	local state
	state=$(systemctl is-failed "$unit" 2>/dev/null)
	if [ "$state" = "failed" ]; then
		fail "$label: failed"
	else
		ok "$label ($state)"
	fi
}

printf '%s%s%s — %s%s\n' "$BOLD$CYAN" "SiT-calib / SiT5721 status" "$RESET$DIM" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$RESET"
rule

printf '%s%s%s\n' "$BOLD" "SiT5721 register-save loop" "$RESET"
check_unit save-sit5721.timer "save timer"
check_unit save-sit5721.service "last save run"
check_unit restart-sit5721-pull.service "boot-time pull restore"

if [ -f "$SAVE_STATUS_FILE" ]; then
	age_min=$(( ($(date +%s) - $(stat -c %Y "$SAVE_STATUS_FILE")) / 60 ))
	pull=$(grep "Pull Value" "$SAVE_STATUS_FILE" | head -1 | sed 's/^[^0-9+-]*//')
	total=$(grep "Total offset written" "$SAVE_STATUS_FILE" | head -1 | sed 's/^[^0-9+-]*//')
	err=$(grep "Error status flag" "$SAVE_STATUS_FILE" | head -1 | awk '{print $NF}')
	stab=$(grep "Stability flag" "$SAVE_STATUS_FILE" | head -1 | awk '{print $NF}')
	printf "       Pull %s, Total %s, %s%s%s/%s (%sm ago)\n" \
		"$pull" "$total" "$CYAN" "$err" "$RESET" "$stab" "$age_min"
else
	fail "save status file missing ($SAVE_STATUS_FILE)"
fi

echo
printf '%s%s%s\n' "$BOLD" "mbt-ubx-apps SiT-calib capture" "$RESET"
check_unit restart-calib.service "boot-time resume"

screen_running=0
if screen -list 2>/dev/null | grep -qE '\.SiT-calib[[:space:]]'; then
	ok "SiT-calib screen: running"
	screen_running=1
else
	fail "SiT-calib screen: NOT running"
fi

if [ -f "$CALIB_STATEFILE" ]; then
	state_line=$(python3 -c "
import json
from datetime import datetime, timezone
with open('$CALIB_STATEFILE') as f:
    d = json.load(f)
saved_at = datetime.fromisoformat(d['saved_at'])
age = (datetime.now(timezone.utc) - saved_at).total_seconds()
h, rem = divmod(int(age), 3600)
m, s = divmod(rem, 60)
age_str = f'{h}h{m:02d}m{s:02d}s'
note = 'fresh' if age <= d['interval'] else 'STALE - reboot now needs manual TOW'
print(f\"TOW {d['TOW_selected']} (week {d['week']}), saved {age_str} ago, {note}\")
")
	state_line="${state_line/STALE/${YELLOW}STALE${RESET}}"
	printf "       %s\n" "$state_line"
else
	printf "       %s\n" "(no state file at $CALIB_STATEFILE)"
fi

if [ "$screen_running" -eq 1 ]; then
	printf "       %sRecent output:%s\n" "$DIM" "$RESET"
	hardcopy=$(mktemp)
	if screen -S SiT-calib -X hardcopy "$hardcopy" 2>/dev/null && [ -s "$hardcopy" ]; then
		tail -n 6 "$hardcopy" | cut -c1-73 | sed "s/^/       ${DIM}/; s/\$/${RESET}/"
	fi
	rm -f "$hardcopy"
fi

echo
rule
if [ "$overall_ok" -eq 1 ]; then
	printf '%s%s%s\n' "${BOLD}${GREEN}" "GO - everything looks healthy." "$RESET"
	exit 0
else
	printf '%s%s%s\n' "${BOLD}${RED}" "NO-GO - see FAIL lines above." "$RESET"
	exit 1
fi
