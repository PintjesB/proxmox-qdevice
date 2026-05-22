#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Container entrypoint for proxmox-qdevice.
#
# This script performs first-boot initialization, such as setting the root
# password, installing SSH authorized keys and generating host keys, and
# then starts corosync-qnetd and, optionally, sshd.  Behaviour is
# controlled entirely via environment variables so that no edits are
# required when deploying with Docker Compose or a similar orchestrator.

set -eu

info() {
  echo "[init] $*"
}

fatal() {
  echo "[init] ERROR: $*" >&2
  exit 1
}

# If a validation script is present in the image, run it early to
# detect misconfigurations.  The script exits with non-zero status on
# fatal errors and zero on warnings.
if [ -x /usr/local/bin/validate_env.sh ]; then
  /usr/local/bin/validate_env.sh || exit 1
fi

# Determine the requested mode.  The mode controls whether the
# container starts the SSH daemon.  Valid values are:
#   setup   – always start SSH
#   runtime – never start SSH
#   auto    – start SSH unless an existing qdevice configuration is detected
QDEVICE_MODE="${QDEVICE_MODE:-runtime}"

# Optional user and group to run the corosync-qnetd daemon as.  Running
# qnetd as an unprivileged user is recommended by Proxmox【59303623124675†L1490-L1496】.
# If unset or set to "root" the daemon will run as root.
QNETD_USER="${QNETD_USER:-}"
QNETD_GROUP="${QNETD_GROUP:-}"

# Root password handling.  Prefer ROOT_PASSWORD_FILE to avoid
# exposing secrets in environment variables.  NEW_ROOT_PASSWORD is
# honoured for backwards compatibility.
ROOT_PASSWORD="${ROOT_PASSWORD:-}" || true
ROOT_PASSWORD_FILE="${ROOT_PASSWORD_FILE:-}" || true
if [ -z "${ROOT_PASSWORD}" ] && [ -n "${NEW_ROOT_PASSWORD:-}" ]; then
  ROOT_PASSWORD="${NEW_ROOT_PASSWORD}"
fi
if [ -n "${ROOT_PASSWORD_FILE}" ] && [ -f "${ROOT_PASSWORD_FILE}" ]; then
  ROOT_PASSWORD="$(cat "${ROOT_PASSWORD_FILE}")"
fi

# Root authorised keys.  If both a value and a file are provided,
# the file takes precedence.
ROOT_AUTHORIZED_KEYS="${ROOT_AUTHORIZED_KEYS:-}" || true
ROOT_AUTHORIZED_KEYS_FILE="${ROOT_AUTHORIZED_KEYS_FILE:-}" || true

# The corosync directory used for detecting whether setup has
# completed.  This value is not overridable because it must match the
# location used by corosync-qnetd and pvecm.  If you persist
# /etc/corosync this directory will remain across container restarts.
COROSYNC_DIR="/etc/corosync"

# The directory where SSH host keys live.  Always /etc/ssh.  Persist
# this directory to retain host identity across restarts.
SSH_HOST_KEYS_DIR="/etc/ssh"

# Determine whether to start the SSH daemon.  The default depends on
# the selected mode:
#   setup → true
#   runtime → false
#   auto → true (adjusted later after detection)
case "$QDEVICE_MODE" in
  setup)
    SSHD_ENABLED="true"
    ;;
  runtime)
    SSHD_ENABLED="false"
    ;;
  auto)
    SSHD_ENABLED="true"
    ;;
  *)
    info "Unknown QDEVICE_MODE '$QDEVICE_MODE'; defaulting to 'runtime'"
    QDEVICE_MODE="runtime"
    SSHD_ENABLED="false"
    ;;
esac

# Log the derived configuration.  QNETD always runs and therefore is
# not configurable via an environment variable.
info "QDEVICE_MODE=$QDEVICE_MODE"
info "SSHD_ENABLED=$SSHD_ENABLED"

# Set the root password if provided.  We check for a non-empty value
# rather than the variable being defined so that blank passwords are
# not inadvertently set.
if [ -n "$ROOT_PASSWORD" ]; then
  info "Setting root password from provided environment or file"
  echo "root:${ROOT_PASSWORD}" | chpasswd
fi

init_sshd_config() {
  if [ "$SSHD_ENABLED" = "true" ] && [ ! -f /etc/ssh/sshd_config ]; then
    info "Initializing /etc/ssh from image defaults"
    mkdir -p /etc/ssh
    cp -a /usr/share/proxmox-qdevice/ssh-defaults/. /etc/ssh/
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  fi
}

# Configure root authorized keys if provided.  Only append keys if
# either ROOT_AUTHORIZED_KEYS or the file is non-empty.
install_root_authorized_keys() {
  keys=""
  if [ -n "$ROOT_AUTHORIZED_KEYS_FILE" ] && [ -f "$ROOT_AUTHORIZED_KEYS_FILE" ]; then
    keys="$(cat "$ROOT_AUTHORIZED_KEYS_FILE")"
  elif [ -n "$ROOT_AUTHORIZED_KEYS" ]; then
    keys="$ROOT_AUTHORIZED_KEYS"
  fi
  if [ -n "$keys" ]; then
    info "Installing root SSH authorized keys"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    # Append keys to authorized_keys (preserving any existing ones).  Use
    # grep -qx to avoid duplicates.
    IFS='\n'
    for key in $keys; do
      key_trimmed="$(echo "$key" | sed 's/[[:space:]]*$//')"
      if [ -n "$key_trimmed" ]; then
        if ! grep -q -x -F "$key_trimmed" /root/.ssh/authorized_keys 2>/dev/null; then
          echo "$key_trimmed" >> /root/.ssh/authorized_keys
        fi
      fi
    done
    unset IFS
    chmod 600 /root/.ssh/authorized_keys
  fi
}

