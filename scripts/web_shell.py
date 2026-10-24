"""
Ossuary web shell: a terminal on the Pi in the control panel (xterm.js).

A WebSocket (RFC 6455, stdlib only) carried by config-server.py's own HTTP
server. The shell runs as the kiosk user in a pseudo-terminal, the same user
and power the startup command already has. Off unless the owner switches it
on in the panel.

Wire protocol:
  client -> server  text frames, JSON:
      {"type": "auth", "code": "...", "cols": 80, "rows": 24}   (first message)
      {"type": "input", "data": "..."}
      {"type": "resize", "cols": 120, "rows": 40}
  server -> client  binary frames: raw terminal output
                    text frame {"type": "error", "message": "..."} before closing
"""

import base64
import fcntl
import hashlib
import json
import os
import select
import signal
import struct
import subprocess
import termios
import threading

WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
MAX_SESSIONS = 3
MAX_FRAME = 1 << 20

_sessions = 0
_sessions_lock = threading.Lock()


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()


def _recv_exact(reader, n):
    """reader: the handler's buffered rfile, which may already hold bytes the
    client sent right after its handshake (reading the raw socket would lose them)."""
    data = b''
    while len(data) < n:
        chunk = reader.read(n - len(data))
        if not chunk:
            raise ConnectionError('closed')
        data += chunk
    return data


def recv_frame(sock):
    """(opcode, payload) of the next complete message from a client (sock: a readable stream)."""
    message, first_opcode = b'', None
    while True:
        b0, b1 = _recv_exact(sock, 2)
        fin, opcode = b0 & 0x80, b0 & 0x0F
        masked, length = b1 & 0x80, b1 & 0x7F
        if length == 126:
            length = struct.unpack('>H', _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack('>Q', _recv_exact(sock, 8))[0]
        if not masked or length > MAX_FRAME:
            raise ConnectionError('bad frame')
        mask = _recv_exact(sock, 4)
        payload = bytearray(_recv_exact(sock, length))
        for i in range(length):
            payload[i] ^= mask[i % 4]
        if opcode >= 0x8:  # control frames are never fragmented
            return opcode, bytes(payload)
        if first_opcode is None:
            first_opcode = opcode
        message += payload
        if len(message) > MAX_FRAME:
            raise ConnectionError('message too large')
        if fin:
            return first_opcode, message


def send_frame(sock, payload, opcode=0x2, lock=None):
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack('>H', n)
    else:
        header += bytes([127]) + struct.pack('>Q', n)
    if lock:
        with lock:
            sock.sendall(header + payload)
    else:
        sock.sendall(header + payload)


def _set_size(fd, cols, rows):
    cols = max(10, min(int(cols or 80), 500))
    rows = max(5, min(int(rows or 24), 200))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


def run_session(sock, rfile, check_code, user, env):
    """Serve one terminal on an upgraded connection until either side closes.

    sock: the socket (for writing, timeouts, shutdown); rfile: its buffered
    reader (for reading). check_code(code) -> (ok, error_message). env: the
    kiosk user's session env.
    """
    global _sessions
    send_lock = threading.Lock()

    def fail(message):
        try:
            send_frame(sock, json.dumps({'type': 'error', 'message': message}).encode(), 0x1, send_lock)
            send_frame(sock, b'', 0x8, send_lock)
        except OSError:
            pass

    sock.settimeout(30)
    try:
        opcode, payload = recv_frame(rfile)
        hello = json.loads(payload) if opcode == 0x1 else {}
    except (ConnectionError, OSError, ValueError):
        return
    if hello.get('type') != 'auth':
        return fail('Expected auth')
    ok, error = check_code(hello.get('code', ''))
    if not ok:
        return fail(error)

    with _sessions_lock:
        if _sessions >= MAX_SESSIONS:
            return fail(f'Too many open shells (max {MAX_SESSIONS})')
        _sessions += 1
    master = slave = proc = None
    try:
        master, slave = os.openpty()
        _set_size(slave, hello.get('cols'), hello.get('rows'))
        shell_env = dict(env, TERM='xterm-256color', SHELL='/bin/bash')
        # setsid -c: new session with the pty as its controlling terminal, so
        # job control and Ctrl-C behave like a normal login.
        proc = subprocess.Popen(
            ['setsid', '-c', 'runuser', '-u', user, '--', 'env', '-i']
            + [f'{k}={v}' for k, v in shell_env.items()] + ['bash', '-l'],
            stdin=slave, stdout=slave, stderr=slave, cwd=env.get('HOME', '/'), close_fds=True)
        os.close(slave)
        slave = None
        sock.settimeout(None)

        def pump_output():
            try:
                while True:
                    ready, _, _ = select.select([master], [], [], 1.0)
                    if proc.poll() is not None and not ready:
                        break
                    if ready:
                        data = os.read(master, 65536)
                        if not data:
                            break
                        send_frame(sock, data, 0x2, send_lock)
            except OSError:
                pass
            finally:
                try:
                    send_frame(sock, b'', 0x8, send_lock)
                    sock.shutdown(2)
                except OSError:
                    pass

        threading.Thread(target=pump_output, daemon=True).start()

        while proc.poll() is None:
            try:
                opcode, payload = recv_frame(rfile)
            except (ConnectionError, OSError):
                break
            if opcode == 0x8:
                break
            if opcode == 0x9:
                send_frame(sock, payload, 0xA, send_lock)
                continue
            if opcode != 0x1:
                continue
            try:
                msg = json.loads(payload)
            except ValueError:
                continue
            if msg.get('type') == 'input' and isinstance(msg.get('data'), str):
                os.write(master, msg['data'].encode())
            elif msg.get('type') == 'resize':
                _set_size(master, msg.get('cols'), msg.get('rows'))
    finally:
        if proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGHUP)
                proc.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
        for fd in (master, slave):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        with _sessions_lock:
            _sessions -= 1
