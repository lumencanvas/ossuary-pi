#!/usr/bin/env python3
"""
Lightweight config server for Ossuary Pi
Runs on port 80 to provide persistent configuration interface
Compatible with Python 3.9+ (Pi OS Bullseye through Trixie)
"""

import json
import os
import subprocess
import sys
import time
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Check Python version
if sys.version_info < (3, 7):
    print("Error: Python 3.7+ required")
    sys.exit(1)

CONFIG_FILE = "/etc/ossuary/config.json"
UI_DIR = "/opt/ossuary/custom-ui"

class ConfigHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=UI_DIR, **kwargs)

    def do_GET(self):
        parsed_path = urlparse(self.path)

        if parsed_path.path == '/':
            # Serve the main UI
            self.path = '/index.html'
            return SimpleHTTPRequestHandler.do_GET(self)
        elif parsed_path.path == '/startup':
            # Get current startup command
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()

            if os.path.exists(CONFIG_FILE):
                with open(CONFIG_FILE, 'r') as f:
                    config = json.load(f)
                    self.wfile.write(json.dumps({
                        'command': config.get('startup_command', '')
                    }).encode())
            else:
                self.wfile.write(json.dumps({'command': ''}).encode())
        elif parsed_path.path == '/status':
            # Get system status
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()

            # Check WiFi status
            try:
                result = subprocess.run(['iwgetid', '-r'], capture_output=True, text=True)
                ssid = result.stdout.strip()
                wifi_connected = bool(ssid)
            except:
                wifi_connected = False
                ssid = ""

            # Check if in AP mode
            try:
                result = subprocess.run(['systemctl', 'is-active', 'wifi-connect'],
                                      capture_output=True, text=True)
                ap_mode = result.stdout.strip() == 'active'
            except:
                ap_mode = False

            status = {
                'wifi_connected': wifi_connected,
                'ssid': ssid,
                'ap_mode': ap_mode,
                'hostname': subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
            }

            self.wfile.write(json.dumps(status).encode())
        else:
            # Serve static files
            return SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        parsed_path = urlparse(self.path)

        if parsed_path.path == '/startup':
            # Update startup command
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)

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

                # Restart startup service to test the command immediately
                restart_result = subprocess.run(
                    ['systemctl', 'restart', 'ossuary-startup'],
                    capture_output=True,
                    text=True
                )

                # Check if service started successfully
                time.sleep(1)
                status_result = subprocess.run(
                    ['systemctl', 'is-active', 'ossuary-startup'],
                    capture_output=True,
                    text=True
                )

                # Get recent logs
                log_result = subprocess.run(
                    ['journalctl', '-u', 'ossuary-startup', '-n', '10', '--no-pager'],
                    capture_output=True,
                    text=True
                )

                response_data = {
                    'success': True,
                    'service_active': status_result.stdout.strip() == 'active',
                    'restart_output': restart_result.stderr if restart_result.returncode != 0 else '',
                    'recent_logs': log_result.stdout[-500:] if log_result.stdout else 'No logs available'
                }

                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(response_data).encode())
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_OPTIONS(self):
        # Handle CORS preflight
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

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

    server_address = ('', port)
    httpd = HTTPServer(server_address, ConfigHandler)
    print(f"Config server running on port {port}...")
    httpd.serve_forever()

if __name__ == '__main__':
    run_server()