#!/usr/bin/env python3
"""
Enhanced config server for Ossuary Pi with full service management
Runs on port 8080 to provide persistent configuration interface
Compatible with Python 3.9+ (Pi OS Bullseye through Trixie)
"""

import json
import os
import subprocess
import sys
import time
import signal
import threading
import tempfile
import shlex
import re
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Check Python version
if sys.version_info < (3, 7):
    print("Error: Python 3.7+ required")
    sys.exit(1)

CONFIG_FILE = "/etc/ossuary/config.json"
UI_DIR = "/opt/ossuary/custom-ui"
LOG_DIR = "/var/log"
TEST_PROCESSES = {}  # Track test processes

# Config schema for validation (basic type checking)
CONFIG_SCHEMA = {
    "startup_command": str,
    "saved_networks": list,
    "behaviors": dict,
    "schedule": dict,
    "profiles": dict,
    "active_profile": str,
    "version": int
}

def validate_config(config):
    """Validate config against schema. Returns (is_valid, errors)"""
    errors = []

    for key, expected_type in CONFIG_SCHEMA.items():
        if key in config:
            if not isinstance(config[key], expected_type):
                errors.append(f"'{key}' should be {expected_type.__name__}, got {type(config[key]).__name__}")

    # Validate saved_networks structure
    if 'saved_networks' in config and isinstance(config['saved_networks'], list):
        for i, network in enumerate(config['saved_networks']):
            if not isinstance(network, dict):
                errors.append(f"saved_networks[{i}] should be a dict")
            elif 'ssid' not in network:
                errors.append(f"saved_networks[{i}] missing required 'ssid' field")

    # Validate schedule structure
    if 'schedule' in config and isinstance(config['schedule'], dict):
        schedule = config['schedule']
        if 'enabled' in schedule and not isinstance(schedule['enabled'], bool):
            errors.append("schedule.enabled should be boolean")
        if 'rules' in schedule and not isinstance(schedule['rules'], list):
            errors.append("schedule.rules should be a list")

    return (len(errors) == 0, errors)

# Default config schema v2
DEFAULT_CONFIG = {
    "version": 2,
    "startup_command": "",
    "active_profile": "custom",
    "profiles": {
        "lumencanvas": {
            "type": "lumencanvas",
            "name": "LumenCanvas Display",
            "enabled": False,
            "config": {
                "canvas_url": "",
                "flags": {
                    "kiosk": True,
                    "webgpu": True,
                    "autoplay": True,
                    "cursor": False
                }
            }
        },
        "webgpu_kiosk": {
            "type": "webgpu_kiosk",
            "name": "Web Kiosk",
            "enabled": False,
            "config": {
                "url": "",
                "flags": {
                    "kiosk": True,
                    "webgpu": True
                }
            }
        },
        "custom": {
            "type": "custom",
            "name": "Custom Command",
            "enabled": True,
            "config": {
                "command": ""
            }
        }
    },
    "behaviors": {
        "on_connection_lost": {
            "action": "show_overlay",
            "timeout_seconds": 60
        },
        "on_connection_regained": {
            "action": "refresh_page",
            "delay_seconds": 3
        },
        "scheduled_refresh": {
            "enabled": False,
            "interval_minutes": 60
        }
    },
    "schedule": {
        "enabled": False,
        "timezone": "auto",  # "auto" or IANA timezone like "America/New_York"
        "rules": [
            # Example rule structure:
            # {
            #     "id": "rule-1",
            #     "name": "Morning Display",
            #     "enabled": True,
            #     "trigger": {
            #         "type": "time",  # "time", "interval", "connection"
            #         "time": "08:00",
            #         "days": ["mon", "tue", "wed", "thu", "fri"]
            #     },
            #     "action": {
            #         "type": "switch_profile",  # "switch_profile", "refresh", "run_command"
            #         "profile": "lumencanvas"
            #     },
            #     "until": {  # Optional end condition
            #         "type": "time",
            #         "time": "18:00"
            #     }
            # }
        ]
    },
    "saved_networks": [
        # {
        #     "ssid": "MyNetwork",
        #     "password": "",  # Encrypted or empty for open
        #     "priority": 1,  # Higher = preferred
        #     "auto_connect": True,
        #     "added_at": "2024-01-15T10:30:00Z",
        #     "last_connected": "2024-01-15T10:30:00Z",
        #     "notes": "Office WiFi"
        # }
    ],
    "wifi_networks": []  # Legacy, kept for compatibility
}

class ConfigHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=UI_DIR, **kwargs)

    def send_json_response(self, data, status=200):
        """Helper to send JSON responses"""
        self.send_response(status)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')

        # Serve index at root
        if parsed_path.path == '/':
            self.path = '/index.html'
            return SimpleHTTPRequestHandler.do_GET(self)

        # API endpoints
        elif parsed_path.path.startswith('/api/'):
            if parsed_path.path == '/api/status':
                self.handle_status()
            elif parsed_path.path == '/api/startup':
                self.handle_get_startup()
            elif parsed_path.path == '/api/services':
                self.handle_get_services()
            elif parsed_path.path == '/api/behaviors':
                self.handle_get_behaviors()
            elif parsed_path.path == '/api/profiles':
                self.handle_get_profiles()
            elif parsed_path.path == '/api/config':
                self.handle_get_config()
            elif parsed_path.path == '/api/system/info':
                self.handle_system_info()
            elif parsed_path.path == '/api/schedule':
                self.handle_get_schedule()
            elif parsed_path.path == '/api/timezone':
                self.handle_get_timezone()
            elif parsed_path.path == '/api/saved-networks':
                self.handle_get_saved_networks()
            elif parsed_path.path == '/api/nearby-networks':
                self.handle_get_nearby_networks()
            elif path_parts[0] == 'api' and path_parts[1] == 'logs':
                if len(path_parts) > 2:
                    self.handle_get_logs(path_parts[2])
                else:
                    self.send_json_response({'error': 'Log type required'}, 400)
            elif path_parts[0] == 'api' and path_parts[1] == 'test-output':
                if len(path_parts) > 2:
                    self.handle_test_output(path_parts[2])
                else:
                    self.send_json_response({'error': 'PID required'}, 400)
            elif parsed_path.path == '/api/screenshot':
                self.handle_screenshot()
            elif parsed_path.path == '/api/display/power':
                self.handle_get_display_power()
            else:
                self.send_json_response({'error': 'Not found'}, 404)

        # Legacy/WiFi Connect compatible endpoints
        elif parsed_path.path == '/startup':
            self.handle_get_startup()
        elif parsed_path.path == '/status':
            self.handle_status()
        elif parsed_path.path == '/networks':
            self.handle_get_nearby_networks_compat()
        else:
            # Serve static files
            return SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')

        # Read POST data
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length) if content_length > 0 else b'{}'

        # API endpoints
        if parsed_path.path == '/api/startup':
            self.handle_save_startup(post_data)
        elif parsed_path.path == '/api/service-control':
            self.handle_service_control(post_data)
        elif parsed_path.path == '/api/test-command':
            self.handle_test_command(post_data)
        elif parsed_path.path == '/api/behaviors':
            self.handle_save_behaviors(post_data)
        elif parsed_path.path == '/api/process/refresh':
            self.handle_process_refresh()
        elif parsed_path.path == '/api/process/restart':
            self.handle_process_restart()
        elif parsed_path.path == '/api/process/stop':
            self.handle_process_stop()
        elif parsed_path.path == '/api/process/start':
            self.handle_process_start()
        elif parsed_path.path == '/api/startup/clear':
            self.handle_clear_startup()
        elif parsed_path.path == '/api/system/reboot':
            self.handle_system_reboot()
        elif parsed_path.path == '/api/schedule':
            self.handle_save_schedule(post_data)
        elif parsed_path.path == '/api/timezone':
            self.handle_set_timezone(post_data)
        elif parsed_path.path == '/api/saved-networks':
            self.handle_save_network(post_data)
        elif parsed_path.path == '/api/saved-networks/delete':
            self.handle_delete_network(post_data)
        elif parsed_path.path == '/api/saved-networks/connect':
            self.handle_connect_saved_network(post_data)
        elif parsed_path.path == '/api/display/power':
            self.handle_set_display_power(post_data)
        # WiFi Connect compatible endpoint (always available)
        elif parsed_path.path == '/connect':
            self.handle_wifi_connect(post_data)
        elif path_parts[0] == 'api' and path_parts[1] == 'stop-test':
            if len(path_parts) > 2:
                self.handle_stop_test(path_parts[2])
            else:
                self.send_json_response({'error': 'PID required'}, 400)
        # Legacy endpoint
        elif parsed_path.path == '/startup':
            self.handle_save_startup(post_data)
        else:
            self.send_json_response({'error': 'Not found'}, 404)

    def handle_status(self):
        """Get system status"""
        try:
            # Check WiFi status
            try:
                result = subprocess.run(['iwgetid', '-r'], capture_output=True, text=True, timeout=2)
                ssid = result.stdout.strip()
                wifi_connected = bool(ssid)
            except:
                wifi_connected = False
                ssid = ""

            # Check if in AP mode
            try:
                result = subprocess.run(['systemctl', 'is-active', 'wifi-connect'],
                                      capture_output=True, text=True, timeout=2)
                ap_mode = result.stdout.strip() == 'active'
            except:
                ap_mode = False

            status = {
                'wifi_connected': wifi_connected,
                'ssid': ssid,
                'ap_mode': ap_mode,
                'hostname': subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
            }

            self.send_json_response(status)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_startup(self):
        """Get current startup command"""
        try:
            if os.path.exists(CONFIG_FILE):
                with open(CONFIG_FILE, 'r') as f:
                    config = json.load(f)
                    self.send_json_response({
                        'command': config.get('startup_command', '')
                    })
            else:
                self.send_json_response({'command': ''})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_save_startup(self, post_data):
        """Save startup command"""
        try:
            data = json.loads(post_data)
            command = data.get('command', '')

            # Load existing config or create new
            if os.path.exists(CONFIG_FILE):
                with open(CONFIG_FILE, 'r') as f:
                    config = json.load(f)
            else:
                config = {}

            # Update command
            config['startup_command'] = command

            # Save config
            os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
            with open(CONFIG_FILE, 'w') as f:
                json.dump(config, f, indent=2)

            # Send HUP signal to process manager to reload config
            try:
                with open('/run/ossuary/process.pid', 'r') as f:
                    pid = int(f.read().strip())
                    os.kill(pid, signal.SIGHUP)
                    service_reloaded = True
            except:
                service_reloaded = False

            # Check if service is active
            status_result = subprocess.run(
                ['systemctl', 'is-active', 'ossuary-startup'],
                capture_output=True, text=True
            )

            response_data = {
                'success': True,
                'service_active': status_result.stdout.strip() == 'active',
                'config_reloaded': service_reloaded
            }

            self.send_json_response(response_data)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_services(self):
        """Get service status"""
        try:
            services = {}
            for service in ['wifi-connect', 'wifi-connect-manager', 'ossuary-startup', 'ossuary-web']:
                result = subprocess.run(
                    ['systemctl', 'is-active', service],
                    capture_output=True, text=True, timeout=2
                )
                services[service] = result.stdout.strip()

            self.send_json_response(services)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_service_control(self, post_data):
        """Control system services"""
        try:
            data = json.loads(post_data)
            service = data.get('service')
            action = data.get('action')

            # Validate service name
            if service not in ['wifi-connect', 'wifi-connect-manager', 'ossuary-startup', 'ossuary-web']:
                self.send_json_response({'error': 'Invalid service'}, 400)
                return

            # Validate action
            if action not in ['start', 'stop', 'restart']:
                self.send_json_response({'error': 'Invalid action'}, 400)
                return

            # Execute action
            result = subprocess.run(
                ['systemctl', action, service],
                capture_output=True, text=True, timeout=10
            )

            # Check new status
            status_result = subprocess.run(
                ['systemctl', 'is-active', service],
                capture_output=True, text=True, timeout=2
            )

            self.send_json_response({
                'success': result.returncode == 0,
                'service': service,
                'action': action,
                'new_status': status_result.stdout.strip(),
                'output': result.stdout + result.stderr
            })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_logs(self, log_type):
        """Get log content"""
        try:
            logs = ""

            if log_type == 'process':
                # Get process manager logs
                log_file = '/var/log/ossuary-process.log'
                if os.path.exists(log_file):
                    # Get last 100 lines
                    result = subprocess.run(
                        ['tail', '-n', '100', log_file],
                        capture_output=True, text=True, timeout=2
                    )
                    logs = result.stdout
                else:
                    logs = "No process logs available"

            elif log_type == 'wifi':
                # Get WiFi Connect logs
                result = subprocess.run(
                    ['journalctl', '-u', 'wifi-connect', '-n', '50', '--no-pager'],
                    capture_output=True, text=True, timeout=2
                )
                logs = result.stdout or "No WiFi Connect logs available"

            elif log_type == 'system':
                # Get system logs
                result = subprocess.run(
                    ['journalctl', '-u', 'ossuary-startup', '-u', 'ossuary-web', '-n', '50', '--no-pager'],
                    capture_output=True, text=True, timeout=2
                )
                logs = result.stdout or "No system logs available"

            else:
                logs = f"Unknown log type: {log_type}"

            self.send_json_response({'logs': logs})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_test_command(self, post_data):
        """Test a command.

        SECURITY NOTE: This endpoint intentionally runs user-provided commands
        for testing display configurations. Access should be restricted to
        trusted networks only. The Pi is designed to run user commands.
        """
        global TEST_PROCESSES

        try:
            data = json.loads(post_data)
            command = data.get('command', '')

            if not command:
                self.send_json_response({'error': 'No command provided'}, 400)
                return

            # Input validation
            command = command.strip()

            # Limit command length to prevent memory issues
            if len(command) > 4096:
                self.send_json_response({'error': 'Command too long (max 4096 chars)'}, 400)
                return

            # Limit concurrent test processes
            if len(TEST_PROCESSES) >= 5:
                self.send_json_response({'error': 'Too many test processes running'}, 429)
                return

            # Log the command being tested (for audit trail)
            print(f"[TEST] Running command: {command[:100]}{'...' if len(command) > 100 else ''}")

            # Create temporary file for output
            output_file = tempfile.NamedTemporaryFile(mode='w+', delete=False, suffix='.log')
            output_filename = output_file.name
            output_file.close()

            # Detect if this is a GUI app
            is_gui = 'chromium' in command.lower() or 'firefox' in command.lower() or 'DISPLAY=' in command

            # Build the test command with proper quoting for display vars
            if is_gui:
                # For GUI apps, set display variables
                test_cmd = f"export DISPLAY=:0; export XAUTHORITY=/home/pi/.Xauthority; {command}"
            else:
                test_cmd = command

            # Start the process with properly managed file handle
            output_handle = open(output_filename, 'w')
            process = subprocess.Popen(
                test_cmd,
                shell=True,  # Required for user commands with pipes/redirects
                stdout=output_handle,
                stderr=subprocess.STDOUT,
                preexec_fn=os.setsid,  # Create new process group for easy cleanup
                cwd='/tmp'  # Run from safe directory
            )

            # Store process info including file handle for proper cleanup
            TEST_PROCESSES[str(process.pid)] = {
                'process': process,
                'output_file': output_filename,
                'output_handle': output_handle,
                'start_time': time.time(),
                'command': command[:100]  # Store for logging
            }

            self.send_json_response({
                'pid': process.pid,
                'message': 'Test started'
            })

        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
        except Exception as e:
            print(f"[ERROR] Test command failed: {e}")
            self.send_json_response({'error': str(e)}, 500)

    def handle_test_output(self, pid_str):
        """Get output from test process"""
        global TEST_PROCESSES

        try:
            if pid_str not in TEST_PROCESSES:
                self.send_json_response({'error': 'Process not found'}, 404)
                return

            proc_info = TEST_PROCESSES[pid_str]
            process = proc_info['process']
            output_file = proc_info['output_file']

            # Read output
            output = ""
            if os.path.exists(output_file):
                with open(output_file, 'r') as f:
                    output = f.read()

            # Check if process is still running
            poll_result = process.poll()
            running = poll_result is None

            response = {
                'output': output,
                'running': running,
                'exit_code': poll_result if not running else None
            }

            # Clean up if process ended
            if not running:
                try:
                    if 'output_handle' in proc_info:
                        proc_info['output_handle'].close()
                except:
                    pass
                try:
                    os.unlink(output_file)
                except:
                    pass
                del TEST_PROCESSES[pid_str]

            self.send_json_response(response)

        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_stop_test(self, pid_str):
        """Stop a test process"""
        global TEST_PROCESSES

        try:
            if pid_str not in TEST_PROCESSES:
                self.send_json_response({'error': 'Process not found'}, 404)
                return

            proc_info = TEST_PROCESSES[pid_str]
            process = proc_info['process']
            output_file = proc_info['output_file']

            # Kill the process group
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                time.sleep(1)
                if process.poll() is None:
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except:
                # Fallback to just killing the process
                process.terminate()
                time.sleep(1)
                if process.poll() is None:
                    process.kill()

            # Clean up file handle and file
            try:
                if 'output_handle' in proc_info:
                    proc_info['output_handle'].close()
            except:
                pass
            try:
                os.unlink(output_file)
            except:
                pass
            del TEST_PROCESSES[pid_str]

            self.send_json_response({'success': True})

        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_behaviors(self):
        """Get behavior settings"""
        try:
            config = self._load_config()
            behaviors = config.get('behaviors', DEFAULT_CONFIG.get('behaviors', {}))
            self.send_json_response(behaviors)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_save_behaviors(self, post_data):
        """Save behavior settings"""
        try:
            data = json.loads(post_data)
            config = self._load_config()
            config['behaviors'] = data
            self._save_config(config)
            self.send_json_response({'success': True})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_profiles(self):
        """Get all profiles"""
        try:
            config = self._load_config()
            profiles = config.get('profiles', DEFAULT_CONFIG.get('profiles', {}))
            active = config.get('active_profile', 'custom')
            self.send_json_response({
                'profiles': profiles,
                'active': active
            })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_config(self):
        """Get full config"""
        try:
            config = self._load_config()
            self.send_json_response(config)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_system_info(self):
        """Get system information"""
        try:
            hostname = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
            ip_result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
            ip = ip_result.stdout.strip().split()[0] if ip_result.stdout.strip() else ''

            info = {
                'hostname': hostname,
                'hostname_local': f"{hostname}.local",
                'ip': ip,
                'config_url': f"http://{hostname}.local:8080",
                'config_url_ip': f"http://{ip}:8080" if ip else None
            }
            self.send_json_response(info)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_process_refresh(self):
        """Trigger page refresh in running process"""
        try:
            # Send HUP signal to process manager
            pid_file = '/run/ossuary/process.pid'
            if os.path.exists(pid_file):
                with open(pid_file, 'r') as f:
                    pid = int(f.read().strip())
                os.kill(pid, signal.SIGHUP)
                self.send_json_response({'success': True, 'message': 'Refresh signal sent'})
            else:
                self.send_json_response({'error': 'Process not running'}, 404)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_process_restart(self):
        """Restart the running process"""
        try:
            result = subprocess.run(
                ['systemctl', 'restart', 'ossuary-startup'],
                capture_output=True, text=True, timeout=10
            )
            self.send_json_response({
                'success': result.returncode == 0,
                'output': result.stdout + result.stderr
            })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_process_stop(self):
        """Stop the running process (but keep service active for restart)"""
        try:
            # Send SIGTERM to the process manager's child process
            pid_file = '/run/ossuary/process.pid.child'
            if os.path.exists(pid_file):
                with open(pid_file, 'r') as f:
                    pid = int(f.read().strip())
                os.kill(pid, signal.SIGTERM)
                self.send_json_response({'success': True, 'message': f'Stopped process {pid}'})
            else:
                # Try stopping via systemctl
                result = subprocess.run(
                    ['systemctl', 'stop', 'ossuary-startup'],
                    capture_output=True, text=True, timeout=10
                )
                self.send_json_response({
                    'success': result.returncode == 0,
                    'output': result.stdout + result.stderr
                })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_process_start(self):
        """Start the process service"""
        try:
            result = subprocess.run(
                ['systemctl', 'start', 'ossuary-startup'],
                capture_output=True, text=True, timeout=10
            )
            self.send_json_response({
                'success': result.returncode == 0,
                'output': result.stdout + result.stderr
            })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_clear_startup(self):
        """Clear the startup command"""
        try:
            config = self._load_config()
            config['startup_command'] = ''
            self._save_config(config)
            self.send_json_response({'success': True, 'message': 'Startup command cleared'})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_system_reboot(self):
        """Reboot the system"""
        try:
            self.send_json_response({'success': True, 'message': 'Rebooting in 3 seconds...'})
            # Schedule reboot in background to allow response to be sent
            subprocess.Popen(['/bin/bash', '-c', 'sleep 3 && /sbin/reboot'])
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_screenshot(self):
        """Capture a screenshot of the current display"""
        try:
            screenshot_path = '/tmp/ossuary-screenshot.png'

            # Try different screenshot tools in order of preference
            success = False

            # Method 1: scrot (works on X11)
            if not success:
                result = subprocess.run(
                    ['scrot', screenshot_path],
                    capture_output=True, timeout=10,
                    env={**os.environ, 'DISPLAY': ':0'}
                )
                if result.returncode == 0 and os.path.exists(screenshot_path):
                    success = True

            # Method 2: grim (works on Wayland)
            if not success:
                result = subprocess.run(
                    ['grim', screenshot_path],
                    capture_output=True, timeout=10
                )
                if result.returncode == 0 and os.path.exists(screenshot_path):
                    success = True

            # Method 3: gnome-screenshot
            if not success:
                result = subprocess.run(
                    ['gnome-screenshot', '-f', screenshot_path],
                    capture_output=True, timeout=10,
                    env={**os.environ, 'DISPLAY': ':0'}
                )
                if result.returncode == 0 and os.path.exists(screenshot_path):
                    success = True

            if success and os.path.exists(screenshot_path):
                # Read and return the image
                with open(screenshot_path, 'rb') as f:
                    image_data = f.read()
                os.unlink(screenshot_path)

                self.send_response(200)
                self.send_header('Content-type', 'image/png')
                self.send_header('Content-Length', len(image_data))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(image_data)
            else:
                self.send_json_response({
                    'error': 'Screenshot failed - no compatible tool found (install scrot or grim)'
                }, 500)

        except subprocess.TimeoutExpired:
            self.send_json_response({'error': 'Screenshot timed out'}, 500)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_display_power(self):
        """Get current display power state"""
        try:
            # Try vcgencmd (Raspberry Pi specific)
            result = subprocess.run(
                ['vcgencmd', 'display_power'],
                capture_output=True, text=True, timeout=5
            )

            if result.returncode == 0:
                output = result.stdout.strip()
                # Output is like "display_power=1" or "display_power=0"
                power_on = '=1' in output
                self.send_json_response({
                    'power': 'on' if power_on else 'off',
                    'raw': output
                })
            else:
                self.send_json_response({
                    'error': 'vcgencmd not available',
                    'power': 'unknown'
                }, 500)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_set_display_power(self, post_data):
        """Set display power state (on/off)"""
        try:
            data = json.loads(post_data)
            power = data.get('power', '').lower()

            if power not in ['on', 'off', '1', '0']:
                self.send_json_response({'error': 'power must be "on" or "off"'}, 400)
                return

            power_value = '1' if power in ['on', '1'] else '0'

            # Use vcgencmd (Raspberry Pi specific)
            result = subprocess.run(
                ['vcgencmd', 'display_power', power_value],
                capture_output=True, text=True, timeout=5
            )

            if result.returncode == 0:
                self.send_json_response({
                    'success': True,
                    'power': 'on' if power_value == '1' else 'off'
                })
            else:
                self.send_json_response({
                    'error': 'Failed to set display power',
                    'details': result.stderr
                }, 500)
        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def _load_config(self):
        """Load config with defaults"""
        config = dict(DEFAULT_CONFIG)  # Start with defaults
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, 'r') as f:
                    saved_config = json.load(f)
                    # Merge saved config over defaults
                    config.update(saved_config)
            except:
                pass
        return config

    def _save_config(self, config):
        """Save config to file"""
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)

    # Schedule handlers
    def handle_get_schedule(self):
        """Get schedule configuration"""
        try:
            config = self._load_config()
            schedule = config.get('schedule', DEFAULT_CONFIG.get('schedule', {}))
            self.send_json_response(schedule)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_save_schedule(self, post_data):
        """Save schedule configuration"""
        try:
            data = json.loads(post_data)
            config = self._load_config()
            config['schedule'] = data
            self._save_config(config)
            # Notify scheduler service to restart (picks up new config)
            subprocess.run(['systemctl', 'restart', 'ossuary-connection-monitor'],
                         capture_output=True, timeout=10)
            self.send_json_response({'success': True})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_timezone(self):
        """Get current timezone"""
        try:
            # Get system timezone
            result = subprocess.run(['timedatectl', 'show', '--property=Timezone', '--value'],
                                  capture_output=True, text=True, timeout=5)
            system_tz = result.stdout.strip() if result.returncode == 0 else 'UTC'

            # Get config timezone setting
            config = self._load_config()
            config_tz = config.get('schedule', {}).get('timezone', 'auto')

            # Get list of common timezones
            common_timezones = [
                'America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles',
                'America/Phoenix', 'America/Anchorage', 'Pacific/Honolulu',
                'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Europe/Moscow',
                'Asia/Tokyo', 'Asia/Shanghai', 'Asia/Singapore', 'Asia/Dubai',
                'Australia/Sydney', 'Australia/Melbourne', 'Pacific/Auckland',
                'UTC'
            ]

            self.send_json_response({
                'system_timezone': system_tz,
                'config_timezone': config_tz,
                'effective_timezone': system_tz if config_tz == 'auto' else config_tz,
                'available_timezones': common_timezones
            })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_set_timezone(self, post_data):
        """Set timezone"""
        try:
            data = json.loads(post_data)
            timezone = data.get('timezone', 'auto')

            config = self._load_config()
            if 'schedule' not in config:
                config['schedule'] = DEFAULT_CONFIG.get('schedule', {})
            config['schedule']['timezone'] = timezone

            # If not 'auto', also set system timezone
            if timezone != 'auto':
                subprocess.run(['timedatectl', 'set-timezone', timezone],
                             capture_output=True, timeout=10)

            self._save_config(config)
            self.send_json_response({'success': True, 'timezone': timezone})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    # Saved networks handlers
    def handle_get_saved_networks(self):
        """Get saved networks list"""
        try:
            config = self._load_config()
            saved = config.get('saved_networks', [])

            # Also get networks from NetworkManager
            nm_networks = []
            try:
                result = subprocess.run(
                    ['nmcli', '-t', '-f', 'NAME,TYPE,DEVICE', 'connection', 'show'],
                    capture_output=True, text=True, timeout=5
                )
                if result.returncode == 0:
                    for line in result.stdout.strip().split('\n'):
                        if line:
                            parts = line.split(':')
                            if len(parts) >= 2 and parts[1] == '802-11-wireless':
                                nm_networks.append({'ssid': parts[0], 'from_nm': True})
            except:
                pass

            self.send_json_response({
                'saved_networks': saved,
                'nm_networks': nm_networks
            })
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_save_network(self, post_data):
        """Save a network to the list"""
        try:
            data = json.loads(post_data)
            ssid = data.get('ssid', '').strip()
            password = data.get('password', '')
            notes = data.get('notes', '')
            priority = data.get('priority', 0)
            auto_connect = data.get('auto_connect', True)

            if not ssid:
                self.send_json_response({'error': 'SSID required'}, 400)
                return

            config = self._load_config()
            if 'saved_networks' not in config:
                config['saved_networks'] = []

            # Check if network already exists
            existing = next((n for n in config['saved_networks'] if n['ssid'] == ssid), None)

            network_entry = {
                'ssid': ssid,
                'password': password,  # Note: In production, this should be encrypted
                'priority': priority,
                'auto_connect': auto_connect,
                'notes': notes,
                'added_at': existing['added_at'] if existing else time.strftime('%Y-%m-%dT%H:%M:%SZ'),
                'last_connected': existing.get('last_connected') if existing else None
            }

            if existing:
                # Update existing
                idx = config['saved_networks'].index(existing)
                config['saved_networks'][idx] = network_entry
            else:
                # Add new
                config['saved_networks'].append(network_entry)

            self._save_config(config)

            # Also add to NetworkManager if password provided
            if password:
                try:
                    # Check if connection already exists in NM
                    check = subprocess.run(
                        ['nmcli', 'connection', 'show', ssid],
                        capture_output=True, timeout=5
                    )
                    if check.returncode == 0:
                        # Update existing
                        subprocess.run(
                            ['nmcli', 'connection', 'modify', ssid,
                             'wifi-sec.psk', password],
                            capture_output=True, timeout=10
                        )
                    else:
                        # Create new
                        subprocess.run(
                            ['nmcli', 'connection', 'add', 'type', 'wifi',
                             'con-name', ssid, 'ssid', ssid,
                             'wifi-sec.key-mgmt', 'wpa-psk',
                             'wifi-sec.psk', password],
                            capture_output=True, timeout=10
                        )
                except:
                    pass  # Non-critical if NM add fails

            self.send_json_response({'success': True, 'network': network_entry})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_delete_network(self, post_data):
        """Delete a saved network"""
        try:
            data = json.loads(post_data)
            ssid = data.get('ssid', '').strip()

            if not ssid:
                self.send_json_response({'error': 'SSID required'}, 400)
                return

            config = self._load_config()
            if 'saved_networks' not in config:
                config['saved_networks'] = []

            # Remove from saved networks
            config['saved_networks'] = [n for n in config['saved_networks'] if n['ssid'] != ssid]
            self._save_config(config)

            # Optionally remove from NetworkManager too
            if data.get('remove_from_system', False):
                try:
                    subprocess.run(
                        ['nmcli', 'connection', 'delete', ssid],
                        capture_output=True, timeout=10
                    )
                except:
                    pass

            self.send_json_response({'success': True})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_connect_saved_network(self, post_data):
        """Connect to a saved network"""
        try:
            data = json.loads(post_data)
            ssid = data.get('ssid', '').strip()

            if not ssid:
                self.send_json_response({'error': 'SSID required'}, 400)
                return

            # Try to connect via NetworkManager
            result = subprocess.run(
                ['nmcli', 'connection', 'up', ssid],
                capture_output=True, text=True, timeout=30
            )

            if result.returncode == 0:
                # Update last_connected
                config = self._load_config()
                for network in config.get('saved_networks', []):
                    if network['ssid'] == ssid:
                        network['last_connected'] = time.strftime('%Y-%m-%dT%H:%M:%SZ')
                        break
                self._save_config(config)
                self.send_json_response({'success': True, 'message': 'Connected'})
            else:
                self.send_json_response({
                    'success': False,
                    'error': result.stderr or 'Connection failed'
                }, 400)
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_nearby_networks(self):
        """Scan for nearby WiFi networks"""
        try:
            # Trigger a rescan
            subprocess.run(['nmcli', 'device', 'wifi', 'rescan'],
                         capture_output=True, timeout=10)
            time.sleep(2)  # Give it time to scan

            # Get list of networks
            result = subprocess.run(
                ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY,BSSID', 'device', 'wifi', 'list'],
                capture_output=True, text=True, timeout=10
            )

            networks = []
            seen_ssids = set()

            if result.returncode == 0:
                for line in result.stdout.strip().split('\n'):
                    if line:
                        parts = line.split(':')
                        if len(parts) >= 3:
                            ssid = parts[0].strip()
                            if ssid and ssid not in seen_ssids:
                                seen_ssids.add(ssid)
                                networks.append({
                                    'ssid': ssid,
                                    'signal': int(parts[1]) if parts[1].isdigit() else 0,
                                    'security': parts[2] if len(parts) > 2 else '',
                                    'encrypted': parts[2] != '' and parts[2] != '--'
                                })

            # Sort by signal strength
            networks.sort(key=lambda x: x['signal'], reverse=True)
            self.send_json_response({'networks': networks})
        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def handle_get_nearby_networks_compat(self):
        """Get nearby networks in WiFi Connect compatible format"""
        try:
            # Trigger a rescan
            subprocess.run(['nmcli', 'device', 'wifi', 'rescan'],
                         capture_output=True, timeout=10)
            time.sleep(2)

            result = subprocess.run(
                ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list'],
                capture_output=True, text=True, timeout=10
            )

            networks = []
            seen_ssids = set()

            if result.returncode == 0:
                for line in result.stdout.strip().split('\n'):
                    if line:
                        parts = line.split(':')
                        if len(parts) >= 2:
                            ssid = parts[0].strip()
                            if ssid and ssid not in seen_ssids:
                                seen_ssids.add(ssid)
                                networks.append({
                                    'ssid': ssid,
                                    'signal': int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0,
                                    'security': parts[2] if len(parts) > 2 else '',
                                    'encrypted': len(parts) > 2 and parts[2] != '' and parts[2] != '--'
                                })

            networks.sort(key=lambda x: x['signal'], reverse=True)
            # Return as array directly (WiFi Connect format)
            self.send_json_response(networks)
        except Exception as e:
            self.send_json_response([], 200)  # Return empty array on error

    def handle_wifi_connect(self, post_data):
        """Connect to a WiFi network (WiFi Connect compatible)"""
        try:
            data = json.loads(post_data)
            ssid = data.get('ssid', '').strip()
            password = data.get('passphrase', '') or data.get('password', '')

            if not ssid:
                self.send_json_response({'error': 'SSID required'}, 400)
                return

            # Check if connection already exists
            check = subprocess.run(
                ['nmcli', 'connection', 'show', ssid],
                capture_output=True, timeout=5
            )

            if check.returncode == 0:
                # Connection exists, update password if provided and connect
                if password:
                    subprocess.run(
                        ['nmcli', 'connection', 'modify', ssid, 'wifi-sec.psk', password],
                        capture_output=True, timeout=10
                    )
                result = subprocess.run(
                    ['nmcli', 'connection', 'up', ssid],
                    capture_output=True, text=True, timeout=30
                )
            else:
                # Create new connection
                if password:
                    result = subprocess.run(
                        ['nmcli', 'device', 'wifi', 'connect', ssid, 'password', password],
                        capture_output=True, text=True, timeout=30
                    )
                else:
                    result = subprocess.run(
                        ['nmcli', 'device', 'wifi', 'connect', ssid],
                        capture_output=True, text=True, timeout=30
                    )

            if result.returncode == 0:
                # Also save to our networks list
                self._save_network_to_list(ssid, password)
                self.send_json_response({'success': True})
            else:
                self.send_json_response({
                    'error': result.stderr or 'Connection failed'
                }, 400)

        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

    def _save_network_to_list(self, ssid, password):
        """Helper to save network to saved_networks list"""
        try:
            config = self._load_config()
            if 'saved_networks' not in config:
                config['saved_networks'] = []

            existing = next((n for n in config['saved_networks'] if n['ssid'] == ssid), None)
            if not existing:
                config['saved_networks'].append({
                    'ssid': ssid,
                    'password': password,
                    'priority': 0,
                    'auto_connect': True,
                    'notes': '',
                    'added_at': time.strftime('%Y-%m-%dT%H:%M:%SZ'),
                    'last_connected': time.strftime('%Y-%m-%dT%H:%M:%SZ')
                })
            else:
                existing['last_connected'] = time.strftime('%Y-%m-%dT%H:%M:%SZ')
                if password:
                    existing['password'] = password

            self._save_config(config)
        except:
            pass  # Non-critical

    def do_OPTIONS(self):
        """Handle CORS preflight"""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

def cleanup_test_processes():
    """Clean up any remaining test processes on exit"""
    global TEST_PROCESSES
    for pid_str, proc_info in list(TEST_PROCESSES.items()):
        try:
            process = proc_info['process']
            if process.poll() is None:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except:
            pass
        try:
            if 'output_handle' in proc_info:
                proc_info['output_handle'].close()
        except:
            pass
        try:
            os.unlink(proc_info['output_file'])
        except:
            pass
    TEST_PROCESSES.clear()

def run_server():
    # Check for port argument
    port = 8080  # Default port to avoid conflict with WiFi Connect
    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            if arg.startswith('--port'):
                if '=' in arg:
                    port = int(arg.split('=')[1])
                else:
                    port = int(sys.argv[sys.argv.index(arg) + 1])

    # Set up signal handlers for cleanup and exit
    def signal_handler(signum, frame):
        cleanup_test_processes()
        sys.exit(0)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    server_address = ('', port)
    httpd = HTTPServer(server_address, ConfigHandler)
    print(f"Enhanced config server running on port {port}...")

    try:
        httpd.serve_forever()
    finally:
        cleanup_test_processes()

if __name__ == '__main__':
    run_server()