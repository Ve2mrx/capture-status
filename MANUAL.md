# capture-status — install & operations manual

Quick local Go/No-go health check spanning both halves of the GPS
time-transfer setup:
- [SiT5721](../../SiT5721/) — the GPSDO chip's register-save loop
  (`save-sit5721.timer`/`.service`) and boot-time Pull Value restore
  (`restart-sit5721-pull.service`).
- [mbt-ubx-apps](../mbt-ubx-apps/) — the `SiT-calib` capture screen and its
  boot-time resume (`restart-calib.service`).

A standalone project (not a subfolder of either) because it reads state
from both without belonging to either.

**Keep this file up to date** whenever install steps, file/unit names, or
checks change.

## Install

```sh
cd project/ubx-data/capture-status
./install.sh    # symlinks sit-status.sh into ~/bin
```

No dependencies beyond what's already on the host for the other two
projects (`systemd`, `screen`, `python3`).

## Usage

```sh
~/bin/sit-status.sh
```

Exits `0` for GO, `1` for NO-GO. Checks, in order:
- `save-sit5721.timer`, `save-sit5721.service`, `restart-sit5721-pull.service`
  via `systemctl is-failed` — **not** `is-active`, since these are
  `Type=oneshot` units that go back to `inactive` once a successful run
  completes; `is-failed` is what actually distinguishes a real failure
  from normal oneshot idle state.
- Last save snapshot (`SiT5721/SiT-save_status.txt`): age + key lines
  (Pull Value, total offset written, error/stability flags).
- **Since 2026-08-01: health telemetry** (`~/sit-health-24h.json`, written
  by `save-SiT5721.py`'s 10-min sampler - see `SiT5721/MANUAL.md`). **WARN**
  (not FAIL) if the file's own `warnings` list is non-empty (a health field
  reading `n == 0` while the window has data - a broken sensor, not just a
  quiet one) or if the file is missing or older than `HEALTH_STALE_MIN`
  (30 min - the sampler runs every 10). Otherwise **OK**, showing `n` and
  age. Deliberately a WARN, not a FAIL: this is diagnostic (per
  `ubx-data/claude-code-silent-telemetry-failure-brief.md`, which has no
  email alert either), so it does **not** affect the overall GO/NO-GO exit
  code - a stale/broken health field alone should never mask or compete
  with a real capture/save failure elsewhere in the output.
- `restart-calib.service` (same `is-failed` reasoning).
- Whether the `SiT-calib` screen is running (`screen -list`).
- Capture state freshness (`~/SiT-calib_state.json`'s `saved_at` vs.
  `interval`) — a `STALE` result means a reboot *right now* would need
  manual TOW entry (see mbt-ubx-apps' project memory
  `restart-calib-manual-tow`), not that anything is currently broken.
- **Since 2026-10-14: the `lea-view` log** (`~/lea-view.csv`, a row a
  minute from `get-data.py --lea-view` - see `mbt-ubx-apps/MANUAL.md`),
  checked only while the screen runs. **WARN** if the file is missing or
  older than `LEA_VIEW_STALE_MIN` (5 min), and if `~/lea-view_errors.log`
  was written in the last 24 h (shows the last `#N <error>`). The age check
  is the one that matters: the error log only catches failures that raise,
  while a logger that silently writes nothing leaves only a stale file.
  WARN, not FAIL, for the same reason as health telemetry.
- Last ~6 lines of the `SiT-calib` screen's terminal output, via
  `screen -S SiT-calib -X hardcopy` (a snapshot, no need to attach).

Output is sized for an 80x24 terminal (~24 lines with the lea-view line,
no line over 80 columns)
and colorized (green OK / red FAIL / yellow WARN/STALE) when run
interactively. Colors auto-disable when output is piped/redirected (not a
tty) or when `NO_COLOR` is set (https://no-color.org).

## Key files/paths

| Path | Purpose |
|---|---|
| `~/bin/sit-status.sh` | Symlink installed by `install.sh` |
| `~/project/SiT5721/SiT-save_status.txt` | Read for the last save snapshot |
| `~/SiT-calib_state.json` | Read for capture-state freshness |
| `~/sit-health-24h.json` | Read for the health-telemetry WARN check (since 2026-08-01) |
| `~/lea-view.csv`, `~/lea-view_errors.log` | Read (mtime only, plus the error log's last line) for the lea-view WARN check (since 2026-10-14) |

## Known issues / troubleshooting log

**2026-07-08 — stale `systemctl is-failed` state produced a false FAIL
after an already-resolved incident.** `restart-calib.service` and
`restart-calib-alert.service` had genuinely failed at boot on
2026-07-06 (the i2c-dev-not-loaded-yet incident - see mbt-ubx-apps'
`MANUAL.md`), but the manual recovery used that night
(`screen -X -S SiT-calib quit` + `set-calib-screen.sh <TOW>`) bypassed
`systemctl` entirely, so it fixed the actual capture but never cleared
the units' failed state. `sit-status.sh` kept reporting
`FAIL boot-time resume: failed` for the next ~44 hours even though
capture was healthy the whole time, because `systemctl is-failed`
reports the *last* run's result, not current health, and nothing had
restarted those units since. Not a bug in this script's `is-failed`
design (still the right check for `Type=oneshot` units generally - see
Usage above) - just a reminder that a failed unit needs an explicit
`sudo systemctl reset-failed <unit>` after a manual-recovery path that
doesn't go through `systemctl`, or the FAIL persists until the next
reboot regardless of actual health. Cleared with:
```sh
sudo systemctl reset-failed restart-calib.service restart-calib-alert.service
```

## Possible follow-ons

A web dashboard (for remote/phone access) was discussed as a bigger,
separate follow-on if this CLI check ever isn't enough — not started.
