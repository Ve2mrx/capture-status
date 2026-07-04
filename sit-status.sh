#!/bin/bash
# Quick local Go/No-go check for both halves of the GPS time-transfer setup:
# the SiT5721 register-save loop (SiT5721 repo) and the SiT-calib capture
# (mbt-ubx-apps repo) - plus their last known output/state, without
# hand-running journalctl/screen -X hardcopy each time.
#
# `systemctl is-active` is not a reliable health check here: these are
# Type=oneshot units that go "inactive" again once a successful run
# completes (see restart-sit5721-pull.service right after a fresh install/
# reboot with nothing to do yet). `is-failed` is what actually distinguishes
# a real failure from normal oneshot idle/inactive state.

SIT5721_DIR=~/project/SiT5721
CALIB_STATEFILE=~/SiT-calib_state.json
SAVE_STATUS_FILE="$SIT5721_DIR/SiT-save_status.txt"

overall_ok=1

check_unit() {
	local unit="$1" label="$2"
	local state
	state=$(systemctl is-failed "$unit" 2>/dev/null)
	if [ "$state" = "failed" ]; then
		echo "  FAIL   $label ($unit): failed"
		overall_ok=0
	else
		echo "  ok     $label ($unit): $state"
	fi
}

echo "=== SiT5721 register-save loop ==="
check_unit save-sit5721.timer "save timer"
check_unit save-sit5721.service "last save run"
check_unit restart-sit5721-pull.service "boot-time pull restore"

if [ -f "$SAVE_STATUS_FILE" ]; then
	age_min=$(( ($(date +%s) - $(stat -c %Y "$SAVE_STATUS_FILE")) / 60 ))
	echo "  Last save status (${age_min}m ago, $SAVE_STATUS_FILE):"
	grep -E "Pull Value|Total offset written|Error status flag|Stability flag" "$SAVE_STATUS_FILE" | sed 's/^/    /'
else
	echo "  NO STATUS FILE at $SAVE_STATUS_FILE"
	overall_ok=0
fi

echo
echo "=== mbt-ubx-apps SiT-calib capture ==="
check_unit restart-calib.service "boot-time resume"

if screen -list 2>/dev/null | grep -qE '\.SiT-calib[[:space:]]'; then
	echo "  ok     SiT-calib screen: running"
else
	echo "  FAIL   SiT-calib screen: NOT running"
	overall_ok=0
fi

if [ -f "$CALIB_STATEFILE" ]; then
	python3 -c "
import json
from datetime import datetime, timezone
with open('$CALIB_STATEFILE') as f:
    d = json.load(f)
saved_at = datetime.fromisoformat(d['saved_at'])
age = (datetime.now(timezone.utc) - saved_at).total_seconds()
fresh = 'fresh' if age <= d['interval'] else 'STALE - a reboot right now would need manual TOW entry'
print(f\"  Capture state: TOW {d['TOW_selected']} (week {d['week']}), saved {d['saved_at']} ({age / 3600:.1f}h ago, {fresh})\")
"
else
	echo "  NO STATE FILE at $CALIB_STATEFILE"
fi

echo "  Last terminal output:"
hardcopy=$(mktemp)
if screen -S SiT-calib -X hardcopy "$hardcopy" 2>/dev/null && [ -s "$hardcopy" ]; then
	tail -n 10 "$hardcopy" | sed 's/^/    /'
else
	echo "    (screen not running, no output to show)"
fi
rm -f "$hardcopy"

echo
if [ "$overall_ok" -eq 1 ]; then
	echo "GO: everything looks healthy."
	exit 0
else
	echo "NO-GO: see FAIL lines above."
	exit 1
fi
