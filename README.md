# Proxmox Qdevice

[![CodeQL](https://github.com/unixerius/proxmox-qdevice/actions/workflows/github-code-scanning/codeql/badge.svg?branch=master)](https://github.com/unixerius/proxmox-qdevice/actions/workflows/github-code-scanning/codeql) [![Docker Image CI](https://github.com/unixerius/proxmox-qdevice/actions/workflows/docker-image.yml/badge.svg?branch=master)](https://github.com/unixerius/proxmox-qdevice/actions/workflows/docker-image.yml) [![Docker Scout vuln. scan](https://github.com/unixerius/proxmox-qdevice/actions/workflows/docker-scout.yml/badge.svg)](https://github.com/unixerius/proxmox-qdevice/actions/workflows/docker-scout.yml)[![SLSA 3](https://slsa.dev/images/gh-badge-level1.svg)](https://slsa.dev)

This repository allows you to build and deploy a container for use
with a Proxmox cluster as an external qdevice (corosync qnetd).  A
cluster normally requires an odd number of voting members.  When you
have an even number of Proxmox servers (for example two) you can
provide an external vote via a qdevice.  This image provides a
minimal Debian runtime with corosync-qnetd and, optionally, an SSH
daemon for the initial `pvecm qdevice setup` procedure.

For more information on proxmmox clusters, external qdevices, and how to configure/use them, go [here](https://pve.proxmox.com/wiki/Cluster_Manager#_corosync_external_vote_support).

Run this container on a device that is *NOT* a virtual instance on one of your Proxmox servers.

## Features of this fork

* **Environment‑driven configuration**.  All behaviour is controlled via
  environment variables so you do not need to modify the container
  image.  See `USAGE.md` and the comments in `docker-compose.yml` for
  descriptions of each variable.
* **Setup and runtime modes**.  When `QDEVICE_MODE=setup` the SSH
  daemon is enabled to allow `pvecm qdevice setup` to provision the
  qdevice.  When `QDEVICE_MODE=runtime` the SSH daemon is disabled by
  default and only `corosync-qnetd` runs, reducing the exposed
  attack surface.
* **Improved secret handling**.  The root password and authorised
  keys can be provided via files (for example Docker secrets) rather
  than inline environment variables.  Backwards compatibility with
  `NEW_ROOT_PASSWORD` is maintained.
* **Automatic SSH host key generation**.  If you persist `/etc/ssh` as
  a volume and this directory is empty on first start, the entrypoint
  will generate host keys to avoid using keys baked into the image.
* **Runtime-only distroless image**.  `Dockerfile-distroless` builds a
  minimal qnetd runtime image without SSH, a shell, a package manager
  or the setup entrypoint.  Use `Dockerfile-bookworm` or
  `Dockerfile-trixie` for initial setup and `QDEVICE_MODE=auto`; use
  the distroless image only after the qdevice has already been
  provisioned.

## Cluster design considerations

Proxmox only recommends QDevices for clusters with an **even number of
nodes**.  The official documentation notes that QDevices are supported
for even‑node clusters and are especially useful for 2‑node setups【59303623124675†L1490-L1496】.  For clusters
with an odd node count, the documentation discourages their use
because the algorithm provides `(N‑1)` votes and a QDevice failure can
create a single point of failure【59303623124675†L1490-L1508】.

When expanding or shrinking a cluster, remove the QDevice before
adding or removing nodes.  A community guide on Proxmox quorum notes
that the QDevice should be removed before adding a node to maintain an
odd node count【416444296263342†L137-L140】.  After the cluster change is complete you can add
the QDevice back using `pvecm qdevice setup <IP>`.

Finally, Proxmox recommends running any daemon that provides votes to
corosync‑qdevice as an **unprivileged user**【59303623124675†L1520-L1522】.  The Dockerfiles in
this repository create a `coroqnetd` user and allow you to run
`corosync-qnetd` under that account via the `QNETD_USER` variable.

## Choosing an image tag

When deploying containers in production you should **pin a specific
version tag** of this image rather than relying on floating tags such
as `latest` or `beta`.  Floating tags may be repointed at any time and
can introduce breaking changes without notice.  By specifying an
immutable tag (for example `unixerius/proxmox-qdevice:13.0.0`) you
control when updates occur.  See the [Docker Hub tag listing](https://hub.docker.com/r/unixerius/proxmox-qdevice/tags)
for available versions.  For more discussion on tag stability and
update policies see the **A note on `latest` and `beta`** section of
`USAGE.md`.

For full instructions on how to use and configure this container, please refer to [USAGE.md](https://github.com/unixerius/proxmox-qdevice/blob/master/USAGE.md).


## Provenance:

This container image is based on Debian's "slim" images, for both Trixie (13) and Bookworm (12).

The QDevice software is installed from Debian's own software repositories.

The image contains a shell script and a Supervisord configuration created by this project's original author. This project is a fork of [bcleonard/proxmox-qdevice](https://github.com/bcleonard/proxmox-qdevice).

Why a fork? The upstream project hasn't had an update in a year and it lacks weekly builds of the parent image, thus opening up your environment to long-lived vulnerabilities. 


## Tested on:

I have used this container image successfully with Proxmox 9.x and with Docker on Synology DSM 7.x.


## Acknowledgements:

This repository is based on original [work by Bradley Leonard](https://github.com/bcleonard/proxmox-qdevice). Many thanks to his hard work!

Bradley's original wiki [can be found here](https://github.com/bcleonard/proxmox-qdevice/wiki) which contains all kinds of information on configuring this container.