init_sshd_config

install_root_authorized_keys

# Generate SSH host keys if configured to do so and at least one key
# type is missing.  The openssh package normally generates host keys
# on installation, but if /etc/ssh has been persisted into an empty
# volume this will not happen automatically.  We do not expose an
# environment variable: best practice is to generate keys whenever
# they are missing.
generate_host_keys() {
  # Determine if keys exist.  We look for commonly used key types.  If
  # any are missing, we regenerate all keys with ssh-keygen -A.  We
  # suppress output to avoid revealing paths or keys.
  missing="false"
  for type in rsa ecdsa ed25519; do
    if [ ! -s "$SSH_HOST_KEYS_DIR/ssh_host_${type}_key" ]; then
      missing="true"
      break
    fi
  done
  if [ "$missing" = "true" ]; then
    info "Generating missing SSH host keys"
    ssh-keygen -A >/dev/null 2>&1
  fi
}

# Always generate host keys if any key type is missing.
generate_host_keys

# Automatically determine whether qdevice setup has completed.  When
# QDEVICE_MODE=auto we enable or disable SSH based on the presence of
# the qnetd NSS database.  According to the corosync‑qdevice
# documentation, the certificate database used for the qnet network
# resides under /etc/corosync/qdevice/net/nssdb and the QNetd CA
# certificate is stored on the server in
# /etc/corosync/qnetd/nssdb【801658067884498†L60-L63】.  We treat the
# existence of either of these files as evidence that setup has
# completed.  A failure to detect them causes SSH to remain enabled
# so that `pvecm qdevice setup` can be executed.
detect_setup_complete() {
  # Check for the QNetd CA certificate or NSS database created
  # during pvecm qdevice setup.  Either path is considered valid.
  if [ -f "$COROSYNC_DIR/qnetd/nssdb/qnetd-cacert.crt" ] || [ -d "$COROSYNC_DIR/qdevice/net/nssdb" ]; then
    return 0
  fi
  return 1
}

# When /etc/corosync is backed by a new host volume, the qnetd NSS
# database created by the package post-install script is hidden by the
# mount.  corosync-qnetd refuses to start without this database and
# exits with "Can't open NSS DB directory".  Initialise the server-side
# NSS database when it is missing.  This is safe for setup and runtime
# images because the command is skipped when the persisted database
# already exists.
init_qnetd_nssdb() {
  if [ -f "$COROSYNC_DIR/qnetd/nssdb/qnetd-cacert.crt" ]; then
    return 0
  fi

  if [ -d "$COROSYNC_DIR/qnetd/nssdb" ] && [ -n "$(ls -A "$COROSYNC_DIR/qnetd/nssdb" 2>/dev/null || true)" ]; then
    info "qnetd NSS DB directory exists but qnetd CA certificate is missing"
    info "Leaving existing NSS DB untouched"
    return 0
  fi

  if ! command -v corosync-qnetd-certutil >/dev/null 2>&1; then
    fatal "corosync-qnetd-certutil is missing and qnetd NSS DB has not been initialized"
  fi

  info "Initializing qnetd NSS DB"
  mkdir -p "$COROSYNC_DIR/qnetd"
  corosync-qnetd-certutil -i
}

# Apply automatic mode detection if requested.  We update the
# SSHD_ENABLED value here so that downstream logic uses the correct
# service configuration.
if [ "$QDEVICE_MODE" = "auto" ]; then
  if detect_setup_complete; then
    info "Auto mode: existing qdevice configuration detected, disabling SSH"
    SSHD_ENABLED="false"
  else
    info "Auto mode: no qdevice configuration detected, enabling SSH for setup"
    SSHD_ENABLED="true"
  fi
fi

# Prepare functions to start services.
start_sshd() {
  # Ensure runtime directory exists
  mkdir -p /run/sshd
  # Start sshd in the background.  Use -D to run in the foreground and
  # -e to send logs to stderr, but we background it to allow running
  # alongside corosync-qnetd.  If sshd exits unexpectedly the
  # container will exit when qnetd does.
  info "Starting sshd"
  /usr/sbin/sshd -D -e &
  SSHD_PID=$!
}

start_qnetd() {
  info "Starting corosync-qnetd"
  # If a QNETD_USER is specified and not root, attempt to run qnetd
  # under that user.  Change ownership of /etc/corosync and the
  # state directory so that the unprivileged user can read and write
  # necessary files.  Then exec the daemon as the specified user.
  if [ -n "$QNETD_USER" ] && [ "$QNETD_USER" != "root" ]; then
    QNETD_GROUP_EFFECTIVE="${QNETD_GROUP:-$QNETD_USER}"
    if [ -d /etc/corosync ]; then
      chown -R "$QNETD_USER":"$QNETD_GROUP_EFFECTIVE" /etc/corosync 2>/dev/null || true
    fi
    if [ -d /var/lib/qnetd ]; then
      chown -R "$QNETD_USER":"$QNETD_GROUP_EFFECTIVE" /var/lib/qnetd 2>/dev/null || true
    fi
    # Use runuser to drop privileges without requiring a login shell.
    exec runuser -u "$QNETD_USER" -- /usr/bin/corosync-qnetd -f
  else
    # Default: run as root
    exec /usr/bin/corosync-qnetd -f
  fi
}

# Start sshd if requested.  SSH runs in the background so that
# corosync-qnetd can replace PID 1.  If SSH is disabled we simply do
# nothing here.
if [ "$SSHD_ENABLED" = "true" ]; then
  start_sshd
fi

# Ensure qnetd can start when /etc/corosync is an initially empty
# persisted host volume.
init_qnetd_nssdb

# Always start the qnetd service.  This call will 'exec' the daemon and
# replace the shell with corosync-qnetd.
start_qnetd