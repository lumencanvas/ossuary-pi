# Pi-Gen Build Failure Investigation

*Created: 2026-01-19*
*Status: **RESOLVED** - Build 21131506328 succeeded on 2026-01-19*

## The Problem

The GitHub Actions pi-gen build consistently fails with this error:

```
Unable to chroot/chdir to [/pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/]
```

All three recent builds (v1.1.0, v1.2.0, v1.2.1) fail with the identical error.

## Build Timeline (What Works vs Fails)

```
✓ stage0, stage1, stage2 - All complete successfully (~40 minutes)
✓ stage-ossuary/prerun.sh - Completes (copies from previous stage)
✓ stage-ossuary/00-install-ossuary/00-packages - Completes (installs chromium, etc.)
✓ stage-ossuary/00-install-ossuary/00-run.sh - Completes (copies files to rootfs)
✗ stage-ossuary/00-install-ossuary/00-run-chroot.sh - FAILS immediately
```

## Key Observation

The **packages step succeeds** - this means:
1. The rootfs EXISTS at that point (packages are installed INTO the rootfs)
2. The chroot mechanism WORKS at that point
3. Something happens BETWEEN 00-packages and 00-run-chroot.sh

## Error Details

```
realpath: /pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/proc: No such file or directory
realpath: /pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/dev: No such file or directory
realpath: /pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/dev/pts: No such file or directory
realpath: /pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/sys: No such file or directory
realpath: /pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/run: No such file or directory
realpath: /pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/tmp: No such file or directory
Unable to chroot/chdir to [/pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/]
```

The `realpath` errors suggest the rootfs directory itself doesn't exist, not just the mount points.

## Current Stage Files

### stage-ossuary/prerun.sh
```bash
#!/bin/bash -e

if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi

echo "Stage ossuary initialized from previous stage"
```

### stage-ossuary/00-install-ossuary/00-packages
```
git
curl
wget
network-manager
python3
python3-pip
chromium
xdotool
dnsmasq
hostapd
```

### stage-ossuary/00-install-ossuary/00-run.sh
```bash
#!/bin/bash -e

install -d "${ROOTFS_DIR}/opt/ossuary"
install -d "${ROOTFS_DIR}/etc/ossuary"

if [ -d "files/ossuary-pi" ]; then
    cp -rv files/ossuary-pi/* "${ROOTFS_DIR}/opt/ossuary/"
fi

chmod +x "${ROOTFS_DIR}/opt/ossuary/install.sh" 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.sh 2>/dev/null || true
chmod +x "${ROOTFS_DIR}/opt/ossuary/scripts/"*.py 2>/dev/null || true
```

### stage-ossuary/00-install-ossuary/00-run-chroot.sh
```bash
#!/bin/bash -e

on_chroot << 'CHROOT_EOF'
set -e

INSTALL_DIR="/opt/ossuary"
# ... creates systemd services, enables them, downloads wifi-connect ...
CHROOT_EOF
```

## Hypotheses

### 1. Stage Directory Structure Issue
Pi-gen might expect a specific directory structure. Our stage is at `./stage-ossuary` but pi-gen might be looking for rootfs at a different path.

**Research**: Check how pi-gen resolves `${ROOTFS_DIR}` for custom stages passed with `./` prefix.

### 2. copy_previous Not Working Correctly
The `copy_previous` function should copy rootfs from stage2. Maybe it's creating a symlink or something that breaks between steps.

**Research**: Look at pi-gen's `copy_previous` implementation in `scripts/common`.

### 3. 00-run.sh Breaking the Rootfs
Something in our `00-run.sh` might be corrupting or removing the rootfs, even though it appears to complete successfully.

**Research**: Check if `cp -rv` or `chmod` could cause issues. Try removing 00-run.sh entirely to test.

### 4. GitHub Actions Runner Issue
The runner might be running out of disk space or memory between steps, causing the rootfs to be unmounted or deleted.

**Research**: Check if `increase-runner-disk-size: true` is actually working. Look at runner disk usage.

### 5. pi-gen Action Bug
The `usimd/pi-gen-action@v1` might have a bug with custom stages.

**Research**: Check the action's GitHub issues for similar problems. Try using a different version or running pi-gen directly.

### 6. ROOTFS_DIR Path Resolution
The path `/pi-gen/work/ossuary-pi-v1.2.1/stage-ossuary/rootfs/` is unusual - normally rootfs is at `work/<image>/rootfs/` not `work/<image>/stage-ossuary/rootfs/`.

**Research**: This might be the key issue - pi-gen might be looking in the wrong place.

## Things Already Tried

1. ✗ Removed `#!/bin/bash -e` from inside heredoc in 00-run-chroot.sh
2. ✗ Simplified prerun.sh to only call `copy_previous`
3. ✗ Changed package from `chromium-browser` to `chromium`
4. ✗ Added `increase-runner-disk-size: true`

