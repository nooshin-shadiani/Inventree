# InvenTree + USD/IRT and stock XLSX installer

These installers deploy InvenTree, PostgreSQL, Redis, the Django-Q2 background
worker, Caddy, the
[USD/IRT exchange-rate plugin](https://github.com/nooshin-shadiani/inventree-plugins/tree/main/plugins/usd-irt-exchange-rate),
and the
[stock XLSX adjustment plugin](https://github.com/nooshin-shadiani/inventree-plugins/tree/main/plugins/stock-xlsx-adjustment)
on Linux or Windows. Both plugins are baked into the InvenTree image used by
the web server and worker and activated automatically. Currency support is
configured for USD and Iranian toman (IRT).

Prepare once on a connected machine, then reuse the resulting platform-specific
bundle for multiple clean offline installs on the same supported platform and
CPU architecture. The first online run retains this bundle by default.

Every bundle contains the four container images, pinned plugin-suite source,
the pinned official InvenTree training dataset, deployment files, version
manifest, and SHA-256 manifest. Linux bundles also contain the matching Docker
Engine and Compose packages when the preparation host is a supported Ubuntu or
Debian release. Windows bundles contain the pinned WSL and Docker Desktop
installers.

The generated bundle—not this Git checkout—is the complete offline installation
media. Copy the whole bundle directory to a USB drive or other local storage.
The installers automatically install the cached Docker prerequisite when it is
missing and run `docker image load` on the saved application images.

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

For a new learning instance populated with the comprehensive training fixture:

```bash
./install-linux.sh --training-data
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

### Enable virtualization on Windows

Docker Desktop's WSL 2 backend requires CPU virtualization. This is a
UEFI/BIOS setting, so the installer cannot enable it for you.

1. Press `Ctrl`+`Shift`+`Esc`, open **Performance > CPU**, and check the
   **Virtualization** value. If it says **Enabled**, continue with the installer.
2. If it says **Disabled**, open Windows Settings and select **System >
   Recovery > Advanced startup > Restart now**. On Windows 10, use **Update &
   Security > Recovery > Advanced startup > Restart now**.
3. Select **Troubleshoot > Advanced options > UEFI Firmware Settings >
   Restart**. If that option is unavailable, use the computer manufacturer's
   startup key or firmware instructions.
4. In the firmware settings, enable **Intel Virtualization Technology**
   (`VT-x` or `VMX`) or **SVM Mode** (`AMD-V`). `VT-d` or `IOMMU` alone is not
   sufficient. Save the settings and restart Windows.
5. Confirm that Task Manager now reports **Virtualization: Enabled**, then run
   the installer. It enables **Windows Subsystem for Linux** and **Virtual
   Machine Platform** automatically. If it requests a restart, restart Windows
   and rerun the same installer command.

If Windows itself is running inside a virtual machine, the host hypervisor must
also expose nested virtualization to that VM.

From an elevated PowerShell 5.1 or newer prompt:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-windows.ps1
```

For a new learning instance populated with the comprehensive training fixture:

```powershell
.\install-windows.ps1 -TrainingData
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

## Complete offline bundle contents

Run the platform's `--prepare-only` / `-PrepareOnly` command once on a connected
preparation computer. Do not copy only the installer script: keep the entire
generated directory together.

The Linux bundle contains:

- `images-linux-<architecture>.tar`: the prebuilt InvenTree-with-plugins,
  PostgreSQL, Redis, and Caddy images;
- `prerequisites/linux-<distribution>-<release>-<architecture>/packages/`:
  Docker Engine, Docker CLI, containerd, Buildx, Compose, and their resolved
  `.deb` dependencies for that exact supported Ubuntu/Debian target;
- the plugin-suite source, official training dataset, Compose/Caddy
  configuration, manifests, and checksums.

The private Windows bundle contains:

- `images.tar`: all four prebuilt application images;
- `prerequisites/windows/DockerDesktop-*.exe`: the pinned, signed Docker
  Desktop installer;
- `prerequisites/windows/wsl-*.msi`: the pinned, signed WSL installer;
- the plugin-suite source, official training dataset, Compose/Caddy
  configuration, manifests, and checksums.

The offline installer loads the image archive automatically. To load only the
images yourself after Docker is installed, run:

```bash
docker image load --input /path/to/inventree-linux/images-linux-amd64.tar
```

```powershell
docker image load --input E:\inventree-windows\images.tar
```

The image archives and vendor installers are generated artifacts and are much
larger than GitHub's regular 100 MiB Git file limit, so they are intentionally
excluded from the repository. A Linux bundle may be distributed separately as
fork Release assets. Do not publish a Windows bundle containing Docker Desktop:
Docker Desktop may be retained only for licensed internal reuse unless Docker
grants explicit redistribution permission.

## What happens during installation

1. The installer verifies Docker Engine and Compose v2 in Linux-container mode.
2. Online mode downloads the commit-pinned plugin suite, pulls digest-pinned
   base images, and builds one InvenTree image with both plugins installed.
3. The images are tagged with installer-owned names. Offline mode instead
   checks `SHA256SUMS`, loads the saved image archive, and verifies every image
   ID before use.
4. A random 256-bit PostgreSQL password is written to a new private `.env`.
   Existing `.env`, Compose/Caddy files, and application data are never
   overwritten.
5. Database migrations and static-file collection run without package downloads.
   Existing installations are backed up before migration.
6. If training data was explicitly requested for a new empty installation, the
   installer imports the pinned fixture, restores both mandatory plugins, and
   initializes a simple offline USD/IRT example rate.
7. The first run offers interactive administrator creation, starts the stack,
   and verifies the web server, worker, installed package versions, both active
   plugin registrations, and—when requested—the fixture counts and accounts.

The deployment enables daily InvenTree database/media backups. The persistent
data, secrets, uploaded files, plugin settings, and backups are stored under
`<install-directory>/inventree-data`. Copy that directory to separate storage;
the offline image archive is software installation media, not a backup of your
inventory.

## Comprehensive training fixture

`--training-data` on Linux and `-TrainingData` on Windows populate a new,
empty installation with the official
[InvenTree demo dataset](https://github.com/inventree/demo-dataset), pinned to
commit `54bff7ea774a00a3fcefac049137d92ece632a98` under its MIT license. The
archive is SHA-256 pinned and included in every generated offline bundle, so
the same fixture can be installed without internet access.

The pinned fixture currently includes:

| Area | Records |
| --- | ---: |
| Parts and categories | 438 parts in 28 categories |
| Stock | 1,278 stock items in 19 locations |
| Manufacturing | 268 BOM lines, 4 BOM substitutes, and 28 build orders |
| Suppliers | 41 companies, 780 supplier parts, and 1,004 supplier price breaks |
| Orders | 20 purchase, 14 sales, 7 return, and 5 transfer orders |

It also contains parameters, related parts, stock history, test results,
attachments, reports, labels, users, groups, and permission rules. The
installer verifies the key record counts and account passwords before marking
the installation complete.

| Username | Password | Role to explore |
| --- | --- | --- |
| `admin` | `inventree` | Superuser and Admin Center |
| `allaccess` | `nolimits` | Normal user with broad create/edit access |
| `reader` | `readonly` | Read-only behavior |
| `engineer` | `partsonly` | Parts and stock with restricted order access |

Training mode also sets `1 USD = 100,000 IRT` with the TGJU consumer disabled.
This is deliberately simple sample data for learning conversions, not a live
market quote. Change the manual rate or enable TGJU in Admin Center before
using current prices.

The fixture import clears a database, so the option is guarded twice: it is
accepted only when there is no completed installation marker and the database
contains no users or inventory/business records. It refuses an existing
installation instead of replacing its data. The demo passwords are public;
keep a training instance bound to localhost, or change all passwords before
allowing access from another computer. Do not use the fixture as production
inventory.

The flag works with an offline bundle too: append `--training-data` to the
Linux offline-install command or `-TrainingData` to the Windows command shown
above.

A useful first tour is:

1. Sign in as `admin` and compare the four users under **Admin Center > Users**.
2. Browse **Parts**, open an assembly, and inspect its BOM, substitutes,
   supplier parts, pricing, and **Plugin Provided > USD / IRT Pricing** panel.
3. Browse **Stock Locations**, inspect item history, and open **Stock XLSX
   Adjustment**.
4. Open a build order and compare its **Build Lines**, allocations, shortages,
   and completed outputs.
5. Compare purchase, sales, return, and transfer order states, then sign in as
   `reader` or `engineer` to see permission boundaries.

## Currency configuration

The installer sets and locks these InvenTree system settings:

- default currency: `USD`
- supported currencies: `USD,IRT`
- currency provider: `inventree-usd-irt-exchange-rate`
- InvenTree's overlapping core currency interval: disabled
- InvenTree's core GitHub release check: disabled
- plugin app integration: enabled for price-snapshot models and migrations
- plugin URL and user-interface integration: enabled for stock XLSX endpoints
- plugin schedule integration: enabled

The plugin's **Enable TGJU USD rate consumer** option remains disabled by
default. Set a manual IRT-per-USD rate for fully offline operation, or enable
the consumer in Admin Center to scrape TGJU by XPath every three hours. Live
TGJU refreshes require internet access even when InvenTree itself is installed
from an offline bundle.

Every InvenTree money-field currency selector includes both USD and IRT,
including the minimum and maximum override selectors under **Part Pricing >
Pricing Overview > Edit Pricing**. Standard InvenTree price widgets continue to
show the currency selected for that field. To see both conversions together,
open **Plugin Provided > USD / IRT Pricing** on the part page; that panel shows
the current calculated ranges in parallel USD and IRT columns.

When a USD or IRT part price is saved, the currency plugin records an immutable
snapshot of the entered amount, its USD and IRT equivalents, the effective
exchange rate, source, time, and user. Later exchange-rate changes do not alter
that historical record.

## Bulk stock adjustment

Authorized users can open **Stock XLSX Adjustment** from **Stock Locations**,
download the template, upload a workbook, preview every change, and then apply
the workbook atomically. The worksheet columns are:

| Column | Meaning |
| --- | --- |
| `stock_item_id` | Exact InvenTree stock-item or lot ID |
| `operation` | `add`, `remove`, or `count` |
| `quantity` | Positive delta for add/remove; non-negative absolute stocktake for count |
| `notes` | Optional audit note, up to 512 characters |

Each successful row uses InvenTree's normal stock movement methods, so the
operation, delta, note, time, and user appear in stock history. Any invalid row
rejects the whole workbook. Access requires **Stock Location > View** and
**Stock Item > Change**; OAuth clients also require `r:change:stock`.

## Shortages and replacement parts

No extra plugin is needed for these workflows:

- To check material for `N` products, create a Build Order with quantity `N`,
  open **Build Lines**, filter **Available = No**, then use **Download > XLSX**.
  The export follows the active filters and includes required, allocated,
  consumed, primary-stock, substitute, and variant availability values.
- Define manufacturing substitutes on the relevant BOM line so availability
  and allocation include them. Use a part's **Related Parts** tab and note for
  a global human-readable replacement reference.

## Version and network notes

The plugins require InvenTree 1.6.0 or newer. At the time this installer was
created, the official stable image was still InvenTree 1.5.0, so
`versions.env` deliberately pins a reviewed InvenTree 1.6 development image by
digest. Update that pin to a tested 1.6 stable digest when it is released.

Online preparation needs access to GitHub, Docker's package/download hosts,
and Docker Hub. In regions where Docker Hub is filtered, prepare the offline
bundle on a connected machine matching the target platform and CPU, then
transfer it. Reuse a bundle only on the platform and architecture recorded in
its manifest; cached Linux Docker packages additionally require the exact
distribution and release recorded with those prerequisites. Regenerate and
review the bundle whenever the pinned application images, plugin suite, or
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
- [Official InvenTree demo dataset](https://github.com/inventree/demo-dataset)
- [Docker Engine for Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Engine for Debian](https://docs.docker.com/engine/install/debian/)
- [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Enable virtualization on Windows](https://support.microsoft.com/en-US/Windows/Experience/enable-virtualization-on-windows)
- [Microsoft WSL installation](https://learn.microsoft.com/windows/wsl/install)
- [`docker image save`](https://docs.docker.com/reference/cli/docker/image/save/)
- [`docker image load`](https://docs.docker.com/reference/cli/docker/image/load/)
