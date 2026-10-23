#!/bin/bash

# Ossuary Connection Monitor
# Watches the network and reacts to connection changes (by default: reload the
# kiosk page when the connection comes back), runs the periodic refresh, and
# executes time-based schedule rules.
#
# Signals: HUP = reload the configuration.

CONFIG_FILE="/etc/ossuary/config.json"
STATE_FILE="/run/ossuary/connection-state"
SCHEDULE_STATE_FILE="/var/lib/ossuary/schedule-state.json"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CHECK_INTERVAL=5

# shellcheck source=ossuary-lib.sh
. "$SCRIPT_DIR/ossuary-lib.sh" 2>/dev/null || . /opt/ossuary/scripts/ossuary-lib.sh

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$SCHEDULE_STATE_FILE")"

log() {
    # stdout goes to the journal (journalctl -u ossuary-connection-monitor)
    echo "$1"
}

BEHAVIOR_LOST=""
BEHAVIOR_REGAINED=""
REGAINED_DELAY=3
REFRESH_INTERVAL=0

reload_config() {
    local result
    # Defaults match config-server.py DEFAULT_CONFIG; a config.json written by
    # the installer has no "behaviors" block at all.
    result=$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
try:
    config = json.load(open(sys.argv[1]))
except Exception:
    config = {}
b = config.get('behaviors') or {}
lost = b.get('on_connection_lost') or {}
regained = b.get('on_connection_regained') or {}
refresh = b.get('scheduled_refresh') or {}
def whole(value, default):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return default
print(lost.get('action', 'show_overlay') if isinstance(lost, dict) else 'show_overlay')
print(regained.get('action', 'refresh_page') if isinstance(regained, dict) else 'refresh_page')
print(whole(regained.get('delay_seconds', 3), 3) if isinstance(regained, dict) else 3)
print(whole(refresh.get('interval_minutes', 60), 60) if isinstance(refresh, dict) and refresh.get('enabled') else 0)
PY
)
    BEHAVIOR_LOST=$(sed -n 1p <<< "$result")
    BEHAVIOR_REGAINED=$(sed -n 2p <<< "$result")
    REGAINED_DELAY=$(sed -n 3p <<< "$result")
    REFRESH_INTERVAL=$(sed -n 4p <<< "$result")
    [[ "$REGAINED_DELAY" =~ ^[0-9]+$ ]] || REGAINED_DELAY=3
    [[ "$REFRESH_INTERVAL" =~ ^[0-9]+$ ]] || REFRESH_INTERVAL=0
    log "Config: on lost=${BEHAVIOR_LOST:-none}, on regained=${BEHAVIOR_REGAINED:-none}, periodic refresh=${REFRESH_INTERVAL}m"
}

check_connection() {
    if ossuary_has_lan; then echo connected; else echo disconnected; fi
}