## Research Resources

### Pi-Gen Documentation & Source
- **Official repo**: https://github.com/RPi-Distro/pi-gen
- **Key files to study**:
  - `scripts/common` - Contains `on_chroot`, `copy_previous` functions
  - `build.sh` - Main build script, shows stage processing logic
  - `export-image/` - Example of a working stage
  - `stage2/` - Example stage structure that works

### Pi-Gen Action
- **Action repo**: https://github.com/usimd/pi-gen-action
- **Issues**: Check for "chroot" or "rootfs" related issues
- **Source**: Look at how it invokes pi-gen and handles custom stages

### Similar Projects Using Custom Stages
- Search GitHub for repos using pi-gen with custom stages
- Look for `stage-list:` in workflow files that include `./` prefixed stages

## Debugging Approaches

### 1. Add Debug Output
Modify 00-run.sh to print debug info:
```bash
#!/bin/bash -ex  # Add -x for trace
echo "ROOTFS_DIR = ${ROOTFS_DIR}"
ls -la "${ROOTFS_DIR}" || echo "ROOTFS_DIR does not exist!"
ls -la "${ROOTFS_DIR}/.." || echo "Parent dir does not exist!"
```

### 2. Skip 00-run-chroot.sh
Rename to `00-run-chroot.sh.skip` - if build succeeds, the issue is in the chroot script.

### 3. Minimal Chroot Test
Replace 00-run-chroot.sh with:
```bash
#!/bin/bash -e
on_chroot << 'EOF'
echo "Chroot works!"
EOF
```

### 4. Check Working Stage
Look at how stage2 is structured and copy that pattern exactly.

### 5. Run Locally with Docker
Clone pi-gen, add our stage, run locally to see full logs:
```bash
git clone https://github.com/RPi-Distro/pi-gen
cp -r stage-ossuary pi-gen/
cd pi-gen
# Edit config, then:
./build-docker.sh
```

## Workflow File Location

`.github/workflows/build-image.yml`

Key settings:
```yaml
uses: usimd/pi-gen-action@v1
with:
  stage-list: stage0 stage1 stage2 ./stage-ossuary
  pi-gen-repository: RPi-Distro/pi-gen
  release: trixie
```

## Failed Build Logs

Can be viewed with:
```bash
gh run view <run-id> --log-failed
gh run view 21128312813 --log  # Full log
```

Recent failed runs:
- v1.2.1: 21128312813
- v1.2.0: 21127155048
- v1.1.0: 21126575197

## Fix Applied (2026-01-19)

### Root Cause Analysis

Based on research into pi-gen's source code:

1. **ROOTFS_DIR Resolution**: For a custom stage like `./stage-ossuary`, pi-gen correctly sets:
   - `STAGE` = `stage-ossuary` (basename)
   - `STAGE_WORK_DIR` = `/pi-gen/work/<image-name>/stage-ossuary`
   - `ROOTFS_DIR` = `/pi-gen/work/<image-name>/stage-ossuary/rootfs`

2. **Script Execution Order**: Within a stage subdirectory, pi-gen processes:
   - `00-packages` (apt-get install via chroot) - WORKS
   - `00-run.sh` (host script) - WORKS
   - `00-run-chroot.sh` (sourced, calls on_chroot) - FAILS

3. **Hypothesis**: Something in the pi-gen-action or pi-gen's script runner may be causing issues when transitioning between separate script files, particularly when the same chroot operations span multiple files.

### Solution

Combined `00-run.sh` and `00-run-chroot.sh` into a single `00-run.sh` script that:
1. Runs host operations (copying files to ROOTFS_DIR)
2. Calls `on_chroot` directly to run chroot operations

This ensures:
- All operations happen in a single script execution
- No mysterious state changes between script files
- Better error reporting with debug output

### Changes Made

1. **`stage-ossuary/00-install-ossuary/00-run.sh`**: Combined script with host ops + `on_chroot` heredoc
2. **`stage-ossuary/00-install-ossuary/00-run-chroot.sh`**: DELETED (merged into 00-run.sh)
3. **`stage-ossuary/prerun.sh`**: Added debug output to see ROOTFS_DIR and copy_previous behavior

## Next Steps

1. ~~Study pi-gen source code, especially `scripts/common` and `build.sh`~~ ✓
2. ~~Look at how `${ROOTFS_DIR}` is set for custom stages with `./` prefix~~ ✓
3. ~~Try the minimal chroot test to isolate the issue~~ (Skipped - applied fix instead)
4. Test the fix by triggering a new build
5. If still failing, check the new debug output for clues

## Alternative Approaches If pi-gen Continues to Fail

1. **Use pi-gen directly** instead of the action (more control but more complex)
2. **Create image differently** - build base image, then use Ansible/cloud-init to configure
3. **Distribute as install script only** - skip pre-built images, have users run `install.sh`
