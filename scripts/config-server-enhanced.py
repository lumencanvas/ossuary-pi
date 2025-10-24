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

        # Serve control panel at root
        if parsed_path.path == '/':
            self.path = '/control-panel.html'
            return SimpleHTTPRequestHandler.do_GET(self)

        # API endpoints
        elif parsed_path.path.startswith('/api/'):
            if parsed_path.path == '/api/status':
                self.handle_status()
            elif parsed_path.path == '/api/startup':
                self.handle_get_startup()
            elif parsed_path.path == '/api/services':
                self.handle_get_services()
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
            else:
                self.send_json_response({'error': 'Not found'}, 404)

        # Legacy endpoints for compatibility
        elif parsed_path.path == '/startup':
            self.handle_get_startup()
        elif parsed_path.path == '/status':
            self.handle_status()
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
                with open('/var/run/ossuary-process.pid', 'r') as f:
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
        """Test a command"""
        global TEST_PROCESSES

        try:
            data = json.loads(post_data)
            command = data.get('command', '')

            if not command:
                self.send_json_response({'error': 'No command provided'}, 400)
                return

            # Create temporary file for output
            output_file = tempfile.NamedTemporaryFile(mode='w+', delete=False, suffix='.log')
            output_filename = output_file.name
            output_file.close()

            # Detect if this is a GUI app
            is_gui = 'chromium' in command or 'firefox' in command or 'DISPLAY=' in command

            # Build the test command
            if is_gui:
                # For GUI apps, set display variables
                test_cmd = f"export DISPLAY=:0; export XAUTHORITY=/home/pi/.Xauthority; {command}"
            else:
                test_cmd = command

            # Start the process
            process = subprocess.Popen(
                test_cmd,
                shell=True,
                stdout=open(output_filename, 'w'),
                stderr=subprocess.STDOUT,
                preexec_fn=os.setsid  # Create new process group for easy cleanup
            )

            # Store process info
            TEST_PROCESSES[str(process.pid)] = {
                'process': process,
                'output_file': output_filename,
                'start_time': time.time()
            }

            self.send_json_response({
                'pid': process.pid,
                'message': 'Test started'
            })

        except Exception as e:
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

            # Clean up
            try:
                os.unlink(output_file)
            except:
                pass
            del TEST_PROCESSES[pid_str]

            self.send_json_response({'success': True})

        except Exception as e:
            self.send_json_response({'error': str(e)}, 500)

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
    for pid_str, proc_info in TEST_PROCESSES.items():
        try:
            process = proc_info['process']
            if process.poll() is None:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
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

    # Set up signal handlers for cleanup
    signal.signal(signal.SIGTERM, lambda s, f: cleanup_test_processes())
    signal.signal(signal.SIGINT, lambda s, f: cleanup_test_processes())

    server_address = ('', port)
    httpd = HTTPServer(server_address, ConfigHandler)
    print(f"Enhanced config server running on port {port}...")

    try:
        httpd.serve_forever()
    finally:
        cleanup_test_processes()

if __name__ == '__main__':
    run_server()