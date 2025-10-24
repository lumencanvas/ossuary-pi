#!/usr/bin/env python3
"""
Smart proxy that manages port 80 access
- During AP mode: Proxies to WiFi Connect (port 80 -> 8080)
- When connected: Serves config interface directly
"""

import subprocess
import time
import sys
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.request
import socket

def check_wifi_connected():
    """Check if connected to WiFi"""
    try:
        result = subprocess.run(['iwgetid', '-r'], capture_output=True, text=True)
        return bool(result.stdout.strip())
    except:
        return False

def check_ap_mode():
    """Check if WiFi Connect is in AP mode"""
    try:
        # Check if wifi-connect process is running with portal
        result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
        return 'wifi-connect' in result.stdout and 'portal' in result.stdout
    except:
        return False

def is_port_open(port, host='localhost'):
    """Check if a port is open"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(1)
    result = sock.connect_ex((host, port))
    sock.close()
    return result == 0

class SmartProxyHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if check_ap_mode() and is_port_open(8080):
            # AP mode - proxy to WiFi Connect on port 8080
            self.proxy_to_wifi_connect()
        else:
            # Connected mode - serve config interface
            self.serve_config_interface()

    def do_POST(self):
        if check_ap_mode() and is_port_open(8080):
            # AP mode - proxy to WiFi Connect
            self.proxy_to_wifi_connect()
        else:
            # Connected mode - handle config updates
            self.handle_config_post()

    def proxy_to_wifi_connect(self):
        """Proxy request to WiFi Connect on port 8080"""
        try:
            # Build target URL
            target_url = f"http://localhost:8080{self.path}"

            # Forward the request
            req = urllib.request.Request(target_url)

            # Copy headers
            for header in self.headers:
                if header.lower() not in ['host', 'connection']:
                    req.add_header(header, self.headers[header])

            # Get response
            response = urllib.request.urlopen(req)

            # Send response back
            self.send_response(response.getcode())
            for header, value in response.headers.items():
                if header.lower() not in ['connection', 'transfer-encoding']:
                    self.send_header(header, value)
            self.end_headers()

            # Copy content
            self.wfile.write(response.read())
        except Exception as e:
            self.send_error(502, f"Proxy error: {str(e)}")

    def serve_config_interface(self):
        """Serve the configuration interface"""
        # Import and use the config server handler
        sys.path.insert(0, '/opt/ossuary/scripts')
        from config_server import ConfigHandler

        # Delegate to config handler
        handler = ConfigHandler(self.request, self.client_address, self.server)
        handler.do_GET()

    def handle_config_post(self):
        """Handle configuration posts"""
        sys.path.insert(0, '/opt/ossuary/scripts')
        from config_server import ConfigHandler

        handler = ConfigHandler(self.request, self.client_address, self.server)
        handler.do_POST()

def main():
    print("Smart Proxy starting on port 80...")
    print("Mode detection enabled:")
    print("  - AP Mode: Proxy to WiFi Connect (port 8080)")
    print("  - Connected: Serve config interface")

    server_address = ('', 80)
    httpd = HTTPServer(server_address, SmartProxyHandler)

    # Check initial state
    if check_ap_mode():
        print("Starting in AP mode - proxying to WiFi Connect")
    else:
        print("Starting in connected mode - serving config interface")

    httpd.serve_forever()

if __name__ == '__main__':
    main()