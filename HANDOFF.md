# Build Handoff - v1.3.1

## Current Status

**Build**: https://github.com/lumencanvas/ossuary-pi/actions/runs/21164905744

| Job | Status | Notes |
|-----|--------|-------|
| arm64 | in_progress | Should complete ~60 min total |
| armhf | **FAILED** | pi-gen-action doesn't support 32-bit on GH Actions |

## armhf Failure Root Cause

The `master` branch of pi-gen (for 32-bit) requires an i386 Docker environment. GitHub Actions runners are amd64. The pi-gen-action uses `i386/debian:trixie` as its Docker base regardless of our `release: bookworm` setting.

**This is a fundamental limitation of pi-gen-action on GitHub Actions - 32-bit builds don't work.**

## Recommended Fix

Remove armhf from CI, build 64-bit only. Users needing 32-bit can:
- Build locally with pi-gen
- Use the manual install script on existing Pi OS

## Quick Commands

```bash
# Check arm64 status
gh run view 21164905744 --json jobs --jq '.jobs[] | select(.name | contains("arm64")) | "\(.status) \(.conclusion // "")"'

# After arm64 completes, check release
gh release view v1.3.1

# If release upload fails, manual upload:
gh run download 21164905744 --name ossuary-pi-image-arm64 --dir /tmp/release
gh release upload v1.3.1 /tmp/release/*.zip --clobber
```

## To Remove armhf from CI

Edit `.github/workflows/build-image.yml`, remove armhf from matrix:
```yaml
matrix:
  include:
    - name: arm64
      pi_gen_version: arm64
      release: trixie
    # armhf removed - doesn't work on GH Actions
```

Update README to only list arm64 download.
