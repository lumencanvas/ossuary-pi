#!/usr/bin/env python3
"""
Ossuary config server (port 8081, and port 80 through captive-portal-proxy.py).

Serves the setup UI and its JSON API. Compatible with Python 3.9+ (Pi OS
Bullseye through Trixie).

Security model
--------------
The server runs as root, listens on the LAN and on the open "Ossuary-Setup"
hotspot, and can change what the kiosk runs. So every /api call (and the legacy
/startup and /connect) needs the device's SETUP CODE in the X-Ossuary-Code
header. The code is generated on first start and shown on the kiosk's own
screen (welcome page), in /etc/ossuary/setup-code, and in
/boot/firmware/ossuary-setup-code.txt. Only /api/status (no secrets) is open.

The welcome page is shown by the kiosk itself from http://localhost:8081, and
gets the code embedded so it can display it. That happens only for a direct
loopback request with a localhost Host header: not through the port-80 proxy,
and not for a DNS-rebinding page that resolves its own name to 127.0.0.1.

There is no Access-Control-Allow-Origin header, and the custom header forces a
CORS preflight that is never approved, so a web page open in a browser on the
LAN (or in the kiosk) cannot drive this API.
"""

import copy
import fcntl
import hmac
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import display_mode  # noqa: E402
import web_shell  # noqa: E402

CONFIG_FILE = "/etc/ossuary/config.json"
SETUP_CODE_FILE = "/etc/ossuary/setup-code"
BOOT_CODE_FILE = "/boot/firmware/ossuary-setup-code.txt"
UI_DIR = "/opt/ossuary/custom-ui"
SCRIPTS_DIR = "/opt/ossuary/scripts"
PROCESS_PID_FILE = "/run/ossuary/process.pid"
PENDING_WIFI_FILE = "/run/ossuary/pending-wifi"  # read by wifi-connect-manager.sh
HOTSPOT_PREFIX = "192.168.42."                     # wifi-connect's default portal subnet
CODE_HEADER = "X-Ossuary-Code"
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I/L
MIN_CODE_LEN = 8   # letters/digits; a chosen code must be at least this long
MAX_CODE_LEN = 32

CONFIG_LOCK = threading.RLock()
# Cross-process lock: connection-monitor.sh also rewrites config.json.
CONFIG_FLOCK = "/etc/ossuary/config.lock"


class _FileLock:
    """flock on CONFIG_FLOCK, re-entrant within this process.

    Always used while holding CONFIG_LOCK (so one thread at a time). It must
    be re-entrant: update_config() holds it while calling save_config(), and a
    second open()+flock() of the same file in one process blocks on the first
    (flock locks belong to the open file description), i.e. a deadlock.
    """
    depth = 0
    fd = None

    def __enter__(self):
        if _FileLock.depth == 0:
            os.makedirs(os.path.dirname(CONFIG_FLOCK), exist_ok=True)
            _FileLock.fd = os.open(CONFIG_FLOCK, os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(_FileLock.fd, fcntl.LOCK_EX)
        _FileLock.depth += 1
        return self

    def __exit__(self, *exc):
        _FileLock.depth -= 1
        if _FileLock.depth == 0:
            fcntl.flock(_FileLock.fd, fcntl.LOCK_UN)
            os.close(_FileLock.fd)
            _FileLock.fd = None

# Config schema for validation (basic type checking)
CONFIG_SCHEMA = {
    "startup_command": str,
    "saved_networks": list,
    "behaviors": dict,
    "schedule": dict,
    "profiles": dict,
    "active_profile": str,
    "version": int,
}

DEFAULT_CONFIG = {
    "version": 2,
    "startup_command": "",
    "active_profile": "custom",
    # Each preset the UI saves also stores its command here, so a schedule rule
    # can switch between them ("switch_profile").
    "profiles": {
        "lumencanvas": {"type": "lumencanvas", "name": "LumenCanvas", "command": ""},
        "webgpu_kiosk": {"type": "webgpu_kiosk", "name": "Web Kiosk", "command": ""},
        "custom": {"type": "custom", "name": "Custom Command", "command": ""},
    },
    "behaviors": {
        "on_connection_lost": {"action": "show_overlay", "timeout_seconds": 60},
        "on_connection_regained": {"action": "refresh_page", "delay_seconds": 3},
        "scheduled_refresh": {"enabled": False, "interval_minutes": 60},
        # process-manager.sh restarts the kiosk command when RAM + swap stays
        # above max_percent for about a minute.
        "memory_watchdog": {"enabled": True, "max_percent": 90},
    },
    "schedule": {
        "enabled": False,
        "timezone": "auto",
        # Rule: {"id", "name", "enabled", "trigger": {"type": "time", "time": "08:00",
        #        "days": ["mon", ...]}, "action": {"type": "refresh"|"restart"|"switch_profile",
        #        "profile": "lumencanvas"}}
        "rules": [],
    },
    # WiFi passwords are NOT kept here: NetworkManager stores them (root-only
    # files in /etc/NetworkManager/system-connections). This list only holds
    # notes and timestamps for the UI.
    "saved_networks": [],
    # Screen mode per output, applied at every boot (display_mode.py).
    "display": {"outputs": {}},
    # The panel's terminal. Off until the owner switches it on.
    "shell": {"enabled": False},
    # Named commands shown as buttons in the Control tab, run as the kiosk user.
    "custom_actions": [],
}

# Services a kiosk doesn't need. "Lean mode" disables them; turning it off
# enables them again. Nothing the kiosk relies on (network, .local, audio,
# USB drives, the desktop session) is in this list.
LEAN_UNITS = ['apt-daily.timer', 'apt-daily-upgrade.timer', 'man-db.timer',
              'ModemManager.service', 'rpcbind.service', 'rpcbind.socket', 'nfs-blkmap.service']
BLUETOOTH_UNITS = ['bluetooth.service']
DISPLAY_REVERT_SECONDS = 20

UI_PRESET_TO_PROFILE = {"lumencanvas": "lumencanvas", "webgpu": "webgpu_kiosk", "custom": "custom"}


def validate_config(config):
    """Validate config against schema. Returns (is_valid, errors)"""
    errors = []
    for key, expected_type in CONFIG_SCHEMA.items():
        if key in config and not isinstance(config[key], expected_type):
            errors.append(f"'{key}' should be {expected_type.__name__}, got {type(config[key]).__name__}")
    for i, network in enumerate(config.get('saved_networks') or []):
        if not isinstance(network, dict):
            errors.append(f"saved_networks[{i}] should be a dict")
        elif 'ssid' not in network:
            errors.append(f"saved_networks[{i}] missing required 'ssid' field")
    schedule = config.get('schedule')
    if isinstance(schedule, dict):
        if 'enabled' in schedule and not isinstance(schedule['enabled'], bool):
            errors.append("schedule.enabled should be boolean")
        if 'rules' in schedule and not isinstance(schedule['rules'], list):
            errors.append("schedule.rules should be a list")
    return (len(errors) == 0, errors)


def deep_merge(base, override):
    """Deep merge override into a COPY of base (never mutates either)."""
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def strip_secrets(config):
    """Remove any WiFi passwords (older versions stored them in plaintext)."""
    for key in ('saved_networks', 'wifi_networks'):
        for network in config.get(key) or []:
            if isinstance(network, dict):
                network.pop('password', None)
                network.pop('passphrase', None)
    return config


def load_config():
    with CONFIG_LOCK:
        config = copy.deepcopy(DEFAULT_CONFIG)
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, 'r') as f:
                    saved = json.load(f)
                if isinstance(saved, dict):
                    config = deep_merge(DEFAULT_CONFIG, saved)
                else:
                    print(f"[WARN] {CONFIG_FILE} is not a JSON object; using defaults", flush=True)
            except (OSError, ValueError) as e:
                print(f"[WARN] Could not read {CONFIG_FILE}: {e}", flush=True)
        if not isinstance(config.get('startup_command'), str):
            config['startup_command'] = ''
        return strip_secrets(config)


