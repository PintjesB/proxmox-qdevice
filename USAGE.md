# Proxmox Qdevice usage instruction

## Install:

This container is designed to run from either Docker Compose or a container manager, like Portainer.

## Configuration:

This repository exposes a number of environment variables that control
how the container behaves.  You should modify the provided
`docker-compose.yml` (or Portainer stack) to set these variables and
the persistent storage paths.  At minimum you must:

* Choose a `QDEVICE_MODE`.  Use `setup` during initial configuration
  (this enables SSH automatically) and `runtime` for normal
  operation (SSH is disabled).  You can also specify `auto` to
  automatically disable SSH after `pvecm qdevice setup` has been
  completed.  In auto mode the entrypoint keeps SSH enabled until
  the qdevice NSS database appears and then disables SSH on
  subsequent starts.
* Provide the root password via `ROOT_PASSWORD` or, preferably,
  mount a Docker secret into the container and specify
  `ROOT_PASSWORD_FILE=/run/secrets/root_password`.  The legacy
  variable `NEW_ROOT_PASSWORD` is still honoured for backwards
  compatibility but should be replaced.
* Persist `/etc/corosync`, `/root` and `/etc/ssh` in host directories
  so that QNetd state, authorised keys and SSH host keys survive
  container recreation.  Replace `<MY LOCAL STORAGE>` placeholders in
  the sample `docker-compose.yml` with appropriate paths such as
  `/var/lib/proxmox-qdevice/corosync`.
* Set `hostname` and network information (parent interface, IP,
  subnet, gateway) to suit your environment.  The container must be
  reachable by every Proxmox node on TCP port 5403 for QNetd and, if
  using setup mode, on TCP port 22 for SSH.

Additional optional variables include:

* `ROOT_AUTHORIZED_KEYS` or `ROOT_AUTHORIZED_KEYS_FILE` to supply
  public keys for root login.  Authorised keys from the file take
  precedence over the string.  Keys are appended to
  `/root/.ssh/authorized_keys` if not already present.
* `QNETD_USER` and `QNETD_GROUP` to run `corosync-qnetd` as an
  unprivileged user and group.  Proxmox recommends running
  qnetd under an unprivileged account【59303623124675†L1490-L1496】.  If not
  specified or set to `root` then qnetd runs as root.
* `ROOT_PASSWORD_FILE` and `ROOT_AUTHORIZED_KEYS_FILE` to read
  secrets from mounted files, such as Docker secrets.  These take
  precedence over their corresponding environment variables.

### Cluster design considerations

* **Only use QDevices on even‑node clusters.**  Proxmox’s own
  documentation states that QDevices are recommended for clusters
  with an even number of nodes (for example a 2+1 setup) and they
  discourage their use on odd‑node clusters【59303623124675†L1490-L1508】.
* **Remove the QDevice before adding or removing nodes.**  When you
  change the size of your cluster, remove the QDevice first and then
  reconfigure it after the change is complete.  Community guidance on
  Proxmox quorum notes that the QDevice should be removed before
  adding a node to keep the cluster’s node count odd【416444296263342†L137-L140】.
* **Run qnetd as an unprivileged user.**  Proxmox recommends
  running any daemon that provides votes to corosync‑qdevice as an
  unprivileged user【59303623124675†L1520-L1522】.  You can set `QNETD_USER=coroqnetd` in
  your environment to follow this best practice.

For more details on each environment variable see the comments in
`docker-compose.yml` and the `entrypoint.sh` script.

### Distroless runtime image

The distroless image is intentionally runtime-only.  It does not include SSH,
a shell, password tooling or the setup entrypoint.  Build and use the Bookworm
or Trixie image for `pvecm qdevice setup`; after the qdevice state exists and
has been persisted, you can switch to the distroless image for the final
qnetd runtime.

Build it with:

```sh
docker build -f Dockerfile-distroless -t proxmox-qdevice:distroless .
```

The distroless image does not require a Docker Hub username or password to
build.  CI only needs credentials when publishing to an external registry.  The
provided workflow publishes to GHCR with `GITHUB_TOKEN` when `IMAGEPUSH=true`.

In the location for your persistent storage, make sure to create the directories for the root homedir and the corosync-data.

### Special note for Synology

For the storage location of "corosync-data" and "roothome", DO NOT use a path in /opt, /usr etc. Create a separate directory for proxmox-qdevice under one of your storage volumes.

