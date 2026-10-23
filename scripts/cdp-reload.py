#!/usr/bin/env python3
"""Reload the kiosk page through the Chrome DevTools Protocol.

Usage: cdp-reload.py [port]        (default port 9222)
Exit status: 0 = Chromium confirmed the reload, 1 = it did not (caller should
fall back to restarting the browser).

The kiosk Chromium is started with --remote-debugging-port, which Chromium only
binds to 127.0.0.1. WebSocket frames sent by a client MUST be masked (RFC 6455
section 5.3); Chromium's DevTools server closes the connection on an unmasked
frame, so a hand-rolled client that skips masking silently does nothing.
"""

import base64
import json
import os
import socket
import struct
import sys
import urllib.request


def _recv_exact(sock, n):
    data = b''
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError('connection closed')
        data += chunk
    return data


def _send_text(sock, payload):
    data = payload.encode()
    header = bytearray([0x81])  # FIN + text frame
    if len(data) < 126:
        header.append(0x80 | len(data))
    elif len(data) < 65536:
        header.append(0x80 | 126)
        header += struct.pack('>H', len(data))
    else:
        header.append(0x80 | 127)
        header += struct.pack('>Q', len(data))
    mask = os.urandom(4)
    header += mask
    sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def _recv_message(sock):
    while True:
        b0, b1 = _recv_exact(sock, 2)
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack('>H', _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack('>Q', _recv_exact(sock, 8))[0]
        if b1 & 0x80:  # servers never mask, but be tolerant
            _recv_exact(sock, 4)
        data = _recv_exact(sock, length)
        if opcode == 0x8:
            raise ConnectionError('server closed the connection')
        if opcode == 0x1:
            return json.loads(data)


def _call(ws_url, method, params):
    host_port, path = ws_url[len('ws://'):].split('/', 1)
    host, port = host_port.rsplit(':', 1)
    sock = socket.create_connection((host, int(port)), timeout=5)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall((
            f'GET /{path} HTTP/1.1\r\nHost: {host_port}\r\n'
            'Upgrade: websocket\r\nConnection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'
        ).encode())
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = sock.recv(1024)
            if not chunk:
                raise ConnectionError('handshake failed')
            response += chunk
        if b' 101 ' not in response.split(b'\r\n', 1)[0]:
            raise ConnectionError('handshake rejected')
        _send_text(sock, json.dumps({'id': 1, 'method': method, 'params': params}))
        while True:
            message = _recv_message(sock)
            if message.get('id') == 1:
                return message
    finally:
        sock.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9222
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/json', timeout=3) as r:
            targets = json.load(r)
    except Exception as e:
        print(f'DevTools not reachable on port {port}: {e}', file=sys.stderr)
        return 1

    for target in targets:
        if target.get('type') != 'page' or not target.get('webSocketDebuggerUrl'):
            continue
        try:
            reply = _call(target['webSocketDebuggerUrl'], 'Page.reload', {'ignoreCache': True})
        except Exception as e:
            print(f'Reload failed: {e}', file=sys.stderr)
            continue
        if 'error' in reply:
            print(f'Reload rejected: {reply["error"]}', file=sys.stderr)
            continue
        print(f'Reloaded {target.get("url", "")}')
        return 0

    print('No page target accepted the reload', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
