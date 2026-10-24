#!/usr/bin/env python3
"""
Ossuary display resolution, via wlr-randr in the kiosk user's Wayland session.

Used two ways:
  - imported by config-server.py (list modes, try one, keep or revert it);
  - run by process-manager.sh before it starts the kiosk command, so the saved
    mode is applied at every boot:  display_mode.py apply <kiosk-user>

The saved choice lives in /etc/ossuary/config.json as
  "display": {"outputs": {"HDMI-A-2": "1280x720@60.000000"},
              "transforms": {"HDMI-A-2": "180"}}
An output with no entry (or "auto") uses the screen's preferred mode; one with
no transform is left as it is ("normal" = unrotated).
"""

import json
import os
import pwd
import re
import subprocess
import sys

CONFIG_FILE = "/etc/ossuary/config.json"
MODE_RE = re.compile(r'^\d{2,5}x\d{2,5}(@\d{1,3}(\.\d+)?)?$')
OUTPUT_RE = re.compile(r'^[A-Za-z0-9_.-]{1,40}$')
# wlr-randr's names: rotation clockwise, "flipped" = mirrored horizontally first.
TRANSFORMS = ('normal', '90', '180', '270', 'flipped', 'flipped-90', 'flipped-180', 'flipped-270')


def session_env(user):
    pw = pwd.getpwnam(user)
    runtime = f"/run/user/{pw.pw_uid}"
    env = {'HOME': pw.pw_dir, 'USER': user, 'LOGNAME': user,
           'PATH': '/usr/local/bin:/usr/bin:/bin', 'XDG_RUNTIME_DIR': runtime}
    try:
        sockets = sorted(n for n in os.listdir(runtime) if re.fullmatch(r'wayland-\d+', n))
    except OSError:
        sockets = []
    if sockets:
        env['WAYLAND_DISPLAY'] = sockets[0]
    return env


def wlr_randr(user, args, timeout=10):
    env = session_env(user)
    if 'WAYLAND_DISPLAY' not in env:
        raise RuntimeError('No Wayland session (resolution control needs the desktop session)')
    cmd = ['runuser', '-u', user, '--', 'env', '-i'] + [f'{k}={v}' for k, v in env.items()] + ['wlr-randr'] + args
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def list_outputs(user):
    """[{name, enabled, current, preferred, modes: [{mode, label}]}] from `wlr-randr --json`."""
    r = wlr_randr(user, ['--json'])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or 'wlr-randr failed')
    outputs = []
    for o in json.loads(r.stdout or '[]'):
        modes, seen, current, preferred = [], set(), None, None
        for m in o.get('modes', []):
            mode = f"{m['width']}x{m['height']}@{m['refresh']:.6f}"
            if m.get('current'):
                current = mode
            if m.get('preferred'):
                preferred = mode
            key = (m['width'], m['height'], round(m['refresh']))
            if key in seen:
                continue
            seen.add(key)
            modes.append({'mode': mode, 'label': f"{m['width']}×{m['height']} @ {m['refresh']:.0f} Hz",
                          'pixels': m['width'] * m['height']})
        modes.sort(key=lambda m: (-m['pixels'], -float(m['mode'].split('@')[1])))
        outputs.append({'name': o.get('name'), 'enabled': o.get('enabled', True),
                        'current': current, 'preferred': preferred,
                        'transform': o.get('transform') or 'normal',
                        'modes': [{'mode': m['mode'], 'label': m['label']} for m in modes]})
    return outputs


def set_mode(user, output, mode):
    """mode: 'WxH@R', or 'auto' for the screen's preferred mode."""
    if not OUTPUT_RE.match(output or ''):
        raise ValueError('Invalid output name')
    if mode == 'auto':
        args = ['--output', output, '--preferred']
    elif MODE_RE.match(mode or ''):
        args = ['--output', output, '--mode', mode]
    else:
        raise ValueError('Invalid mode')
    r = wlr_randr(user, args)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or 'Could not set the mode')


def set_transform(user, output, transform):
    if not OUTPUT_RE.match(output or ''):
        raise ValueError('Invalid output name')
    if transform not in TRANSFORMS:
        raise ValueError('Invalid rotation')
    r = wlr_randr(user, ['--output', output, '--transform', transform])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or 'Could not rotate the screen')


def _saved(key, config_file):
    try:
        with open(config_file) as f:
            values = (json.load(f).get('display') or {}).get(key) or {}
        return {k: v for k, v in values.items() if isinstance(k, str) and isinstance(v, str)}
    except (OSError, ValueError, AttributeError):
        return {}


def saved_modes(config_file=CONFIG_FILE):
    return _saved('outputs', config_file)


def saved_transforms(config_file=CONFIG_FILE):
    return {k: v for k, v in _saved('transforms', config_file).items() if v in TRANSFORMS}


def apply_saved(user):
    """Apply the saved mode for every connected output that has one."""
    try:
        found = list_outputs(user)
        connected = {o['name']: o['current'] for o in found}
        rotation = {o['name']: o['transform'] for o in found}
    except Exception as e:  # no session yet, wlr-randr missing...
        print(f"[display] not applied: {e}", file=sys.stderr)
        return
    for output, mode in saved_modes().items():
        # Skip a mode that is already on: re-setting it can blank the screen briefly.
        if output in connected and mode != 'auto' and connected[output] != mode:
            try:
                set_mode(user, output, mode)
                print(f"[display] {output} -> {mode}")
            except Exception as e:
                print(f"[display] {output} {mode} failed: {e}", file=sys.stderr)
    for output, transform in saved_transforms().items():
        if output in rotation and rotation[output] != transform:
            try:
                set_transform(user, output, transform)
                print(f"[display] {output} rotated {transform}")
            except Exception as e:
                print(f"[display] {output} rotate {transform} failed: {e}", file=sys.stderr)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'apply':
        apply_saved(sys.argv[2])
    else:
        print('usage: display_mode.py apply <kiosk-user>', file=sys.stderr)
        sys.exit(2)
