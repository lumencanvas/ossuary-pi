# Multiple Processes Feature - Architecture Plan

## Overview

This document outlines the plan for supporting multiple managed processes in Ossuary Pi, enabling users to run one display/Chromium process alongside multiple background processes.

## User Requirements

1. **One Chromium at a time** - Only one browser/display process (LumenCanvas, Web Kiosk)
2. **Display selection** - Ability to choose which display (`:0`, `:1`, etc.) for the browser
3. **Multiple background processes** - Unlimited non-Chromium processes (scripts, servers, etc.)
4. **Named processes** - Each process has a user-defined name
5. **CRUD operations** - Add, edit, delete processes
6. **Schedule integration** - Schedules can reference any named process

## Architecture Changes

### 1. Config Schema Update

**Current schema:**
```json
{
  "startup_command": "chromium --kiosk ...",
  "behaviors": {...},
  "schedule": {...}
}
```

**Proposed schema (v3):**
```json
{
  "version": 3,
  "processes": {
    "main-display": {
      "id": "main-display",
      "name": "Gallery Display",
      "type": "chromium",
      "command": "chromium --kiosk https://lumencanvas.studio/canvas/abc",
      "display": ":0",
      "enabled": true,
      "autostart": true,
      "restart_on_crash": true,
      "flags": {
        "kiosk": true,
        "webgpu": true,
        "autoplay": true
      }
    },
    "data-sync": {
      "id": "data-sync",
      "name": "Data Sync Service",
      "type": "custom",
      "command": "python3 /home/pi/sync.py",
      "enabled": true,
      "autostart": true,
      "restart_on_crash": true
    },
    "api-server": {
      "id": "api-server",
      "name": "Local API Server",
      "type": "custom",
      "command": "node /home/pi/server.js",
      "enabled": true,
      "autostart": true,
      "restart_on_crash": false
    }
  },
  "active_display_process": "main-display",
  "behaviors": {...},
  "schedule": {
    "enabled": true,
    "rules": [
      {
        "id": "morning-switch",
        "name": "Switch to Morning Canvas",
        "trigger": {"type": "time", "time": "08:00", "days": ["mon","tue","wed","thu","fri"]},
        "action": {
          "type": "update_process",
          "process_id": "main-display",
          "updates": {
            "command": "chromium --kiosk https://lumencanvas.studio/canvas/morning"
          }
        }
      },
      {
        "id": "restart-sync",
        "name": "Restart sync daily",
        "trigger": {"type": "time", "time": "03:00", "days": ["*"]},
        "action": {
          "type": "restart_process",
          "process_id": "data-sync"
        }
      }
    ]
  }
}
```

### 2. Process Manager Updates

**File:** `scripts/process-manager.sh`

Changes needed:
- Parse multiple processes from config
- Track PID for each process separately
- Enforce one-Chromium rule (kill existing before starting new)
- Support per-process restart policies
- SIGHUP reloads all process configs

**New functions:**
```bash
# Load all processes from config
load_processes() {...}

# Start a specific process by ID
start_process(process_id) {...}

# Stop a specific process by ID
stop_process(process_id) {...}

# Check if a Chromium process is already running
is_chromium_running() {...}

# Start all autostart processes
start_all_autostart() {...}

# Handle SIGHUP - reload and reconcile
handle_reload() {...}
```

**PID file structure:**
```
/run/ossuary/
├── manager.pid           # Process manager PID
├── main-display.pid      # Individual process PIDs
├── data-sync.pid
└── api-server.pid
```

### 3. Config Server API Updates

**File:** `scripts/config-server.py`

