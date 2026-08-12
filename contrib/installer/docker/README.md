# InvenTree + USD/IRT installer

These installers deploy InvenTree, PostgreSQL, Redis, the Django-Q2 background
worker, Caddy, and the
[USD/IRT exchange-rate plugin](https://github.com/nooshin-shadiani/InventreeUSDIRTExchangeRate)
on Linux or Windows. The plugin is baked into the InvenTree image used by both
the web server and worker, activated automatically, and configured for USD and
Iranian toman (IRT).

Prepare once on a connected machine, then reuse the resulting platform-specific
bundle for multiple clean offline installs on the same supported platform and
CPU architecture. The first online run retains this bundle by default.

Every bundle contains the four container images, pinned plugin source,
deployment files, version manifest, and SHA-256 manifest. Linux bundles also
contain the matching Docker Engine and Compose packages when the preparation
host is a supported Ubuntu or Debian release. Windows bundles contain the pinned
WSL and Docker Desktop installers.

## Linux

Automatic Docker Engine installation supports the official x86-64 and ARM64
releases of:

- Ubuntu 22.04, 24.04, and 26.04
- Debian 11, 12, and 13

On another distribution, install Docker Engine and Compose v2 first and use
`--skip-docker-install`.

Run from a clone or extracted archive of this repository:

```bash
cd contrib/installer/docker
./install-linux.sh
```

The default deployment directory is `~/InvenTree`, the site is bound only to
`http://localhost:8000`, and the reusable bundle is written to
`~/InvenTree/offline-bundle`. To prepare removable media without deploying:

```bash
./install-linux.sh \
    --prepare-only \
    --bundle-dir /path/to/removable-media/inventree-linux
```

Install from that bundle with networking disconnected:

```bash
/path/to/removable-media/inventree-linux/install-linux.sh \
    --offline-bundle /path/to/removable-media/inventree-linux
```

For supported Ubuntu/Debian hosts, the bundle also caches Docker's official
distro-, release-, and CPU-specific packages. A bundle made for a different
Linux release or CPU can still carry the application, but it cannot install the
Docker prerequisite there. Docker's `docker` group is root-equivalent, so the
script does not add users to it automatically; it uses `sudo docker` when
required.

Use `./install-linux.sh --help` for directory, port, preparation, and admin
options.

## Windows

Requirements are Windows 10 22H2 (build 19045) or newer, or Windows 11 23H2
(build 22631) or newer, with x86-64 virtualization enabled and at least 8 GB of
RAM. Windows Server and Windows containers are not supported.

From an elevated PowerShell 5.1 or newer prompt:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1
```

The script enables the required Windows features, installs/updates WSL, and can
download and install the official Docker Desktop WSL2 backend after explicit
acceptance of Docker's license. A Windows restart may be required; the script
never restarts the machine itself. Rerun the same command after restarting.

Prepare the Windows application bundle without deploying:

```powershell
.\install-windows.ps1 -PrepareOnly -BundleDirectory E:\inventree-windows
```

Then install the application without network access:

```powershell
E:\inventree-windows\install-windows.ps1 `
    -OfflineBundle E:\inventree-windows
```

The generated bundle retains the pinned WSL and Docker Desktop installers in
addition to the application images. Before installing Docker Desktop on the
offline target, the script requires explicit acceptance of Docker's license and
verifies the package's pinned SHA-256 hash and Docker Inc. Authenticode
signature.

Retaining Docker Desktop in a bundle is intended only for licensed internal
reuse. Docker Desktop remains governed by the Docker Subscription Service
Agreement; do not publish or otherwise redistribute a bundle containing Docker
Desktop without Docker's permission. See
[Docker's subscription terms](https://www.docker.com/legal/docker-subscription-service-agreement/)
for applicable licensing.

Use `Get-Help .\install-windows.ps1 -Detailed` for all parameters.

## What happens during installation

1. The installer verifies Docker Engine and Compose v2 in Linux-container mode.
2. Online mode downloads the commit-pinned plugin, pulls digest-pinned base
   images, and builds one InvenTree image with the plugin already installed.
3. The images are tagged with installer-owned names. Offline mode instead
   checks `SHA256SUMS`, loads the saved image archive, and verifies every image
   ID before use.
4. A random 256-bit PostgreSQL password is written to a new private `.env`.
   Existing `.env`, Compose/Caddy files, and application data are never
   overwritten.
5. Database migrations and static-file collection run without package downloads.
   Existing installations are backed up before migration.
6. The first run offers interactive administrator creation, starts the stack,
   and verifies the web server, worker, and installed plugin version.

The deployment enables daily InvenTree database/media backups. The persistent
data, secrets, uploaded files, plugin settings, and backups are stored under
`<install-directory>/inventree-data`. Copy that directory to separate storage;
the offline image archive is software installation media, not a backup of your
inventory.

## Currency configuration

The installer sets and locks these InvenTree system settings:

- default currency: `USD`
- supported currencies: `USD,IRT`
- currency provider: `inventree-usd-irt-exchange-rate`
- InvenTree's overlapping core currency interval: disabled
- InvenTree's core GitHub release check: disabled
- plugin schedule integration: enabled

The plugin's **Enable TGJU USD rate consumer** option remains disabled by
default. Set a manual IRT-per-USD rate for fully offline operation, or enable
the consumer in Admin Center to scrape TGJU by XPath every three hours. Live
TGJU refreshes require internet access even when InvenTree itself is installed
from an offline bundle.

## Version and network notes

The plugin requires InvenTree 1.6.0 or newer. At the time this installer was
created, the official stable image was still InvenTree 1.5.0, so
`versions.env` deliberately pins a reviewed InvenTree 1.6 development image by
digest. Update that pin to a tested 1.6 stable digest when it is released.

Online preparation needs access to GitHub, Docker's package/download hosts,
and Docker Hub. In regions where Docker Hub is filtered, prepare the offline
bundle on a connected machine matching the target platform and CPU, then
transfer it. Reuse a bundle only on the platform and architecture recorded in
its manifest; cached Linux Docker packages additionally require the exact
distribution and release recorded with those prerequisites. Regenerate and
review the bundle whenever the pinned application images, plugin, or
prerequisite versions change; retained software does not receive security
updates automatically. The offline checksums detect accidental corruption;
they are not a third-party signature or a substitute for obtaining this
repository from a trusted source.

Docker-published ports can bypass some host firewall rules. The default bind is
localhost-only. Before changing `INVENTREE_BIND_ADDRESS` to `0.0.0.0`, configure
the host firewall and set `INVENTREE_SITE_URL` to the actual LAN URL. This
offline-oriented Caddy configuration serves plain HTTP; configure TLS before
exposing it outside a trusted network.

## Maintenance

Run commands from the deployment directory. If Linux Docker needs root access,
prefix `docker` with `sudo`.

```bash
# Status
docker compose --env-file .env -f compose.yaml ps

# Manual backup
docker compose --env-file .env -f compose.yaml exec inventree-server invoke backup

# Stop / start without deleting data
docker compose --env-file .env -f compose.yaml stop
docker compose --env-file .env -f compose.yaml up -d --pull never --no-build
```

Do not run `docker compose down --volumes` or delete `inventree-data` unless the
persistent inventory and backups are intentionally being destroyed.

## Sources

- [InvenTree Docker installation](https://docs.inventree.org/en/latest/start/docker/)
- [InvenTree plugin installation](https://docs.inventree.org/en/latest/plugins/install/)
- [Docker Engine for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Engine for Debian](https://docs.docker.com/engine/install/debian/)
- [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Microsoft WSL installation](https://learn.microsoft.com/windows/wsl/install)
- [`docker image save`](https://docs.docker.com/reference/cli/docker/image/save/)
- [`docker image load`](https://docs.docker.com/reference/cli/docker/image/load/)
