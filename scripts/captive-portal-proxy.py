#!/usr/bin/env python3
"""
Captive Portal Detection Proxy

This proxy sits on port 80 and handles captive portal detection requests from
various platforms (iOS, Android, Windows, Firefox) by returning 302 redirects
to trigger the captive portal detection. All other requests are proxied to
WiFi Connect on port 8080.

IMPORTANT: To TRIGGER captive portal detection, we must return responses that
DIFFER from what the device expects. Returning the "correct" response (204 for
Android, "Success" for iOS) would make the device think internet is available
and NOT show the captive portal.

Strategy:
- Return 302 redirect to "/" for all detection URLs
- This triggers the captive portal UI on all platforms
- The redirect destination shows the WiFi Connect setup UI

Platform Detection URLs (all get 302 redirect):
- Apple iOS/macOS: /hotspot-detect.html, /library/test/success.html
- Android/Chrome: /generate_204, /gen_204
- Windows: /connecttest.txt, /ncsi.txt, /redirect
- Firefox: /canonical.html, /success.txt
"""

import http.server
import socketserver
import urllib.request
import urllib.error
import sys
import signal
import socket
import time

# Configuration
LISTEN_PORT = 80
WIFI_CONNECT_PORT = 8080
WIFI_CONNECT_HOST = 'localhost'
REDIRECT_TARGET = '/'  # Redirect to root (WiFi Connect UI)

# Captive portal detection paths - all trigger redirect to portal UI
PORTAL_DETECTION_PATHS = {
    # Apple devices (iOS, macOS)
    '/hotspot-detect.html',
    '/library/test/success.html',
    '/captive.apple.com',  # Sometimes just the path

    # Android devices (Chrome, Samsung, etc.)
    '/generate_204',
    '/gen_204',
    '/connectivitycheck.gstatic.com',

    # Windows devices
    '/connecttest.txt',
    '/ncsi.txt',
    '/redirect',

    # Firefox
    '/canonical.html',
    '/success.txt',

    # Linux (NetworkManager/GNOME)
    '/check_network_status.txt',
    '/nm-check-status',
}


class CaptivePortalProxyHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler that intercepts captive portal detection and proxies other requests."""

    # Increase timeout for slow connections
    timeout = 30

    def log_message(self, format, *args):
        """Custom logging format."""
        print(f"[{self.log_date_time_string()}] {self.client_address[0]} - {format % args}")

    def is_portal_detection_request(self, path):
        """Check if this is a captive portal detection request."""
        # Normalize path (remove query string) and convert to lowercase
        clean_path = path.split('?')[0].lower()
        return clean_path in PORTAL_DETECTION_PATHS

    def handle_portal_detection(self, path):
        """
        Return a 302 redirect to trigger captive portal detection.

        All platforms detect captive portals by checking if they get
        the expected response. By returning a redirect instead, we
        signal that internet is NOT available and trigger the portal UI.
        """
        clean_path = path.split('?')[0].lower()

        if clean_path not in PORTAL_DETECTION_PATHS:
            return False

        print(f"[PORTAL] Captive portal detection triggered: {clean_path} -> redirect to {REDIRECT_TARGET}")

        # Send 302 redirect to the portal UI
        # This triggers captive portal detection on all platforms
        try:
            self.send_response(302)
            self.send_header('Location', REDIRECT_TARGET)
            self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
            self.send_header('Content-Length', '0')
            self.end_headers()
        except BrokenPipeError:
            # Client disconnected, ignore
            pass

        return True

    def proxy_request(self, method='GET', body=None):
        """Proxy the request to WiFi Connect."""
        target_url = f"http://{WIFI_CONNECT_HOST}:{WIFI_CONNECT_PORT}{self.path}"
        print(f"[PROXY] {method} {self.path} -> {target_url}")

        try:
            # Build request
            req = urllib.request.Request(target_url, method=method)

            # Copy relevant headers
            for header, value in self.headers.items():
                if header.lower() not in ['host', 'connection', 'content-length']:
                    req.add_header(header, value)

            # Set host header for the target
            req.add_header('Host', f'{WIFI_CONNECT_HOST}:{WIFI_CONNECT_PORT}')

            # Add body for POST/PUT requests
            if body:
                req.data = body

            # Send request to WiFi Connect
            response = urllib.request.urlopen(req, timeout=30)

            # Forward response back to client
            self.send_response(response.getcode())

            # Copy response headers
            for header, value in response.headers.items():
                if header.lower() not in ['connection', 'transfer-encoding', 'content-encoding']:
                    self.send_header(header, value)
            self.end_headers()

            # Copy response body
            self.wfile.write(response.read())

        except urllib.error.HTTPError as e:
            # Forward HTTP errors from WiFi Connect
            self.send_response(e.code)
            for header, value in e.headers.items():
                if header.lower() not in ['connection', 'transfer-encoding']:
                    self.send_header(header, value)
            self.end_headers()
            if e.fp:
                self.wfile.write(e.fp.read())

        except urllib.error.URLError as e:
            # WiFi Connect not available
            print(f"[ERROR] WiFi Connect not available: {e}")
            self.send_error(502, f"WiFi Connect service unavailable")

        except socket.timeout:
            print(f"[ERROR] Timeout connecting to WiFi Connect")
            self.send_error(504, "Gateway timeout")

        except BrokenPipeError:
            # Client disconnected mid-request, ignore
            pass

        except Exception as e:
            print(f"[ERROR] Proxy error: {e}")
            self.send_error(502, f"Proxy error")

    def do_GET(self):
        """Handle GET requests."""
        # Check for captive portal detection first
        if self.is_portal_detection_request(self.path):
            self.handle_portal_detection(self.path)
            return

        # Proxy everything else to WiFi Connect
        self.proxy_request('GET')

    def do_POST(self):
        """Handle POST requests."""
        # Read request body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else None

        # Proxy to WiFi Connect
        self.proxy_request('POST', body)

    def do_HEAD(self):
        """Handle HEAD requests."""
        if self.is_portal_detection_request(self.path):
            # Return redirect headers (same as GET but no body)
            self.handle_portal_detection(self.path)
            return

        self.proxy_request('HEAD')

    def do_OPTIONS(self):
        """Handle OPTIONS requests."""
        self.proxy_request('OPTIONS')


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded HTTP server for handling concurrent requests."""
    allow_reuse_address = True
    daemon_threads = True


