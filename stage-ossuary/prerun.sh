#!/bin/bash -e

# Initialize this stage from the previous stage
echo "=== Stage Ossuary prerun.sh ==="
echo "ROOTFS_DIR: ${ROOTFS_DIR}"
echo "PREV_ROOTFS_DIR: ${PREV_ROOTFS_DIR:-not set}"
echo "STAGE_WORK_DIR: ${STAGE_WORK_DIR:-not set}"

if [ ! -d "${ROOTFS_DIR}" ]; then
    echo "ROOTFS_DIR does not exist, calling copy_previous..."
    copy_previous
    echo "copy_previous completed"
else
    echo "ROOTFS_DIR already exists"
fi

echo "Verifying ROOTFS_DIR contents:"
ls -la "${ROOTFS_DIR}" | head -10

echo "Stage ossuary initialized from previous stage"