Directories like /opt get erased across Synology DSM updates. Ask me how I know. ;)

## Running / Deploying:

You can either run the command:

`docker compose up -d`

Or cut and paste the docker-compose.yml into portainer.io as a stack and then deploy.

The very first time that you run the container, this will _seemingly_ fail. It runs, but corosync-qnetd will fail to start. Refer to [issue 5](https://github.com/unixerius/proxmox-qdevice/issues/5), or the "Completing setup" section below.

## Completing setup:

1. Build your Proxmox cluster.
2. Run the `proxmox-qdevice` container via Docker Compose.

Then follow the [setup instructions on the Proxmox site](https://pve.proxmox.com/wiki/Cluster_Manager#_corosync_external_vote_support), which means:

3. Install the `corosync-qdevice` package on all real cluster nodes.
4. Ensure that all cluster nodes can SSH to the container; I did `ssh_copy_id root@${qdeviceIP}`.
5. Run `pvecm qdevice setup ${IPAddress}` on one of the real cluster nodes.
6. Once that is done, restart the `proxmox-qdevice` container. This time, corosync-qnetd will startup correctly as it now has a full database and configuration.

## Monitoring and troubleshooting

After your cluster is configured with a QDevice you should periodically check
that the quorum service is operating correctly.  The following commands are
useful:

* **Check cluster quorum:** Run `pvecm status` on any Proxmox node.  A healthy
  two‑node plus QDevice cluster will report `Flags: Quorate Qdevice` and list
  the QDevice with one vote.  If the QDevice shows as `NA` (Not Alive), verify
  connectivity on TCP 5403 and restart the container.
* **Inspect qnetd state:** From inside the container or via `docker exec` run
  `corosync-qnetd-tool -s`.  This prints the QNet daemon’s status including
  connected clients and clusters.  You should see one cluster entry and one
  or two client connections depending on how many Proxmox nodes are active.
* **Review logs:** On a systemd‑based host you can review detailed logs with
  `journalctl -u corosync-qdevice` or `journalctl -u corosync-qnetd`.  In a
  container environment without systemd you can rely on `docker logs` and
  the above tools.

For automated monitoring, integrate a TCP port check against port 5403 (for
example using Uptime Kuma, CheckMK or similar) and configure alerting if
the check fails.  During runtime you should not expose port 22 to the
cluster network; only port 5403 needs to be reachable for qnetd.


## Security Implications

This container includes an SSH server to support the initial `pvecm qdevice setup` operation.  During normal runtime the SSH server is disabled unless you explicitly select `QDEVICE_MODE=setup` or `QDEVICE_MODE=auto` and no qdevice configuration exists.  Because the SSH daemon allows root logins, you **must** provide authentication material when enabling SSH.  Recommended practices:

1. Provide a strong root password via `ROOT_PASSWORD_FILE` (preferred) or `ROOT_PASSWORD`.  The legacy `NEW_ROOT_PASSWORD` is also still honoured for backwards compatibility.  Avoid hard‑coding passwords in your `docker-compose.yml` to prevent accidental exposure.
2. Provide an SSH public key via `ROOT_AUTHORIZED_KEYS_FILE` or `ROOT_AUTHORIZED_KEYS` instead of a password.  Keys from the file take precedence and are appended to `/root/.ssh/authorized_keys`.

All secrets should be persisted across container recreation.  For example, mount `/etc/ssh` so that host keys remain stable and `/root` so that authorised keys remain intact.  See the sample `docker-compose.yml` for volumes to persist.

> [!IMPORTANT]
>
> **A note on `latest` and `beta`:** It is not recommended to use the `latest` (`unixerius/proxmox-qdevice`, `unixerius/proxmox-qdevice:latest`) tag for production setups.  Floating tags can change without notice and may introduce breaking changes.  Always specify an immutable version tag when deploying to production.


## One-time setup, then distroless runtime

For a hardened deployment, run the Debian-based image only once for the `pvecm qdevice setup` step, then switch to the distroless runtime image using the same persisted `/etc/corosync` state.

See `docs/BOOTSTRAP_DISTROLESS_RUNTIME.md` for the exact one-time `docker run` command and the final distroless runtime command.  A helper script is also provided at `examples/one-time-setup-then-distroless.sh`.