def save_config(config):
    """Atomic write (survives power loss)."""
    with CONFIG_LOCK, _FileLock():
        strip_secrets(config)
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        tmp_file = CONFIG_FILE + '.tmp'
        with open(tmp_file, 'w') as f:
            json.dump(config, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_file, 0o600)
        os.rename(tmp_file, CONFIG_FILE)


def update_config(mutator):
    """Read-modify-write under the lock, so concurrent requests can't lose updates."""
    with CONFIG_LOCK, _FileLock():
        config = load_config()
        result = mutator(config)
        save_config(config)
        return result


def migrate_config():
    """Scrub plaintext passwords left by older versions, once at startup."""
    if not os.path.exists(CONFIG_FILE):
        return
    try:
        with open(CONFIG_FILE) as f:
            raw = f.read()
        if '"password"' in raw or '"passphrase"' in raw:
            update_config(lambda c: None)
            print("[INFO] Removed stored WiFi passwords from config.json (NetworkManager keeps them)", flush=True)
    except OSError:
        pass


# --------------------------------------------------------------------------
# Setup code
# --------------------------------------------------------------------------

def normalize_code(code):
    return re.sub(r'[^A-Z0-9]', '', (code or '').upper())


def load_or_create_setup_code():
    try:
        with open(SETUP_CODE_FILE) as f:
            code = f.read().strip()
        if MIN_CODE_LEN <= len(normalize_code(code)) <= MAX_CODE_LEN:
            return code
    except OSError:
        pass
    code = random_setup_code()
    write_setup_code(code)
    print(f"[INFO] Generated a new setup code in {SETUP_CODE_FILE}", flush=True)
    return code


def random_setup_code():
    raw = ''.join(secrets.choice(CODE_ALPHABET) for _ in range(8))
    return f"{raw[:4]}-{raw[4:]}"


def write_setup_code(code):
    os.makedirs(os.path.dirname(SETUP_CODE_FILE), exist_ok=True)
    tmp = SETUP_CODE_FILE + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(code + '\n')
    os.replace(tmp, SETUP_CODE_FILE)


def publish_code_to_boot_partition(code):
    """Readable from any computer by putting the SD card in it."""
    if not os.path.isdir(os.path.dirname(BOOT_CODE_FILE)):
        return
    text = (f"Ossuary setup code: {code}\n\n"
            "Enter it in the Ossuary control panel (http://<hostname>.local:8081)\n"
            "It is also shown on the kiosk's screen while no display is configured.\n")
    try:
        with open(BOOT_CODE_FILE) as f:
            if f.read() == text:
                return
    except OSError:
        pass
    try:
        with open(BOOT_CODE_FILE, 'w') as f:
            f.write(text)
    except OSError as e:
        print(f"[WARN] Could not write {BOOT_CODE_FILE}: {e}", flush=True)


SETUP_CODE = None  # set in run_server()

# Screen modes being tried: output -> {mode, previous, timer, deadline}.
PENDING_MODES = {}
PENDING_MODE_LOCK = threading.Lock()


def revert_display_mode(output):
    """Put an output back to the mode it had before the one being tried."""
    with PENDING_MODE_LOCK:
        pending = PENDING_MODES.pop(output, None)
    if not pending:
        return False
    pending['timer'].cancel()
    try:
        display_mode.set_mode(kiosk_user(), output, pending['previous'])
        print(f"[display] {output} reverted to {pending['previous']}", flush=True)
        return True
    except Exception as e:
        print(f"[display] revert of {output} failed: {e}", flush=True)
        return False


class FailedAttempts:
    """Simple per-IP limiter: 10 wrong codes per 5 minutes, then 429."""
    WINDOW = 300
    LIMIT = 10

    def __init__(self):
        self.lock = threading.Lock()
        self.attempts = {}

    def blocked(self, ip):
        with self.lock:
            now = time.monotonic()
            recent = [t for t in self.attempts.get(ip, []) if now - t < self.WINDOW]
            self.attempts[ip] = recent
            return len(recent) >= self.LIMIT

    def record(self, ip):
        with self.lock:
            self.attempts.setdefault(ip, []).append(time.monotonic())


FAILED = FailedAttempts()


# --------------------------------------------------------------------------
# Kiosk user session helpers (mirror scripts/ossuary-lib.sh)
# --------------------------------------------------------------------------

def memory_used_percent():
    """RAM + swap in use, as process-manager.sh's watchdog measures it."""
    info = {}
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                k, v = line.split(':', 1)
                info[k] = int(v.split()[0])
    except (OSError, ValueError):
        return None
    total = info.get('MemTotal', 0) + info.get('SwapTotal', 0)
    free = info.get('MemAvailable', 0) + info.get('SwapFree', 0)
    return int(100 - free * 100 / total) if total else None


