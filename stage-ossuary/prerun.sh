#!/bin/bash -e

# Initialize this stage from the previous stage
if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi

echo "Stage ossuary initialized from previous stage"
