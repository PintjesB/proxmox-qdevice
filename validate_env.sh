#!/bin/sh
# Validate environment variables for proxmox-qdevice.
#
# This script performs a few basic checks to help detect common
# misconfigurations.  It can be run manually or invoked by
# orchestration tools prior to starting the container.  It exits with
# status 0 even if warnings are emitted.  Fatal errors cause a non‑zero
# exit code.

set -eu

warn() {
  echo "[validate_env] WARNING: $*" >&2
}

fatal() {
  echo "[validate_env] ERROR: $*" >&2
  exit 1
}

# Warn about deprecated environment variables that are no longer
# respected.  These variables were previously used to enable or
# disable services or to override default directories.  Best
# practices are now enforced unconditionally and these variables have
# no effect.
if [ -n "${QNETD_ENABLED:-}" ]; then
  warn "QNETD_ENABLED is deprecated and ignored; qnetd always runs"
fi
if [ -n "${SSHD_ENABLED:-}" ]; then
  warn "SSHD_ENABLED is deprecated; use QDEVICE_MODE to control SSH"
fi
if [ -n "${GENERATE_SSH_HOST_KEYS:-}" ]; then
  warn "GENERATE_SSH_HOST_KEYS is deprecated; host keys are always generated when missing"
fi
if [ -n "${SSH_HOST_KEYS_DIR:-}" ]; then
  warn "SSH_HOST_KEYS_DIR is deprecated; host keys are always stored in /etc/ssh"
fi
if [ -n "${COROSYNC_DIR:-}" ]; then
  warn "COROSYNC_DIR is deprecated and ignored; corosync data lives in /etc/corosync"
fi

QDEVICE_MODE="${QDEVICE_MODE:-runtime}"

# Derive SSHD state based solely on QDEVICE_MODE.  In auto mode we
# assume SSH may be required for setup and warn accordingly.  Unknown
# values default to runtime semantics (SSH disabled).
case "$QDEVICE_MODE" in
  setup)
    SSHD_ENABLED="true";;
  runtime)
    SSHD_ENABLED="false";;
  auto)
    SSHD_ENABLED="true";;
  *)
    warn "Unknown QDEVICE_MODE '$QDEVICE_MODE'; defaulting to runtime mode for validation"
    SSHD_ENABLED="false";;
esac

# Warn if SSH is enabled but no authentication material is provided.
if [ "$SSHD_ENABLED" = "true" ]; then
  if [ -z "${ROOT_PASSWORD:-}" ] \
     && [ -z "${ROOT_PASSWORD_FILE:-}" ] \
     && [ -z "${ROOT_AUTHORIZED_KEYS:-}" ] \
     && [ -z "${ROOT_AUTHORIZED_KEYS_FILE:-}" ] \
     && [ -z "${NEW_ROOT_PASSWORD:-}" ]; then
    warn "SSH is enabled but no root password or authorised keys have been provided.  Login may be insecure."
  fi
fi

# Warn if an unprivileged user is requested but does not exist.
if [ -n "${QNETD_USER:-}" ] && [ "$QNETD_USER" != "root" ]; then
  if ! id "$QNETD_USER" >/dev/null 2>&1; then
    fatal "Specified QNETD_USER '$QNETD_USER' does not exist in the container.  Create it in the Dockerfile or choose another user."
  fi
fi

exit 0