def check_wifi_connect_available():
    """Check if WiFi Connect is running on port 8080."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(1)
    result = sock.connect_ex((WIFI_CONNECT_HOST, WIFI_CONNECT_PORT))
    sock.close()
    return result == 0


def wait_for_wifi_connect(max_attempts=30, delay=2):
    """Wait for WiFi Connect to become available."""
    print(f"Waiting for WiFi Connect on port {WIFI_CONNECT_PORT}...")
    for attempt in range(max_attempts):
        if check_wifi_connect_available():
            print(f"WiFi Connect is available on port {WIFI_CONNECT_PORT}")
            return True
        print(f"  Attempt {attempt + 1}/{max_attempts}: WiFi Connect not ready...")
        time.sleep(delay)
    print("WARNING: WiFi Connect not available, but starting proxy anyway")
    return False


def main():
    print("=" * 60)
    print("  Captive Portal Detection Proxy")
    print("=" * 60)
    print(f"  Listen port: {LISTEN_PORT}")
    print(f"  WiFi Connect backend: {WIFI_CONNECT_HOST}:{WIFI_CONNECT_PORT}")
    print(f"  Redirect target: {REDIRECT_TARGET}")
    print("")
    print("  Strategy: Return 302 redirects for detection URLs")
    print("  This triggers captive portal UI on all platforms:")
    print("    - Apple iOS/macOS (/hotspot-detect.html)")
    print("    - Android/Chrome (/generate_204)")
    print("    - Windows (/connecttest.txt)")
    print("    - Firefox (/canonical.html)")
    print("=" * 60)

    # Wait for WiFi Connect to be available
    wait_for_wifi_connect(max_attempts=15, delay=2)

    # Create server
    try:
        server = ThreadedHTTPServer(('', LISTEN_PORT), CaptivePortalProxyHandler)
    except PermissionError:
        print(f"ERROR: Cannot bind to port {LISTEN_PORT}. Run as root.")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR creating server: {e}")
        sys.exit(1)

    # Handle shutdown signals gracefully
    def shutdown_handler(signum, frame):
        print(f"\nReceived signal {signum}, shutting down...")
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    # Start server
    print(f"\nProxy server started on port {LISTEN_PORT}")
    print("Waiting for connections...\n")

    try:
        server.serve_forever()
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
