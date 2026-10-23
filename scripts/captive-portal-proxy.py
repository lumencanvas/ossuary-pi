#!/usr/bin/env python3
"""
Ossuary front door on port 80.

While the "Ossuary-Setup" hotspot is up (balena wifi-connect running):
  * Operating-system captive-portal probes (Apple /hotspot-detect.html, Android
    /generate_204, Windows /connecttest.txt, ...) and any request for a foreign
    host get a 302 to http://192.168.42.1/. Answering a probe with anything but
    the expected response is what makes phones pop the "sign in to network"
    sheet. wifi-connect's dnsmasq resolves every name to the gateway, so all of
    those requests land here.
  * /networks goes to wifi-connect: it scanned before raising the access
    point, and the radio can't scan while it is one.
  * Everything else (the setup UI and its /api) goes to the Ossuary config
    server, so the full setup, including the startup command, works from the
    phone that joined the hotspot.

When the hotspot is down this simply forwards to the config server, so
http://<hostname>.local/ works on the LAN as well as :8081.

wifi-connect binds to the gateway address (192.168.42.1:8080), not loopback,
and redirects any request whose Host header is not the gateway, so both the
address and the Host header below matter.
"""

import http.client
import http.server
import signal
import socket
import socketserver
import sys
import time

LISTEN_PORT = 80
PORTAL_GATEWAY = '192.168.42.1'   # wifi-connect default --portal-gateway
WIFI_CONNECT = (PORTAL_GATEWAY, 8080)
CONFIG_SERVER = ('127.0.0.1', 8081)
PORTAL_URL = f'http://{PORTAL_GATEWAY}/'

PORTAL_DETECTION_PATHS = {
    '/hotspot-detect.html', '/library/test/success.html',            # Apple
    '/generate_204', '/gen_204',                                      # Android / Chrome
    '/connecttest.txt', '/ncsi.txt', '/redirect',                     # Windows
    '/canonical.html', '/success.txt',                                # Firefox
    '/check_network_status.txt', '/nm-check-status',                  # Linux
    '/kindle-wifi/wifistub.html',                                     # Kindle
}
# Only the scan comes from wifi-connect (it scanned before raising the access
# point). Joining a network (/connect) is handled by the config server, which
# gives the join longer than wifi-connect's ~15 s.
WIFI_CONNECT_PATHS = {'/networks'}
HOP_BY_HOP = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
              'te', 'trailers', 'transfer-encoding', 'upgrade', 'host', 'content-length',
              'x-forwarded-for', 'x-forwarded-host'}

_portal_cache = {'at': 0.0, 'up': False}


def portal_active():
    """Is wifi-connect listening? Cached for 2s (called on every request)."""
    now = time.monotonic()
    if now - _portal_cache['at'] > 2:
        try:
            with socket.create_connection(WIFI_CONNECT, timeout=0.5):
                _portal_cache['up'] = True
        except OSError:
            _portal_cache['up'] = False
        _portal_cache['at'] = now
    return _portal_cache['up']


def local_hostnames():
    name = socket.gethostname().lower()
    return {PORTAL_GATEWAY, name, f'{name}.local', 'localhost', '127.0.0.1'}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    timeout = 30
    MAX_BODY = 1024 * 1024

    def log_message(self, fmt, *args):
        print(f'{self.client_address[0]} {fmt % args}', flush=True)

    def _redirect_to_portal(self):
        self.send_response(302)
        self.send_header('Location', PORTAL_URL)
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def _route(self):
        path = self.path.split('?', 1)[0]
        host = (self.headers.get('Host') or '').split(':', 1)[0].lower()
        if portal_active():
            if path.lower() in PORTAL_DETECTION_PATHS or (host and host not in local_hostnames()):
                return 'redirect'
            if path in WIFI_CONNECT_PATHS:
                return 'wifi-connect'
        return 'config'

    def _forward(self, target, body):
        host, port = target
        # Longer than the config server's slowest call (joining a network, 45 s).
        conn = http.client.HTTPConnection(host, port, timeout=60)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        headers['Host'] = f'{host}:{port}'
        headers['X-Forwarded-For'] = self.client_address[0]
        headers['X-Forwarded-Host'] = self.headers.get('Host', '')
        headers['Connection'] = 'close'
        if body is not None:
            headers['Content-Length'] = str(len(body))
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
        except OSError as e:
            print(f'[ERROR] {self.command} {self.path} -> {host}:{port}: {e}', flush=True)
            self.send_error(502, 'Service unavailable')
            return
        finally:
            conn.close()

        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_BY_HOP:
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def _handle(self):
        if len(self.path) > 2048:
            self.send_error(414)
            return
        body = None
        if self.command in ('POST', 'PUT'):
            try:
                length = int(self.headers.get('Content-Length', 0))
            except ValueError:
                self.send_error(400)
                return
            if length < 0 or length > self.MAX_BODY:
                self.send_error(413)
                return
            body = self.rfile.read(length)

        route = self._route()
        try:
            if route == 'redirect':
                self._redirect_to_portal()
            elif route == 'wifi-connect':
                self._forward(WIFI_CONNECT, body)
            else:
                self._forward(CONFIG_SERVER, body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = do_POST = do_HEAD = do_PUT = do_OPTIONS = _handle


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    try:
        server = Server(('', LISTEN_PORT), Handler)
    except OSError as e:
        print(f'ERROR: cannot listen on port {LISTEN_PORT}: {e}', flush=True)
        sys.exit(1)

    def shutdown(signum, frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(f'Ossuary front door on :{LISTEN_PORT} (portal {WIFI_CONNECT[0]}:{WIFI_CONNECT[1]}, '
          f'config {CONFIG_SERVER[0]}:{CONFIG_SERVER[1]})', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