def kiosk_user():
    try:
        out = subprocess.run(
            ['bash', '-c', f'source {SCRIPTS_DIR}/ossuary-lib.sh && ossuary_kiosk_user'],
            capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def session_env(user):
    """Environment that puts a command into the kiosk user's graphical session."""
    import pwd
    pw = pwd.getpwnam(user)
    runtime = f"/run/user/{pw.pw_uid}"
    env = {
        'HOME': pw.pw_dir, 'USER': user, 'LOGNAME': user,
        'PATH': '/usr/local/bin:/usr/bin:/bin',
        'XDG_RUNTIME_DIR': runtime,
        'DBUS_SESSION_BUS_ADDRESS': f'unix:path={runtime}/bus',
    }
    sockets = []
    try:
        sockets = sorted(n for n in os.listdir(runtime) if re.fullmatch(r'wayland-\d+', n))
    except OSError:
        pass
    if sockets:
        env['WAYLAND_DISPLAY'] = sockets[0]
        env['XDG_SESSION_TYPE'] = 'wayland'
    else:
        env['DISPLAY'] = ':0'
        env['XAUTHORITY'] = os.path.join(pw.pw_dir, '.Xauthority')
    return env


def run_as_kiosk(args, timeout=10):
    """Run a command as the kiosk user inside their display session."""
    user = kiosk_user()
    if not user:
        raise RuntimeError('No kiosk user found')
    env = session_env(user)
    cmd = ['runuser', '-u', user, '--', 'env', '-i'] + [f'{k}={v}' for k, v in env.items()] + args
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


def signal_process_manager(sig=signal.SIGHUP):
    try:
        with open(PROCESS_PID_FILE) as f:
            os.kill(int(f.read().strip()), sig)
        return True
    except (OSError, ValueError):
        return False


def nm_wifi_connections():
    """[(uuid, name, ssid, mode)] for every saved wifi profile."""
    result = []
    try:
        out = subprocess.run(['nmcli', '-t', '-f', 'TYPE,UUID', 'connection', 'show'],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return result
    for line in out.stdout.splitlines():
        ctype, _, uuid = line.partition(':')
        if ctype != '802-11-wireless' or not uuid:
            continue
        info = subprocess.run(
            ['nmcli', '-g', 'connection.id,802-11-wireless.ssid,802-11-wireless.mode',
             'connection', 'show', uuid], capture_output=True, text=True, timeout=5)
        fields = info.stdout.split('\n')
        if len(fields) >= 3:
            result.append((uuid, fields[0], fields[1], fields[2]))
    return result


class ConfigHandler(SimpleHTTPRequestHandler):
    server_version = "Ossuary"
    sys_version = ""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=UI_DIR, **kwargs)

    def log_message(self, fmt, *args):
        print(f"{self.client_ip()} {fmt % args}", flush=True)

    # ---------------------------------------------------------------- helpers

    def client_ip(self):
        # Trust X-Forwarded-For only from our own port-80 proxy (loopback);
        # anyone talking to :8081 directly could otherwise rotate it to dodge
        # the setup-code rate limit.
        peer = self.client_address[0]
        forwarded = self.headers.get('X-Forwarded-For')
        if forwarded and peer in ('127.0.0.1', '::1'):
            return forwarded.split(',')[0].strip()
        return peer

    def is_local_kiosk(self):
        """A direct loopback request from the kiosk's own browser."""
        if self.client_address[0] not in ('127.0.0.1', '::1'):
            return False
        if self.headers.get('X-Forwarded-For'):
            return False  # came through the port-80 proxy
        host = (self.headers.get('Host') or '').rsplit(':', 1)[0].strip('[]').lower()
        return host in ('localhost', '127.0.0.1', '::1')

    def send_json_response(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        super().end_headers()

    def authorized(self):
        ip = self.client_ip()
        if FAILED.blocked(ip):
            self.send_json_response({'error': 'Too many wrong setup codes. Try again in a few minutes.'}, 429)
            return False
        given = normalize_code(self.headers.get(CODE_HEADER))
        if given and hmac.compare_digest(given, normalize_code(SETUP_CODE)):
            return True
        if given:
            FAILED.record(ip)
        self.send_json_response({'error': 'Setup code required', 'code_required': True}, 401)
        return False

    def read_json_body(self):
        """Parse a JSON body. Returns (data, error_sent)."""
        ctype = (self.headers.get('Content-Type') or '').split(';')[0].strip().lower()
        try:
            length = int(self.headers.get('Content-Length', 0))
        except ValueError:
            self.send_json_response({'error': 'Bad Content-Length'}, 400)
            return None, True
        if length < 0 or length > 1048576:
            self.send_json_response({'error': 'Bad request size'}, 413)
            return None, True
        raw = self.rfile.read(length) if length else b''
        if not raw:
            return {}, False
        if ctype != 'application/json':
            self.send_json_response({'error': 'Content-Type must be application/json'}, 415)
            return None, True
        try:
            data = json.loads(raw)
        except ValueError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
            return None, True
        if not isinstance(data, dict):
            self.send_json_response({'error': 'Expected a JSON object'}, 400)
            return None, True
        return data, False

    # ---------------------------------------------------------------- routing

    GET_ROUTES = {
        '/api/startup': 'handle_get_startup',
        '/api/services': 'handle_get_services',
        '/api/behaviors': 'handle_get_behaviors',
        '/api/profiles': 'handle_get_profiles',
        '/api/config': 'handle_get_config',
        '/api/system/info': 'handle_system_info',
        '/api/schedule': 'handle_get_schedule',
        '/api/timezone': 'handle_get_timezone',
        '/api/saved-networks': 'handle_get_saved_networks',
        '/api/nearby-networks': 'handle_get_nearby_networks',
        '/api/screenshot': 'handle_screenshot',
        '/api/display/power': 'handle_get_display_power',
        '/api/process/status': 'handle_get_process_status',
        '/api/auth/check': 'handle_auth_check',
        '/api/wifi-country': 'handle_get_wifi_country',
        '/api/hostname': 'handle_get_hostname',
        '/api/display/modes': 'handle_get_display_modes',
        '/api/shell/settings': 'handle_get_shell_settings',
        '/api/actions': 'handle_get_actions',
        '/api/system/lean': 'handle_get_lean',
        '/api/setup-code': 'handle_get_setup_code',
        '/startup': 'handle_get_startup',
        '/networks': 'handle_get_nearby_networks_compat',
    }

    POST_ROUTES = {
        '/api/startup': 'handle_save_startup',
        '/startup': 'handle_save_startup',
        '/api/service-control': 'handle_service_control',
        '/api/behaviors': 'handle_save_behaviors',
        '/api/process/refresh': 'handle_process_refresh',
        '/api/process/restart': 'handle_process_restart',
        '/api/process/stop': 'handle_process_stop',
        '/api/process/start': 'handle_process_start',
        '/api/startup/clear': 'handle_clear_startup',
        '/api/system/reboot': 'handle_system_reboot',
        '/api/schedule': 'handle_save_schedule',
        '/api/timezone': 'handle_set_timezone',
        '/api/saved-networks': 'handle_save_network',
        '/api/saved-networks/delete': 'handle_delete_network',
        '/api/saved-networks/connect': 'handle_connect_saved_network',
        '/api/profiles/activate': 'handle_set_active_profile',
        '/api/display/power': 'handle_set_display_power',
        '/api/wifi-country': 'handle_set_wifi_country',
        '/api/hostname': 'handle_set_hostname',
        '/api/display/mode': 'handle_try_display_mode',
        '/api/display/mode/keep': 'handle_keep_display_mode',
        '/api/display/mode/revert': 'handle_revert_display_mode',
        '/api/shell/settings': 'handle_set_shell_settings',
        '/api/actions': 'handle_save_actions',
        '/api/actions/run': 'handle_run_action',
        '/api/system/lean': 'handle_set_lean',
        '/api/setup-code': 'handle_set_setup_code',
        '/connect': 'handle_wifi_connect',
    }

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ('/', '/index.html'):
            self.path = '/index.html'
            return super().do_GET()
        if path == '/welcome.html':
            return self.serve_welcome()
        if path == '/api/status' or path == '/status':
            return self.handle_status()
        if path == '/api/shell':
            return self.handle_shell()
        if path.startswith('/api/logs/'):
            if self.authorized():
                self.handle_get_logs(path[len('/api/logs/'):])
            return
        handler = self.GET_ROUTES.get(path)
        if handler:
            if self.authorized():
                getattr(self, handler)()
            return
        if path.startswith('/api/'):
            return self.send_json_response({'error': 'Not found'}, 404)
        return super().do_GET()  # static files from UI_DIR

    def do_HEAD(self):
        path = urlparse(self.path).path
        if path.startswith('/api/') or path in self.GET_ROUTES:
            self.send_response(405)
            self.end_headers()
            return
        return super().do_HEAD()

    def from_setup_hotspot(self):
        """A phone on the open Ossuary-Setup hotspot, while the hotspot is up."""
        if not self.client_ip().startswith(HOTSPOT_PREFIX):
            return False
        return subprocess.run(['systemctl', 'is-active', '--quiet', 'wifi-connect'], timeout=3).returncode == 0

    def do_POST(self):
        path = urlparse(self.path).path
        handler = self.POST_ROUTES.get(path)
        if not handler:
            return self.send_json_response({'error': 'Not found'}, 404)
        # Choosing the WiFi network from the setup hotspot needs no code, like
        # wifi-connect's own portal: the hotspot only exists while the kiosk
        # is offline, and the person setting it up may not have the code yet.
        hotspot_join = path == '/connect' and self.from_setup_hotspot()
        if not hotspot_join and not self.authorized():
            return
        data, error_sent = self.read_json_body()
        if error_sent:
            return
        getattr(self, handler)(data)

    def do_OPTIONS(self):
        # No CORS: cross-origin pages get no Access-Control-Allow-* headers.
        self.send_response(204)
        self.send_header('Allow', 'GET, POST')
        self.end_headers()

    # ---------------------------------------------------------------- pages

    def serve_welcome(self):
        try:
            with open(os.path.join(UI_DIR, 'welcome.html'), 'rb') as f:
                page = f.read()
        except OSError:
            return self.send_error(404)
        code = SETUP_CODE if self.is_local_kiosk() else ''
        page = page.replace(b'__OSSUARY_SETUP_CODE__', code.encode())
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(page)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(page)

    # ---------------------------------------------------------------- status

    def handle_status(self):
        """Public: no secrets. Used by the welcome page and the UI before login."""
        ssid = ''
        connection = 'offline'
        ip = ''
        try:
            out = subprocess.run(['nmcli', '-t', '-f', 'TYPE,STATE,CON-UUID', 'device', 'status'],
                                 capture_output=True, text=True, timeout=3).stdout
            for line in out.splitlines():
                dtype, state, uuid = (line.split(':') + ['', '', ''])[:3]
                if not state.startswith('connected'):
                    continue
                if dtype == 'ethernet' and connection == 'offline':
                    connection = 'ethernet'
                elif dtype == 'wifi':
                    info = subprocess.run(
                        ['nmcli', '-g', '802-11-wireless.mode,802-11-wireless.ssid', 'connection', 'show', uuid],
                        capture_output=True, text=True, timeout=3).stdout.split('\n')
                    if info and info[0] != 'ap':
                        connection = 'wifi'
                        ssid = info[1] if len(info) > 1 else ''
        except (OSError, subprocess.TimeoutExpired):
            pass
        try:
            ap_mode = subprocess.run(['systemctl', 'is-active', 'wifi-connect'],
                                     capture_output=True, text=True, timeout=2).stdout.strip() == 'active'
        except (OSError, subprocess.TimeoutExpired):
            ap_mode = False
        try:
            ips = subprocess.run(['hostname', '-I'], capture_output=True, text=True, timeout=2).stdout.split()
            ip = next((a for a in ips if a != '192.168.42.1' and ':' not in a), '')
        except (OSError, subprocess.TimeoutExpired):
            pass
        config = load_config()
        self.send_json_response({
            'connection': connection,            # "wifi" | "ethernet" | "offline"
            'wifi_connected': connection == 'wifi',
            'ssid': ssid,
            'ap_mode': ap_mode,
            'hostname': socket.gethostname(),
            'ip': ip,
            'configured': bool((config.get('startup_command') or '').strip()),
        })

    def handle_auth_check(self):
        self.send_json_response({'ok': True})

    def handle_get_startup(self):
        self.send_json_response({'command': load_config().get('startup_command', '')})

    def handle_save_startup(self, data):
        command = (data.get('command') or '').strip()
        if len(command) > 4096:
            return self.send_json_response({'error': 'Command too long (max 4096 characters)'}, 400)
        preset = data.get('preset')

        def mutate(config):
            config['startup_command'] = command
            profile = UI_PRESET_TO_PROFILE.get(preset)
            if profile:
                config.setdefault('profiles', {}).setdefault(profile, {})['command'] = command
                config['active_profile'] = profile
        update_config(mutate)
        reloaded = signal_process_manager()
        self.send_json_response({'success': True, 'config_reloaded': reloaded})

    def handle_get_services(self):
        services = {}
        for service in ['wifi-connect', 'wifi-connect-manager', 'captive-portal-proxy',
                        'ossuary-startup', 'ossuary-web', 'ossuary-connection-monitor']:
            services[service] = subprocess.run(['systemctl', 'is-active', service],
                                               capture_output=True, text=True, timeout=2).stdout.strip()
        self.send_json_response(services)

    def handle_service_control(self, data):
        service = data.get('service')
        action = data.get('action')
        if service not in ['wifi-connect', 'wifi-connect-manager', 'ossuary-startup', 'ossuary-web']:
            return self.send_json_response({'error': 'Invalid service'}, 400)
        if action not in ['start', 'stop', 'restart']:
            return self.send_json_response({'error': 'Invalid action'}, 400)
        result = subprocess.run(['systemctl', action, service], capture_output=True, text=True, timeout=20)
        status = subprocess.run(['systemctl', 'is-active', service], capture_output=True, text=True, timeout=2)
        self.send_json_response({
            'success': result.returncode == 0, 'service': service, 'action': action,
            'new_status': status.stdout.strip(), 'output': result.stdout + result.stderr,
        })

    def handle_get_logs(self, log_type):
        query = parse_qs(urlparse(self.path).query)
        try:
            lines = min(max(int(query.get('lines', ['50'])[0]), 10), 1000)
        except ValueError:
            lines = 50
        service_map = {
            'ossuary-process': {'unit': 'ossuary-startup', 'file': '/var/log/ossuary-process.log'},
            'ossuary-web': {'unit': 'ossuary-web'},
            'ossuary-connection-monitor': {'unit': 'ossuary-connection-monitor'},
            'wifi-connect': {'units': ['wifi-connect-manager', 'wifi-connect']},
            'captive-portal-proxy': {'unit': 'captive-portal-proxy'},
            # Legacy names
            'process': {'unit': 'ossuary-startup', 'file': '/var/log/ossuary-process.log'},
            'wifi': {'units': ['wifi-connect-manager', 'wifi-connect']},
            'system': {'units': ['ossuary-startup', 'ossuary-web']},
        }
        cfg = service_map.get(log_type)
        if not cfg:
            return self.send_json_response({'error': f'Unknown service: {log_type}'}, 400)
        logs = ''
        if 'file' in cfg and os.path.exists(cfg['file']):
            logs = subprocess.run(['tail', '-n', str(lines), cfg['file']],
                                  capture_output=True, text=True, timeout=5).stdout
        if not logs:
            cmd = ['journalctl', '-n', str(lines), '--no-pager', '-o', 'short-iso']
            for unit in cfg.get('units', [cfg.get('unit')]):
                cmd += ['-u', unit]
            logs = subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout \
                or f"No logs available for {log_type}"
        self.send_json_response({'logs': logs})

    def handle_get_behaviors(self):
        self.send_json_response(load_config().get('behaviors', {}))

    def handle_save_behaviors(self, data):
        allowed = {'on_connection_lost', 'on_connection_regained', 'scheduled_refresh', 'memory_watchdog'}
        for key, value in data.items():
            if key not in allowed or not isinstance(value, dict):
                return self.send_json_response({'error': f'Unknown or invalid behavior: {key}'}, 400)
            for num in ('delay_seconds', 'interval_minutes', 'timeout_seconds'):
                if num in value and not (isinstance(value[num], int) and 0 <= value[num] <= 10080):
                    return self.send_json_response({'error': f'{key}.{num} must be a whole number'}, 400)
            if 'enabled' in value and not isinstance(value['enabled'], bool):
                return self.send_json_response({'error': f'{key}.enabled must be true or false'}, 400)
            if key == 'memory_watchdog' and 'max_percent' in value and not (
                    isinstance(value['max_percent'], int) and not isinstance(value['max_percent'], bool)
                    and 50 <= value['max_percent'] <= 98):
                return self.send_json_response({'error': 'memory_watchdog.max_percent must be 50-98'}, 400)
        update_config(lambda c: c.setdefault('behaviors', {}).update(data))
        self._signal_connection_monitor()
        self.send_json_response({'success': True})

    def _signal_connection_monitor(self):
        subprocess.run(['systemctl', 'kill', '-s', 'HUP', '--kill-whom=main', 'ossuary-connection-monitor'],
                       capture_output=True, timeout=5)

    def handle_get_profiles(self):
        config = load_config()
        self.send_json_response({'profiles': config.get('profiles', {}),
                                 'active': config.get('active_profile', 'custom')})

    def handle_set_active_profile(self, data):
        name = (data.get('profile') or '').strip()
        config = load_config()
        profile = config.get('profiles', {}).get(name)
        if not profile:
            return self.send_json_response({'error': f'Unknown profile: {name}'}, 404)
        if not (profile.get('command') or '').strip():
            return self.send_json_response({'error': f'Profile "{name}" has no saved command yet'}, 400)

        def mutate(c):
            c['active_profile'] = name
            c['startup_command'] = profile['command']
        update_config(mutate)
        self.send_json_response({'success': True, 'active_profile': name,
                                 'process_reloaded': signal_process_manager()})

    def handle_get_config(self):
        self.send_json_response(load_config())

    def handle_system_info(self):
        hostname = socket.gethostname()
        ips = subprocess.run(['hostname', '-I'], capture_output=True, text=True, timeout=2).stdout.split()
        ip = next((a for a in ips if a != '192.168.42.1' and ':' not in a), '')
        self.send_json_response({
            'hostname': hostname, 'hostname_local': f"{hostname}.local", 'ip': ip,
            'config_url': f"http://{hostname}.local:8081",
            'config_url_ip': f"http://{ip}:8081" if ip else None,
            'memory_used_percent': memory_used_percent(),
        })

    def handle_get_setup_code(self):
        self.send_json_response({'code': SETUP_CODE})

    def handle_set_setup_code(self, data):
        """Choose a code ({'code': ...}) or roll a new random one ({'random': true})."""
        global SETUP_CODE
        if data.get('random'):
            code = random_setup_code()
        else:
            code = re.sub(r'\s+', ' ', str(data.get('code', ''))).strip().upper()
            n = len(normalize_code(code))
            if n < MIN_CODE_LEN or n > MAX_CODE_LEN or len(code) > 64:
                return self.send_json_response(
                    {'error': f'Use {MIN_CODE_LEN}-{MAX_CODE_LEN} letters or numbers (dashes and spaces are ignored)'}, 400)
        try:
            write_setup_code(code)
        except OSError as e:
            return self.send_json_response({'error': f'Could not save the code: {e}'}, 500)
        SETUP_CODE = code
        publish_code_to_boot_partition(code)
        self.send_json_response({'success': True, 'code': code})

    # ---------------------------------------------------------------- screen mode

    def handle_get_display_modes(self):
        try:
            outputs = display_mode.list_outputs(kiosk_user())
        except Exception as e:
            return self.send_json_response({'error': str(e)}, 503)
        with PENDING_MODE_LOCK:
            pending = {k: {'mode': v['mode'], 'seconds_left': max(0, int(v['deadline'] - time.monotonic()))}
                       for k, v in PENDING_MODES.items()}
        self.send_json_response({'outputs': outputs, 'saved': display_mode.saved_modes(CONFIG_FILE),
                                 'pending': pending})

    def handle_try_display_mode(self, data):
        """Switch now; revert in DISPLAY_REVERT_SECONDS unless kept."""
        output, mode = data.get('output'), data.get('mode')
        user = kiosk_user()
        try:
            current = next((o for o in display_mode.list_outputs(user) if o['name'] == output), None)
            if not current:
                return self.send_json_response({'error': 'No such output'}, 404)
            if mode != 'auto' and mode not in {m['mode'] for m in current['modes']}:
                return self.send_json_response({'error': 'That screen does not offer this mode'}, 400)
            with PENDING_MODE_LOCK:
                previous = PENDING_MODES.pop(output, {}).get('previous') or current['current'] or 'auto'
                display_mode.set_mode(user, output, mode)
                timer = threading.Timer(DISPLAY_REVERT_SECONDS, revert_display_mode, args=(output,))
                timer.daemon = True
                PENDING_MODES[output] = {'mode': mode, 'previous': previous, 'timer': timer,
                                         'deadline': time.monotonic() + DISPLAY_REVERT_SECONDS}
                timer.start()
        except (ValueError, RuntimeError) as e:
            return self.send_json_response({'error': str(e)}, 400)
        self.send_json_response({'success': True, 'pending': True, 'revert_in': DISPLAY_REVERT_SECONDS})

    def handle_keep_display_mode(self, data):
        output = data.get('output')
        with PENDING_MODE_LOCK:
            pending = PENDING_MODES.pop(output, None)
        if not pending:
            return self.send_json_response({'error': 'Nothing to keep (it may already have reverted)'}, 409)
        pending['timer'].cancel()
        update_config(lambda c: c.setdefault('display', {}).setdefault('outputs', {}).update({output: pending['mode']}))
        self.send_json_response({'success': True, 'mode': pending['mode']})

    def handle_revert_display_mode(self, data):
        ok = revert_display_mode(data.get('output'))
        self.send_json_response({'success': ok})

    # ---------------------------------------------------------------- shell

    def handle_get_shell_settings(self):
        self.send_json_response({'enabled': bool(load_config().get('shell', {}).get('enabled'))})

    def handle_set_shell_settings(self, data):
        enabled = data.get('enabled')
        if not isinstance(enabled, bool):
            return self.send_json_response({'error': 'enabled must be true or false'}, 400)
        update_config(lambda c: c.setdefault('shell', {}).update({'enabled': enabled}))
        self.send_json_response({'success': True, 'enabled': enabled})

    def handle_shell(self):
        """WebSocket upgrade for the panel terminal; the code arrives in the first message."""
        if not load_config().get('shell', {}).get('enabled'):
            return self.send_json_response({'error': 'The shell is switched off in the Control tab'}, 403)
        key = self.headers.get('Sec-WebSocket-Key')
        if (self.headers.get('Upgrade') or '').lower() != 'websocket' or not key:
            return self.send_json_response({'error': 'WebSocket upgrade required'}, 400)
        # Only the panel's own pages may open it (hostname match, any port).
        origin_host = urlparse(self.headers.get('Origin') or '').hostname
        host = (self.headers.get('Host') or '').rsplit(':', 1)[0].strip('[]').lower()
        if not origin_host or origin_host.lower() != host:
            return self.send_json_response({'error': 'Cross-origin shell refused'}, 403)
        user = kiosk_user()
        if not user:
            return self.send_json_response({'error': 'No kiosk user'}, 503)
        ip = self.client_ip()

        def check_code(code):
            if FAILED.blocked(ip):
                return False, 'Too many wrong setup codes. Try again in a few minutes.'
            given = normalize_code(code)
            if given and hmac.compare_digest(given, normalize_code(SETUP_CODE)):
                return True, ''
            FAILED.record(ip)
            return False, 'Setup code required'

        self.send_response(101, 'Switching Protocols')
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', web_shell.accept_key(key))
        super().end_headers()
        self.wfile.flush()
        self.close_connection = True
        print(f"[shell] opened from {ip}", flush=True)
        web_shell.run_session(self.connection, self.rfile, check_code, user, session_env(user))
        print(f"[shell] closed from {ip}", flush=True)

    # ---------------------------------------------------------------- custom actions

    def handle_get_actions(self):
        self.send_json_response({'actions': load_config().get('custom_actions', [])})

    def handle_save_actions(self, data):
        actions = data.get('actions')
        if not isinstance(actions, list) or len(actions) > 30:
            return self.send_json_response({'error': 'actions must be a list (up to 30)'}, 400)
        clean = []
        for a in actions:
            if not isinstance(a, dict):
                return self.send_json_response({'error': 'Each action needs a name and a command'}, 400)
            name, command = str(a.get('name', '')).strip(), str(a.get('command', '')).strip()
            if not name or not command or len(name) > 40 or len(command) > 2000:
                return self.send_json_response({'error': 'Each action needs a name (up to 40) and a command'}, 400)
            action_id = str(a.get('id') or '') or secrets.token_hex(4)
            if not re.fullmatch(r'[a-f0-9]{8}', action_id):
                action_id = secrets.token_hex(4)
            clean.append({'id': action_id, 'name': name, 'command': command})
        update_config(lambda c: c.update({'custom_actions': clean}))
        self.send_json_response({'success': True, 'actions': clean})

    def handle_run_action(self, data):
        action = next((a for a in load_config().get('custom_actions', []) if a.get('id') == data.get('id')), None)
        if not action:
            return self.send_json_response({'error': 'No such action'}, 404)
        try:
            r = run_as_kiosk(['bash', '-lc', action['command']], timeout=60)
        except subprocess.TimeoutExpired:
            return self.send_json_response({'success': False, 'output': 'Timed out after 60 s'})
        except RuntimeError as e:
            return self.send_json_response({'error': str(e)}, 503)
        out = (r.stdout + r.stderr).decode(errors='replace')[-8000:]
        self.send_json_response({'success': r.returncode == 0, 'exit_code': r.returncode, 'output': out})

    # ---------------------------------------------------------------- lean mode

    def handle_get_lean(self):
        def enabled(unit):
            r = subprocess.run(['systemctl', 'is-enabled', unit], capture_output=True, text=True, timeout=5)
            return r.stdout.strip()
        lean = {u: enabled(u) for u in LEAN_UNITS}
        bt = {u: enabled(u) for u in BLUETOOTH_UNITS}
        present = [s for s in lean.values() if s not in ('', 'not-found')]
        self.send_json_response({
            'lean': bool(present) and all(s in ('disabled', 'masked') for s in present),
            'bluetooth': any(s == 'enabled' for s in bt.values()),
            'units': {**lean, **bt},
        })

    def handle_set_lean(self, data):
        results = {}

        def switch(units, on):
            for u in units:
                r = subprocess.run(['systemctl', 'enable' if on else 'disable', '--now', u],
                                   capture_output=True, text=True, timeout=60)
                results[u] = 'ok' if r.returncode == 0 else (r.stderr.strip() or 'failed')

        if 'lean' in data:
            if not isinstance(data['lean'], bool):
                return self.send_json_response({'error': 'lean must be true or false'}, 400)
            switch(LEAN_UNITS, not data['lean'])
        if 'bluetooth' in data:
            if not isinstance(data['bluetooth'], bool):
                return self.send_json_response({'error': 'bluetooth must be true or false'}, 400)
            switch(BLUETOOTH_UNITS, data['bluetooth'])
        self.send_json_response({'success': True, 'results': results})

    def handle_get_hostname(self):
        self.send_json_response({'hostname': socket.gethostname()})

    def handle_set_hostname(self, data):
        """Rename the device. Takes effect now (and for .local) without a reboot."""
        name = str(data.get('hostname', '')).strip().lower()
        if not re.fullmatch(r'[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?', name):
            return self.send_json_response(
                {'error': 'Use 1-63 letters, numbers or hyphens, not starting or ending with a hyphen'}, 400)
        old = socket.gethostname()
        if name == old:
            return self.send_json_response({'success': True, 'hostname': name, 'changed': False})
        r = subprocess.run(['hostnamectl', 'set-hostname', name], capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            return self.send_json_response({'error': r.stderr.strip() or 'Could not set hostname'}, 400)
        # Keep sudo and local lookups resolving the new name.
        try:
            with open('/etc/hosts') as f:
                lines = f.read().splitlines()
            out, found = [], False
            for line in lines:
                if line.startswith('127.0.1.1'):
                    out.append(f'127.0.1.1\t{name}')
                    found = True
                else:
                    out.append(line)
            if not found:
                out.append(f'127.0.1.1\t{name}')
            tmp = '/etc/hosts.ossuary-tmp'
            with open(tmp, 'w') as f:
                f.write('\n'.join(out) + '\n')
            os.chmod(tmp, 0o644)
            os.replace(tmp, '/etc/hosts')
        except OSError as e:
            print(f'[hostname] /etc/hosts not updated: {e}')
        # Announce the new .local name right away.
        subprocess.run(['systemctl', 'try-restart', 'avahi-daemon'], capture_output=True, timeout=15)
        self.send_json_response({'success': True, 'hostname': name, 'changed': True,
                                 'config_url': f'http://{name}.local:8081'})

    # ---------------------------------------------------------------- process

    def handle_process_refresh(self, data):
        """Reload the page in place; restart the browser only if that fails."""
        result = subprocess.run(['python3', os.path.join(SCRIPTS_DIR, 'cdp-reload.py')],
                                capture_output=True, text=True, timeout=20)
        if result.returncode == 0:
            return self.send_json_response({'success': True, 'message': 'Page reloaded'})
        if signal_process_manager():
            return self.send_json_response({'success': True, 'message': 'Page could not be reloaded in place; restarting the browser'})
        self.send_json_response({'error': 'Nothing is running'}, 404)

    def handle_process_restart(self, data):
        result = subprocess.run(['systemctl', 'restart', 'ossuary-startup'], capture_output=True, text=True, timeout=30)
        self.send_json_response({'success': result.returncode == 0,
                                 'message': 'Restarted' if result.returncode == 0 else 'Failed to restart',
                                 'output': result.stdout + result.stderr})

    def handle_process_stop(self, data):
        result = subprocess.run(['systemctl', 'stop', 'ossuary-startup'], capture_output=True, text=True, timeout=30)
        self.send_json_response({'success': result.returncode == 0,
                                 'message': 'Stopped until the next Start or reboot' if result.returncode == 0 else 'Failed to stop',
                                 'output': result.stdout + result.stderr})

    def handle_process_start(self, data):
        result = subprocess.run(['systemctl', 'start', 'ossuary-startup'], capture_output=True, text=True, timeout=30)
        self.send_json_response({'success': result.returncode == 0,
                                 'message': 'Started' if result.returncode == 0 else 'Failed to start',
                                 'output': result.stdout + result.stderr})

    def handle_get_process_status(self):
        result = subprocess.run(['systemctl', 'show', 'ossuary-startup', '--property=ActiveState,SubState'],
                                capture_output=True, text=True, timeout=5)
        props = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        state = props.get('ActiveState', 'unknown')
        child_pid = None
        try:
            with open(PROCESS_PID_FILE + '.child') as f:
                child_pid = int(f.read().strip())
            os.kill(child_pid, 0)
        except (OSError, ValueError):
            child_pid = None
        command = load_config().get('startup_command', '')
        if state == 'active' and child_pid:
            display = 'running'
        elif state == 'active' and not command:
            display = 'waiting for a display to be configured'
        elif state == 'active':
            display = 'starting'
        else:
            display = 'stopped' if state == 'inactive' else state
        self.send_json_response({'state': display, 'service_state': state, 'substate': props.get('SubState', ''),
                                 'command': command, 'child_pid': child_pid, 'running': display == 'running'})

    def handle_clear_startup(self, data):
        update_config(lambda c: c.update({'startup_command': ''}))
        signal_process_manager()
        self.send_json_response({'success': True, 'message': 'Startup command cleared'})

    def handle_system_reboot(self, data):
        self.send_json_response({'success': True, 'message': 'Rebooting in 3 seconds...'})
        subprocess.Popen(['/bin/bash', '-c', 'sleep 3 && systemctl reboot'])

    # ---------------------------------------------------------------- display

    def handle_screenshot(self):
        path = '/tmp/ossuary-screenshot.png'
        try:
            os.unlink(path)
        except OSError:
            pass
        user = kiosk_user()
        attempts = []
        if user:
            out_path = f'/tmp/ossuary-shot-{user}.png'
            attempts = [(['grim', out_path], out_path), (['scrot', '-o', out_path], out_path)]
        data = None
        for args, out_path in attempts:
            try:
                if run_as_kiosk(args, timeout=15).returncode == 0 and os.path.exists(out_path):
                    with open(out_path, 'rb') as f:
                        data = f.read()
                    os.unlink(out_path)
                    break
            except (OSError, subprocess.TimeoutExpired, RuntimeError):
                continue
        if not data:
            return self.send_json_response({'error': 'Screenshot failed (needs grim on Wayland or scrot on X11)'}, 500)
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def _wlr_outputs(self):
        try:
            out = run_as_kiosk(['wlr-randr', '--json'], timeout=5)
            if out.returncode == 0:
                return json.loads(out.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired, RuntimeError):
            pass
        return None

    def handle_get_display_power(self):
        outputs = self._wlr_outputs()
        if outputs is not None:
            on = any(o.get('enabled') for o in outputs)
            return self.send_json_response({'power': 'on' if on else 'off',
                                            'outputs': [o.get('name') for o in outputs]})
        try:
            r = subprocess.run(['vcgencmd', 'display_power'], capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                return self.send_json_response({'power': 'on' if '=1' in r.stdout else 'off'})
        except (OSError, subprocess.TimeoutExpired):
            pass
        self.send_json_response({'error': 'Display power control is not available', 'power': 'unknown'}, 501)

    def handle_set_display_power(self, data):
        power = str(data.get('power', '')).lower()
        if power not in ('on', 'off', '1', '0'):
            return self.send_json_response({'error': 'power must be "on" or "off"'}, 400)
        on = power in ('on', '1')
        outputs = self._wlr_outputs()
        if outputs:
            # Wayland (labwc, Pi OS Bookworm+): vcgencmd display_power does not work under KMS.
            ok = True
            for o in outputs:
                r = run_as_kiosk(['wlr-randr', '--output', o['name'], '--on' if on else '--off'], timeout=10)
                ok = ok and r.returncode == 0
            if ok:
                return self.send_json_response({'success': True, 'power': 'on' if on else 'off'})
        try:
            r = subprocess.run(['vcgencmd', 'display_power', '1' if on else '0'],
                               capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                return self.send_json_response({'success': True, 'power': 'on' if on else 'off'})
        except (OSError, subprocess.TimeoutExpired):
            pass
        self.send_json_response({'error': 'Display power control is not available on this system'}, 501)

    # ---------------------------------------------------------------- schedule

    def handle_get_schedule(self):
        self.send_json_response(load_config().get('schedule', {}))

    def handle_save_schedule(self, data):
        valid, errors = validate_config({'schedule': data})
        if not valid:
            return self.send_json_response({'error': '; '.join(errors)}, 400)
        # Merge: the timezone lives in the same block and has its own endpoint.
        update_config(lambda c: c.setdefault('schedule', {}).update(
            {k: data[k] for k in ('enabled', 'rules') if k in data}))
        self._signal_connection_monitor()
        self.send_json_response({'success': True})

    def handle_get_timezone(self):
        result = subprocess.run(['timedatectl', 'show', '--property=Timezone', '--property=NTPSynchronized'],
                                capture_output=True, text=True, timeout=5)
        props = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        system_tz = props.get('Timezone', 'UTC')
        config_tz = load_config().get('schedule', {}).get('timezone', 'auto')
        self.send_json_response({
            'system_timezone': system_tz,
            'config_timezone': config_tz,
            'effective_timezone': system_tz if config_tz == 'auto' else config_tz,
            'clock_synced': props.get('NTPSynchronized') == 'yes',
            'available_timezones': [
                'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
                'America/Phoenix', 'America/Anchorage', 'Pacific/Honolulu',
                'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Moscow',
                'Asia/Tokyo', 'Asia/Shanghai', 'Asia/Singapore', 'Asia/Dubai',
                'Australia/Sydney', 'Australia/Melbourne', 'Pacific/Auckland', 'UTC',
            ],
        })

    def handle_set_timezone(self, data):
        timezone = data.get('timezone', 'auto')
        if timezone != 'auto':
            if not re.fullmatch(r'[A-Za-z0-9_+\-/]+', timezone):
                return self.send_json_response({'error': 'Invalid timezone'}, 400)
            r = subprocess.run(['timedatectl', 'set-timezone', timezone], capture_output=True, text=True, timeout=10)
            if r.returncode != 0:
                return self.send_json_response({'error': r.stderr.strip() or 'Could not set timezone'}, 400)
        update_config(lambda c: c.setdefault('schedule', {}).update({'timezone': timezone}))
        self._signal_connection_monitor()
        self.send_json_response({'success': True, 'timezone': timezone})

    # ---------------------------------------------------------------- wifi

    def handle_get_wifi_country(self):
        r = subprocess.run(['iw', 'reg', 'get'], capture_output=True, text=True, timeout=5)
        m = re.search(r'country (\w\w):', r.stdout)
        country = m.group(1) if m else ''
        self.send_json_response({'country': '' if country == '00' else country})

    def handle_set_wifi_country(self, data):
        country = str(data.get('country', '')).upper()
        if not re.fullmatch(r'[A-Z]{2}', country):
            return self.send_json_response({'error': 'Country must be a two-letter code like US or GB'}, 400)
        try:
            r = subprocess.run(['raspi-config', 'nonint', 'do_wifi_country', country],
                               capture_output=True, text=True, timeout=30)
            ok = r.returncode == 0
        except OSError:
            r = subprocess.run(['iw', 'reg', 'set', country], capture_output=True, text=True, timeout=10)
            ok = r.returncode == 0
        if not ok:
            return self.send_json_response({'error': (r.stderr or r.stdout).strip() or 'Could not set country'}, 400)
        self.send_json_response({'success': True, 'country': country})

    def handle_get_saved_networks(self):
        config = load_config()
        notes = {n['ssid']: n for n in config.get('saved_networks', []) if isinstance(n, dict) and n.get('ssid')}
        networks = []
        for uuid, name, ssid, mode in nm_wifi_connections():
            if mode == 'ap':
                continue  # the setup hotspot itself
            entry = {'ssid': ssid or name, 'connection': name}
            meta = notes.pop(ssid or name, {})
            for key in ('notes', 'added_at', 'last_connected'):
                if meta.get(key):
                    entry[key] = meta[key]
            networks.append(entry)
        # Entries the UI saved that NetworkManager no longer knows about
        for ssid, meta in notes.items():
            networks.append({'ssid': ssid, 'notes': meta.get('notes', ''), 'missing': True})
        self.send_json_response({'saved_networks': networks})

    def _join_from_hotspot(self, ssid, password):
        # Unauthenticated (open hotspot), so this only ever ADDS a profile.
        # Existing profiles are never modified or deleted from here: otherwise
        # anyone near the hotspot could wipe the venue's saved password.
        # If the new profile never connects, wifi-connect-manager.sh deletes it.
        common = ['connection.autoconnect', 'yes', 'connection.autoconnect-priority', '50']
        security = ['wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password] if password else []
        r = subprocess.run(['nmcli', 'connection', 'add', 'type', 'wifi', 'con-name', ssid,
                            'ssid', ssid] + common + security, capture_output=True, text=True, timeout=15)
        m = re.search(r'\(([0-9a-f-]{36})\)', r.stdout)
        uuid = m.group(1) if m else ''
        if r.returncode != 0 or not uuid:
            return self.send_json_response({'error': r.stderr.strip() or 'Could not save the network'}, 400)
        os.makedirs(os.path.dirname(PENDING_WIFI_FILE), exist_ok=True)
        with open(PENDING_WIFI_FILE, 'w') as f:
            f.write(f"{uuid}\n{ssid}\n")
        self._remember_network(ssid)
        self.send_json_response({'success': True, 'message': f'Joining {ssid}'})

        def close_hotspot():
            time.sleep(2)  # let the reply reach the phone first
            subprocess.run(['systemctl', 'stop', 'wifi-connect'], capture_output=True, timeout=60)
        threading.Thread(target=close_hotspot, daemon=True).start()

    def _remember_network(self, ssid, notes=None, connected=False):
        def mutate(config):
            networks = config.setdefault('saved_networks', [])
            entry = next((n for n in networks if n.get('ssid') == ssid), None)
            if not entry:
                entry = {'ssid': ssid, 'added_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                networks.append(entry)
            if notes is not None:
                entry['notes'] = notes
            if connected:
                entry['last_connected'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        update_config(mutate)

    def handle_save_network(self, data):
        """Pre-configure a network: stored by NetworkManager, auto-connects when in range."""
        ssid = (data.get('ssid') or '').strip()
        password = data.get('password') or ''
        if not ssid:
            return self.send_json_response({'error': 'Network name required'}, 400)
        if password and not (8 <= len(password) <= 63):
            return self.send_json_response({'error': 'WiFi passwords are 8 to 63 characters'}, 400)
        existing = [c for c in nm_wifi_connections() if c[2] == ssid and c[3] != 'ap']
        if existing:
            args = ['nmcli', 'connection', 'modify', existing[0][0], 'connection.autoconnect', 'yes']
            if password:
                args += ['wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password]
        else:
            args = ['nmcli', 'connection', 'add', 'type', 'wifi', 'con-name', ssid, 'ssid', ssid,
                    'connection.autoconnect', 'yes']
            if password:
                args += ['wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password]
        r = subprocess.run(args, capture_output=True, text=True, timeout=15)
        if r.returncode != 0:
            return self.send_json_response({'error': r.stderr.strip() or 'NetworkManager rejected the network'}, 400)
        self._remember_network(ssid, notes=(data.get('notes') or '').strip())
        self.send_json_response({'success': True, 'network': {'ssid': ssid}})

    def handle_delete_network(self, data):
        ssid = (data.get('ssid') or '').strip()
        if not ssid:
            return self.send_json_response({'error': 'SSID required'}, 400)
        update_config(lambda c: c.update(
            {'saved_networks': [n for n in c.get('saved_networks', []) if n.get('ssid') != ssid]}))
        errors = []
        if data.get('remove_from_system', True):
            # Match by SSID: Raspberry Pi Imager names its profile "preconfigured".
            for uuid, name, conn_ssid, mode in nm_wifi_connections():
                if mode != 'ap' and (conn_ssid == ssid or name == ssid):
                    r = subprocess.run(['nmcli', 'connection', 'delete', uuid], capture_output=True, text=True, timeout=15)
                    if r.returncode != 0:
                        errors.append(r.stderr.strip())
        if errors:
            return self.send_json_response({'error': '; '.join(errors)}, 500)
        self.send_json_response({'success': True})

    def handle_connect_saved_network(self, data):
        ssid = (data.get('ssid') or '').strip()
        match = [c for c in nm_wifi_connections() if c[3] != 'ap' and (c[2] == ssid or c[1] == ssid)]
        if not match:
            return self.send_json_response({'error': f'No saved network called "{ssid}"'}, 404)
        r = subprocess.run(['nmcli', 'connection', 'up', match[0][0]], capture_output=True, text=True, timeout=45)
        if r.returncode != 0:
            return self.send_json_response({'success': False, 'error': r.stderr.strip() or 'Connection failed'}, 400)
        self._remember_network(ssid, connected=True)
        self.send_json_response({'success': True, 'message': 'Connected'})

    def _scan(self, rescan):
        if rescan:
            subprocess.run(['nmcli', 'device', 'wifi', 'rescan'], capture_output=True, timeout=10)
            time.sleep(2)
        result = subprocess.run(['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list',
                                 '--rescan', 'no'], capture_output=True, text=True, timeout=10)
        networks, seen = [], set()
        for line in result.stdout.splitlines():
            # Parse from the right: an SSID may contain (escaped) colons.
            parts = re.split(r'(?<!\\):', line)
            if len(parts) < 3:
                continue
            ssid = ':'.join(parts[:-2]).replace('\\:', ':').strip()
            signal_str, security = parts[-2], parts[-1].strip()
            if ssid and ssid not in seen:
                seen.add(ssid)
                networks.append({'ssid': ssid, 'signal': int(signal_str) if signal_str.isdigit() else 0,
                                 'security': security, 'encrypted': security not in ('', '--')})
        networks.sort(key=lambda n: n['signal'], reverse=True)
        return networks

    def handle_get_nearby_networks(self):
        rescan = parse_qs(urlparse(self.path).query).get('rescan', ['0'])[0] == '1'
        self.send_json_response({'networks': self._scan(rescan)})

    def handle_get_nearby_networks_compat(self):
        """wifi-connect compatible /networks (used when the hotspot is NOT up)."""
        rescan = parse_qs(urlparse(self.path).query).get('rescan', ['0'])[0] == '1'
        self.send_json_response(self._scan(rescan))

    def handle_wifi_connect(self, data):
        """wifi-connect compatible /connect.

        From the setup hotspot: save the network as a NetworkManager profile,
        answer the phone, then close the hotspot so NetworkManager can join it.
        wifi-connect's own /connect gives up after ~15 s and deletes the
        profile, which is too short once the radio has to leave AP mode; here
        wifi-connect-manager.sh gives the join a full minute, and removes the
        profile only if it never connected (wrong password).

        From the LAN: switch networks directly.
        """
        ssid = (data.get('ssid') or '').strip()
        password = data.get('passphrase') or data.get('password') or ''
        if not ssid:
            return self.send_json_response({'error': 'SSID required'}, 400)
        if password and not (8 <= len(password) <= 63):
            return self.send_json_response({'error': 'WiFi passwords are 8 to 63 characters'}, 400)
        if self.from_setup_hotspot():
            return self._join_from_hotspot(ssid, password)
        match = [c for c in nm_wifi_connections() if c[3] != 'ap' and c[2] == ssid]
        if match:
            if password:
                subprocess.run(['nmcli', 'connection', 'modify', match[0][0], 'wifi-sec.psk', password],
                               capture_output=True, timeout=10)
            r = subprocess.run(['nmcli', 'connection', 'up', match[0][0]], capture_output=True, text=True, timeout=45)
        else:
            args = ['nmcli', 'device', 'wifi', 'connect', ssid]
            if password:
                args += ['password', password]
            r = subprocess.run(args, capture_output=True, text=True, timeout=45)
        if r.returncode != 0:
            return self.send_json_response({'error': r.stderr.strip() or 'Connection failed'}, 400)
        self._remember_network(ssid, connected=True)
        self.send_json_response({'success': True})


def run_server():
    global SETUP_CODE
    port = 8081
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg.startswith('--port='):
            port = int(arg.split('=', 1)[1])
        elif arg == '--port' and i + 1 < len(args):
            port = int(args[i + 1])

    SETUP_CODE = load_or_create_setup_code()
    publish_code_to_boot_partition(SETUP_CODE)
    migrate_config()

    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *a: sys.exit(0))

    ThreadingHTTPServer.daemon_threads = True
    httpd = ThreadingHTTPServer(('', port), ConfigHandler)
    print(f"Ossuary config server on port {port}", flush=True)
    httpd.serve_forever()


if __name__ == '__main__':
    run_server()