New endpoints:

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/processes` | List all processes with status |
| POST | `/api/processes` | Create new process |
| GET | `/api/processes/{id}` | Get process details |
| PUT | `/api/processes/{id}` | Update process |
| DELETE | `/api/processes/{id}` | Delete process |
| POST | `/api/processes/{id}/start` | Start process |
| POST | `/api/processes/{id}/stop` | Stop process |
| POST | `/api/processes/{id}/restart` | Restart process |
| GET | `/api/displays` | List available displays |

**Response example for GET /api/processes:**
```json
{
  "processes": {
    "main-display": {
      "id": "main-display",
      "name": "Gallery Display",
      "type": "chromium",
      "enabled": true,
      "status": "running",
      "pid": 1234,
      "uptime": 3600,
      "restarts": 0
    },
    "data-sync": {
      "id": "data-sync",
      "name": "Data Sync Service",
      "type": "custom",
      "enabled": true,
      "status": "stopped",
      "pid": null
    }
  },
  "active_display": "main-display"
}
```

### 4. Web UI Updates

**File:** `custom-ui/index.html`

New "Processes" tab replacing current Display tab:

```
┌──────────────────────────────────────────────────────┐
│  PROCESSES                                           │
├──────────────────────────────────────────────────────┤
│  ┌────────────────────────────────────────────────┐  │
│  │ Gallery Display          [RUNNING] [DISPLAY]   │  │
│  │ chromium --kiosk https://lumen...              │  │
│  │ Display :0 • WebGPU • Kiosk                    │  │
│  │                      [Edit] [Stop] [Delete]    │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │ Data Sync Service           [RUNNING]          │  │
│  │ python3 /home/pi/sync.py                       │  │
│  │ Uptime: 2h 15m • Restarts: 0                   │  │
│  │                   [Edit] [Restart] [Delete]    │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │ Local API Server            [STOPPED]          │  │
│  │ node /home/pi/server.js                        │  │
│  │                       [Edit] [Start] [Delete]  │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  [+ Add Display Process]  [+ Add Background Process] │
└──────────────────────────────────────────────────────┘
```

**Add Display Process modal:**
- Same presets as before (LumenCanvas, Web Kiosk, Custom)
- Additional "Display" dropdown (`:0`, `:1`, etc.)
- Warning if display process already exists

**Add Background Process modal:**
- Name field
- Command textarea
- Restart on crash toggle
- Autostart toggle

### 5. Schedule Integration

Schedules can now reference processes by ID:

```json
{
  "action": {
    "type": "switch_canvas",
    "process_id": "main-display",
    "url": "https://lumencanvas.studio/canvas/evening"
  }
}
```

```json
{
  "action": {
    "type": "restart_process",
    "process_id": "data-sync"
  }
}
```

```json
{
  "action": {
    "type": "enable_process",
    "process_id": "api-server"
  }
}
```

### 6. Migration Path

**Backward compatibility:**
- Detect `startup_command` (v1/v2 config)
- Auto-migrate to v3 format on first load
- Create single process named "main-display" from startup_command

```python
def migrate_config(config):
    if 'version' not in config or config['version'] < 3:
        # Migrate from v1/v2
        old_command = config.get('startup_command', '')
        config['version'] = 3
        config['processes'] = {}

        if old_command:
            config['processes']['main-display'] = {
                'id': 'main-display',
                'name': 'Main Display',
                'type': 'chromium' if 'chromium' in old_command else 'custom',
                'command': old_command,
                'display': ':0',
                'enabled': True,
                'autostart': True,
                'restart_on_crash': True
            }
            config['active_display_process'] = 'main-display'

        # Remove old field
        config.pop('startup_command', None)

    return config
```

## Implementation Order

### Phase 1: Backend Foundation
1. Update config schema to v3
2. Implement migration in config-server.py
3. Update process-manager.sh for multi-process
4. Add new API endpoints

### Phase 2: UI Updates
1. Create Processes tab
2. Build process cards component
3. Add/Edit process modals
4. Display selection for Chromium processes

### Phase 3: Schedule Integration
1. Update schedule action types
2. Add process selector to schedule modal
3. Update schedule execution in connection-monitor

### Phase 4: Polish
1. Process status indicators (uptime, restart count)
2. Log viewing per process
3. Process output streaming (websocket?)

## Constraints and Rules

1. **One Chromium Rule**: Only one process with `type: "chromium"` can run at a time. Starting a new display process stops the existing one.

2. **Display Lock**: Each display (`:0`, `:1`) can only have one process targeting it.

3. **Process IDs**: Must be unique, URL-safe strings. Auto-generated if not provided.

4. **Naming**: Names are user-facing, IDs are for internal reference.

5. **Deletion Protection**: Cannot delete a running process. Must stop first.

## Files to Modify

| File | Changes |
|------|---------|
| `scripts/process-manager.sh` | Multi-process management |
| `scripts/config-server.py` | New API endpoints, migration |
| `custom-ui/index.html` | New Processes tab, modals |
| `scripts/connection-monitor.sh` | Schedule action handlers |
| `install.sh` | No changes needed |

## Open Questions

1. **Process Dependencies**: Should processes be able to depend on each other? (e.g., API server must start before display)

2. **Resource Limits**: Should we add CPU/memory limits per process?

3. **Log Rotation**: How to handle logs for multiple long-running processes?

4. **Hot-swap Display**: When switching displays, should we fade transition or hard cut?

---

*This plan is for discussion and may be modified based on feedback.*