send_hup_to_process_manager() {
    local pid
    pid=$(cat /run/ossuary/process.pid 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -HUP "$pid" 2>/dev/null
}

# Reload the page in place through DevTools; restart the browser if that fails.
refresh_chromium() {
    local out
    if out=$(python3 "$SCRIPT_DIR/cdp-reload.py" 2>&1); then
        log "Page reloaded ($out)"
        return 0
    fi
    log "In-place reload failed ($out); restarting the browser"
    send_hup_to_process_manager || log "Could not restart the browser: process manager not running"
}

# Switch to a saved display profile (each preset saves its command).
switch_profile() {
    local profile="$1" result
    result=$(python3 - "$CONFIG_FILE" "$profile" <<'PY' 2>&1
import fcntl, json, os, sys
path, name = sys.argv[1], sys.argv[2]
# Same lock as config-server.py, so a schedule switch can't race a UI save.
lock = os.open('/etc/ossuary/config.lock', os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(lock, fcntl.LOCK_EX)
config = json.load(open(path))
command = ((config.get('profiles') or {}).get(name) or {}).get('command', '').strip()
if not command:
    print(f'profile "{name}" has no saved command')
    sys.exit(1)
if config.get('startup_command') == command:
    print('already active')
    sys.exit(0)
config['startup_command'] = command
config['active_profile'] = name
tmp = path + '.monitor.tmp'
with open(tmp, 'w') as f:
    json.dump(config, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.chmod(tmp, 0o600)
os.rename(tmp, path)
print('switched')
PY
)
    local status=$?
    log "Switch to profile '$profile': $result"
    [ $status -eq 0 ] && [ "$result" = "switched" ] && send_hup_to_process_manager
}

# Print "action:profile" for each schedule rule due now. Each rule fires once
# per day per trigger time: the state file remembers the last firing. A rule is
# due from its trigger minute until 5 minutes later, so a missed tick (slow
# boot, clock step) still fires it once.
due_schedule_actions() {
    python3 - "$CONFIG_FILE" "$SCHEDULE_STATE_FILE" <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime
config_path, state_path = sys.argv[1], sys.argv[2]
try:
    schedule = (json.load(open(config_path)).get('schedule') or {})
except Exception:
    sys.exit(0)
if not schedule.get('enabled'):
    sys.exit(0)
try:
    fired = json.load(open(state_path))
except Exception:
    fired = {}
now = datetime.now()
today = now.strftime('%Y-%m-%d')
day = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'][now.weekday()]
minute_now = now.hour * 60 + now.minute
changed = False
for rule in schedule.get('rules') or []:
    if not isinstance(rule, dict) or rule.get('enabled') is False:
        continue
    trigger = rule.get('trigger') or {}
    if trigger.get('type', 'time') != 'time' or day not in (trigger.get('days') or []):
        continue
    try:
        h, m = map(int, str(trigger.get('time', '')).split(':'))
    except ValueError:
        continue
    late = minute_now - (h * 60 + m)
    if not 0 <= late < 5:
        continue
    key = f"{today} {h:02d}:{m:02d}"
    rule_id = str(rule.get('id') or rule.get('name') or f'{h}:{m}')
    if fired.get(rule_id) == key:
        continue
    fired[rule_id] = key
    changed = True
    action = rule.get('action') or {}
    print(f"{action.get('type', 'refresh')}:{action.get('profile', '')}")
if changed:
    tmp = state_path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(fired, f)
    os.rename(tmp, state_path)
PY
}

execute_schedule_action() {
    local action_type="${1%%:*}" profile="${1#*:}"
    log "Schedule: $action_type${profile:+ ($profile)}"
    case "$action_type" in
        refresh) refresh_chromium ;;
        restart) send_hup_to_process_manager ;;
        switch_profile) switch_profile "$profile" ;;
        *) log "Unknown schedule action: $action_type" ;;
    esac
}

on_connection_lost() {
    log "Connection lost"
    echo disconnected > "$STATE_FILE"
}

on_connection_regained() {
    log "Connection regained (action: ${BEHAVIOR_REGAINED:-none})"
    echo connected > "$STATE_FILE"
    case "$BEHAVIOR_REGAINED" in
        refresh_page|refresh)
            sleep "$REGAINED_DELAY"
            refresh_chromium
            ;;
        restart)
            send_hup_to_process_manager
            ;;
    esac
}

trap 'log "Stopping"; exit 0' TERM INT
trap 'reload_config' HUP

main() {
    log "Connection monitor started"
    reload_config

    local last_state current last_refresh=$SECONDS clock_warned=0
    # Start from "unknown": the first observation is not treated as a change,
    # so booting offline doesn't count as "lost", nor booting online as "regained".
    last_state=unknown

    while true; do
        current=$(check_connection)
        if [ "$last_state" != unknown ] && [ "$current" != "$last_state" ]; then
            if [ "$current" = disconnected ]; then
                on_connection_lost
            else
                on_connection_regained
            fi
        fi
        last_state="$current"

        if [ "$current" = connected ] && [ "${REFRESH_INTERVAL:-0}" -gt 0 ] \
            && [ $((SECONDS - last_refresh)) -ge $((REFRESH_INTERVAL * 60)) ]; then
            log "Periodic refresh (every ${REFRESH_INTERVAL} minutes)"
            refresh_chromium
            last_refresh=$SECONDS
        fi

        # Time-based rules need a trustworthy clock. A Pi without an RTC battery
        # boots with the time it last saved until NTP syncs.
        if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; then
            clock_warned=0
            local action
            while IFS= read -r action; do
                [ -n "$action" ] && execute_schedule_action "$action"
            done < <(due_schedule_actions)
        elif [ "$clock_warned" = 0 ]; then
            log "Clock not synchronised yet: schedule rules paused until it is"
            clock_warned=1
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main
