#!/bin/sh

# This script has been retained for backward compatibility. It
# intentionally avoids shell tracing (set -x) to prevent leaking
# sensitive information such as passwords into container logs.  It
# simply reads the environment variable NEW_ROOT_PASSWORD and, if
# defined and non-empty, resets the root password accordingly.

if [ -n "${NEW_ROOT_PASSWORD:-}" ]; then
  echo "root:${NEW_ROOT_PASSWORD}" | chpasswd
fi
