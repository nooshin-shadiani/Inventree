#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_DIR="${HOME}/InvenTree"
BUNDLE_DIR=""
OFFLINE_BUNDLE=""
HTTP_PORT="8000"
SKIP_DOCKER_INSTALL=false
SKIP_ADMIN=false
PREPARE_ONLY=false
NO_OFFLINE_CACHE=false
DOCKER=()
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
INVENTREE_DEPLOY_IMAGE=""
POSTGRES_DEPLOY_IMAGE=""
REDIS_DEPLOY_IMAGE=""
CADDY_DEPLOY_IMAGE=""
INSTALL_LOCK_FD=""
EXPORT_LOCK_FD=""
EXPORT_LOCK_DIR=""
EXPORT_STAGING_DIR=""
ENV_TEMP_FILE=""
INSTALLED_TEMP_FILE=""

usage() {
    cat <<'EOF'
Install InvenTree and the USD/IRT exchange-rate plugin with Docker.

Usage:
  ./install-linux.sh [options]

Options:
  --install-dir PATH       Deployment directory (default: ~/InvenTree)
  --http-port PORT         Local HTTP port (default: 8000)
  --offline-bundle PATH    Install strictly from an existing offline bundle
  --bundle-dir PATH        Where online mode saves the reusable offline bundle
  --skip-docker-install    Require an existing Docker Engine + Compose v2
  --skip-admin             Do not prompt to create the first superuser
  --prepare-only           Cache prerequisites/images; do not deploy or start
  --no-offline-cache       Install online without exporting an offline bundle
  -h, --help               Show this help

Offline bundles contain all application images and the pinned plugin. Linux
Docker packages are cached only for the exact supported distro/release/CPU.
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '\n==> %s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

remove_private_tree() {
    local target="$1"

    [[ -n "$target" ]] || return 0
    [[ -e "$target" || -L "$target" ]] || return 0
    [[ -d "$target" && ! -L "$target" ]] || return 1
    find "$target" -depth -delete
}

cleanup_installer() {
    local exit_code=$?
    trap - EXIT
    set +e
    [[ -z "$ENV_TEMP_FILE" ]] || unlink -- "$ENV_TEMP_FILE"
    [[ -z "$INSTALLED_TEMP_FILE" ]] || unlink -- "$INSTALLED_TEMP_FILE"
    remove_private_tree "$EXPORT_STAGING_DIR"
    if [[ -n "$EXPORT_LOCK_FD" ]]; then
        flock --unlock "$EXPORT_LOCK_FD"
        exec {EXPORT_LOCK_FD}<&-
        EXPORT_LOCK_FD=""
    fi
    if [[ -n "$INSTALL_LOCK_FD" ]]; then
        flock --unlock "$INSTALL_LOCK_FD"
        exec {INSTALL_LOCK_FD}<&-
        INSTALL_LOCK_FD=""
    fi
    exit "$exit_code"
}

trap cleanup_installer EXIT

copy_if_missing() {
    local source_file="$1"
    local destination_file="$2"

    if [[ ! -e "$destination_file" ]]; then
        cp -- "$source_file" "$destination_file"
    fi
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

validate_port() {
    [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || die "HTTP port must be an integer"
    (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || die "HTTP port must be between 1 and 65535"
}

canonicalize_directory_path() {
    local raw_path="$1"
    local label="$2"
    local logical_path current_path component
    local path_components=()

    logical_path="$(realpath -ms -- "$raw_path")"
    current_path=/
    local IFS=/
    read -r -a path_components <<< "${logical_path#/}"
    for component in "${path_components[@]}"; do
        [[ -n "$component" ]] || continue
        current_path="${current_path%/}/$component"
        [[ ! -L "$current_path" ]] || die "$label path contains a symbolic link: $current_path"
        if [[ -e "$current_path" && "$current_path" != "$logical_path" ]]; then
            [[ -d "$current_path" ]] || die "$label path has a non-directory ancestor: $current_path"
        fi
    done

    realpath -m -- "$logical_path"
}

path_is_within() {
    local candidate="${1%/}/"
    local parent="${2%/}/"
    [[ "$candidate" == "$parent"* ]]
}

require_regular_path() {
    local target="$1"
    local label="$2"

    [[ ! -L "$target" ]] || die "$label cannot be a symbolic link: $target"
    if [[ -e "$target" ]]; then
        [[ -f "$target" ]] || die "$label is not a regular file: $target"
    fi
}

require_directory_path() {
    local target="$1"
    local label="$2"

    [[ ! -L "$target" ]] || die "$label cannot be a symbolic link: $target"
    if [[ -e "$target" ]]; then
        [[ -d "$target" ]] || die "$label is not a directory: $target"
    else
        mkdir -- "$target"
    fi
}

check_install_lock() {
    require_command flock
    exec {INSTALL_LOCK_FD}<"$INSTALL_DIR"
    flock --nonblock "$INSTALL_LOCK_FD" \
        || die "Another installer process appears active for $INSTALL_DIR"
}

prepare_bundle_destination() {
    local destination="$BUNDLE_DIR"
    [[ "$destination" != "$INSTALL_DIR" ]] || die "Bundle directory cannot equal the install directory"
    [[ "$destination" != "$SCRIPT_DIR" ]] || die "Bundle directory cannot equal the installer source directory"

    local destination_parent destination_name
    destination_parent="$(dirname -- "$destination")"
    destination_name="$(basename -- "$destination")"
    mkdir -p -- "$destination_parent"
    destination_parent="$(canonicalize_directory_path "$destination_parent" "Bundle parent")"
    destination="${destination_parent}/${destination_name}"
    [[ "$destination" != "$INSTALL_DIR" ]] || die "Bundle directory cannot equal the install directory"
    [[ "$destination" != "$SCRIPT_DIR" ]] || die "Bundle directory cannot equal the installer source directory"

    BUNDLE_DIR="$destination"
    EXPORT_LOCK_DIR="$destination_parent"
}

check_export_lock() {
    local lock_directory="$1"
    require_command flock

    if [[ -n "$INSTALL_LOCK_FD" && "$lock_directory" == "$INSTALL_DIR" ]]; then
        EXPORT_LOCK_DIR="$lock_directory"
        return
    fi

    [[ -z "$EXPORT_LOCK_FD" ]] || die "Bundle export lock was already acquired for $EXPORT_LOCK_DIR"
    exec {EXPORT_LOCK_FD}<"$lock_directory"
    flock --nonblock "$EXPORT_LOCK_FD" \
        || die "Another bundle export appears active in $lock_directory"
    EXPORT_LOCK_DIR="$lock_directory"
}

release_export_lock() {
    if [[ -n "$EXPORT_LOCK_FD" ]]; then
        flock --unlock "$EXPORT_LOCK_FD"
        exec {EXPORT_LOCK_FD}<&-
        EXPORT_LOCK_FD=""
    fi
    EXPORT_LOCK_DIR=""
}

load_versions() {
    local versions_file="$1"
    local allowed_keys=' INSTALLER_FORMAT_VERSION INVENTREE_BASE_SOURCE INVENTREE_RUNTIME_IMAGE POSTGRES_SOURCE POSTGRES_RUNTIME_IMAGE REDIS_SOURCE REDIS_RUNTIME_IMAGE CADDY_SOURCE CADDY_RUNTIME_IMAGE PLUGIN_VERSION PLUGIN_COMMIT PLUGIN_ARCHIVE_NAME PLUGIN_ARCHIVE_URL PLUGIN_ARCHIVE_SHA256 PLUGIN_ARCHIVE_SUBDIRECTORY DOCKER_DESKTOP_VERSION DOCKER_DESKTOP_BUILD DOCKER_DESKTOP_URL DOCKER_DESKTOP_SHA256 WSL_VERSION WSL_URL WSL_SHA256 '
    [[ -f "$versions_file" ]] || die "Missing version manifest: $versions_file"

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Invalid key in versions.env: $key"
        [[ "$allowed_keys" == *" $key "* ]] || die "Unknown key in versions.env: $key"
        printf -v "$key" '%s' "$value"
    done < "$versions_file"

    local required_key
    for required_key in \
        INSTALLER_FORMAT_VERSION INVENTREE_BASE_SOURCE INVENTREE_RUNTIME_IMAGE \
        POSTGRES_SOURCE POSTGRES_RUNTIME_IMAGE REDIS_SOURCE REDIS_RUNTIME_IMAGE \
        CADDY_SOURCE CADDY_RUNTIME_IMAGE PLUGIN_VERSION PLUGIN_COMMIT \
        PLUGIN_ARCHIVE_URL PLUGIN_ARCHIVE_SHA256 PLUGIN_ARCHIVE_SUBDIRECTORY; do
        [[ -n "${!required_key:-}" ]] || die "versions.env is missing $required_key"
    done
}

parse_arguments() {
    while (($#)); do
        case "$1" in
            --install-dir)
                (($# >= 2)) || die "--install-dir requires a value"
                INSTALL_DIR="$2"
                shift 2
                ;;
            --http-port)
                (($# >= 2)) || die "--http-port requires a value"
                HTTP_PORT="$2"
                shift 2
                ;;
            --offline-bundle)
                (($# >= 2)) || die "--offline-bundle requires a value"
                OFFLINE_BUNDLE="$2"
                shift 2
                ;;
            --bundle-dir)
                (($# >= 2)) || die "--bundle-dir requires a value"
                BUNDLE_DIR="$2"
                shift 2
                ;;
            --skip-docker-install)
                SKIP_DOCKER_INSTALL=true
                shift
                ;;
            --skip-admin)
                SKIP_ADMIN=true
                shift
                ;;
            --prepare-only)
                PREPARE_ONLY=true
                shift
                ;;
            --no-offline-cache)
                NO_OFFLINE_CACHE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    [[ -z "$OFFLINE_BUNDLE" || -z "$BUNDLE_DIR" ]] || die "Use either --offline-bundle or --bundle-dir, not both"
    [[ -z "$OFFLINE_BUNDLE" || "$NO_OFFLINE_CACHE" == false ]] || die "--no-offline-cache is not valid with --offline-bundle"
    [[ "$PREPARE_ONLY" == false || "$NO_OFFLINE_CACHE" == false ]] \
        || die "--prepare-only requires an offline bundle output"
    [[ "$PREPARE_ONLY" == false || -z "$OFFLINE_BUNDLE" ]] \
        || die "--prepare-only cannot be combined with --offline-bundle"
    validate_port

    INSTALL_DIR="$(canonicalize_directory_path "$INSTALL_DIR" "Install directory")"
    if [[ -n "$OFFLINE_BUNDLE" ]]; then
        OFFLINE_BUNDLE="$(canonicalize_directory_path "$OFFLINE_BUNDLE" "Offline bundle")"
    fi
    if [[ -n "$BUNDLE_DIR" ]]; then
        BUNDLE_DIR="$(canonicalize_directory_path "$BUNDLE_DIR" "Bundle output")"
    else
        BUNDLE_DIR="${INSTALL_DIR}/offline-bundle"
    fi
}

run_privileged() {
    if (( EUID == 0 )); then
        "$@"
    else
        require_command sudo
        sudo "$@"
    fi
}

detect_platform() {
    case "$(uname -m)" in
        x86_64|amd64)
            HOST_ARCH=amd64
            DEB_ARCH=amd64
            ;;
        aarch64|arm64)
            HOST_ARCH=arm64
            DEB_ARCH=arm64
            ;;
        *)
            die "Only x86_64 and ARM64 are supported"
            ;;
    esac
}

detect_linux_release() {
    local required="${1:-true}"
    [[ -r /etc/os-release ]] || die "Cannot identify Linux distribution"
    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="${ID:-}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"

    case "${DISTRO_ID}:${DISTRO_VERSION}" in
        ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:11|debian:12|debian:13) ;;
        *)
            if [[ "$required" == true ]]; then
                die "Automatic Docker setup supports only Ubuntu 22.04/24.04/26.04 and Debian 11/12/13. Use --skip-docker-install with a working Docker Engine on this host (${PRETTY_NAME:-unknown})."
            fi
            return 1
            ;;
    esac

    [[ -n "$DISTRO_CODENAME" ]] || die "Linux release codename is missing"
}

docker_is_usable() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1 || return 1
    DOCKER=(docker)
    return 0
}

sudo_docker_is_usable() {
    (( EUID != 0 )) || return 1
    command -v docker >/dev/null 2>&1 || return 1
    command -v sudo >/dev/null 2>&1 || return 1
    sudo docker info >/dev/null 2>&1 || return 1
    sudo docker compose version >/dev/null 2>&1 || return 1
    DOCKER=(sudo docker)
    return 0
}

select_docker_command() {
    if docker_is_usable; then
        return
    fi

    if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1; then
        if sudo docker info >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1; then
            DOCKER=(sudo docker)
            return
        fi
    fi

    die "Docker daemon or Compose v2 is not usable. Start Docker, or rerun without --skip-docker-install while online."
}

add_docker_repository() {
    local keyring=/etc/apt/keyrings/docker.asc
    local sources_file=/etc/apt/sources.list.d/docker.sources
    local repo_url="https://download.docker.com/linux/${DISTRO_ID}"

    note "Configuring Docker's official ${DISTRO_ID} repository"
    run_privileged apt-get update
    run_privileged apt-get install -y ca-certificates curl
    run_privileged install -m 0755 -d /etc/apt/keyrings

    if [[ ! -f "$keyring" ]]; then
        local key_tmp
        key_tmp="$(mktemp)"
        curl --fail --location --silent --show-error "${repo_url}/gpg" --output "$key_tmp"
        run_privileged install -m 0644 "$key_tmp" "$keyring"
        unlink "$key_tmp"
    fi

    if [[ ! -f "$sources_file" ]]; then
        local sources_tmp
        sources_tmp="$(mktemp)"
        {
            printf 'Types: deb\n'
            printf 'URIs: %s\n' "$repo_url"
            printf 'Suites: %s\n' "$DISTRO_CODENAME"
            printf 'Components: stable\n'
            printf 'Architectures: %s\n' "$DEB_ARCH"
            printf 'Signed-By: %s\n' "$keyring"
        } > "$sources_tmp"
        run_privileged install -m 0644 "$sources_tmp" "$sources_file"
        unlink "$sources_tmp"
    fi
    run_privileged apt-get update
}

check_conflicting_packages() {
    local conflicts=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)
    local installed=()
    local package

    for package in "${conflicts[@]}"; do
        if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
            installed+=("$package")
        fi
    done

    ((${#installed[@]} == 0)) || die "Conflicting packages are installed: ${installed[*]}. Review and remove them explicitly before installing Docker CE: https://docs.docker.com/engine/install/${DISTRO_ID}/#uninstall-old-versions"
}

install_docker_online() {
    detect_linux_release
    check_conflicting_packages
    add_docker_repository

    note "Installing Docker Engine and Compose v2"
    run_privileged apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    run_privileged systemctl enable --now docker
}

cache_linux_docker_packages() (
    local apt_state=""
    trap '[[ -z "$apt_state" ]] || remove_private_tree "$apt_state"' EXIT

    if ! command -v apt-get >/dev/null 2>&1; then
        return
    fi

    if ! detect_linux_release false; then
        note "Skipping the Docker package cache on unsupported ${PRETTY_NAME:-Linux}; the application bundle remains complete"
        return
    fi
    local destination="$1/prerequisites/linux-${DISTRO_ID}-${DISTRO_VERSION}-${DEB_ARCH}"
    apt_state="$(mktemp -d)"
    chmod 0755 "$apt_state"
    mkdir -p -- "$destination/packages/partial" "$apt_state/lists/partial" "$apt_state/preferences.d"
    : > "$apt_state/status"
    : > "$apt_state/preferences"
    : > "$apt_state/extended_states"

    note "Caching distro-specific Docker packages for offline reuse"

    curl --fail --location --silent --show-error \
        "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
        --output "$apt_state/docker.asc"
    chmod 0644 "$apt_state/docker.asc"

    local distro_archive distro_security
    if [[ "$DISTRO_ID" == ubuntu ]]; then
        if [[ "$DEB_ARCH" == amd64 ]]; then
            distro_archive=http://archive.ubuntu.com/ubuntu
            distro_security=http://security.ubuntu.com/ubuntu
        else
            distro_archive=http://ports.ubuntu.com/ubuntu-ports
            distro_security=$distro_archive
        fi
        {
            printf 'deb [arch=%s] %s %s main universe\n' "$DEB_ARCH" "$distro_archive" "$DISTRO_CODENAME"
            printf 'deb [arch=%s] %s %s-updates main universe\n' "$DEB_ARCH" "$distro_archive" "$DISTRO_CODENAME"
            printf 'deb [arch=%s] %s %s-security main universe\n' "$DEB_ARCH" "$distro_security" "$DISTRO_CODENAME"
        } > "$apt_state/sources.list"
    else
        distro_archive=http://deb.debian.org/debian
        distro_security=http://security.debian.org/debian-security
        {
            printf 'deb [arch=%s] %s %s main\n' "$DEB_ARCH" "$distro_archive" "$DISTRO_CODENAME"
            printf 'deb [arch=%s] %s %s-updates main\n' "$DEB_ARCH" "$distro_archive" "$DISTRO_CODENAME"
            printf 'deb [arch=%s] %s %s-security main\n' "$DEB_ARCH" "$distro_security" "$DISTRO_CODENAME"
        } > "$apt_state/sources.list"
    fi
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
        "$DEB_ARCH" "$apt_state/docker.asc" "$DISTRO_ID" "$DISTRO_CODENAME" \
        >> "$apt_state/sources.list"

    local apt_options=(
        -o Debug::NoLocking=1
        -o "Dir::Etc::sourcelist=${apt_state}/sources.list"
        -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=${apt_state}/lists"
        -o "Dir::State::status=${apt_state}/status"
        -o "Dir::State::extended_states=${apt_state}/extended_states"
        -o "Dir::Cache::archives=${destination}/packages"
        -o "Dir::Cache::pkgcache=${apt_state}/pkgcache.bin"
        -o "Dir::Cache::srcpkgcache=${apt_state}/srcpkgcache.bin"
        -o APT::Get::List-Cleanup=0
        -o Acquire::Languages=none
        -o "Dir::Etc::preferences=${apt_state}/preferences"
        -o "Dir::Etc::preferencesparts=${apt_state}/preferences.d"
    )
    apt-get "${apt_options[@]}" update
    apt-get \
        -y \
        "${apt_options[@]}" \
        --download-only \
        --no-install-recommends \
        install \
        "${DOCKER_PACKAGES[@]}"

    local package_path package_name package_version package_architecture
    local package_index="$destination/packages/Packages"
    local package_manifest="$destination/package-manifest.tsv"
    : > "$package_index"
    printf 'package\tversion\tarchitecture\tsha256\tfile\n' > "$package_manifest"
    local package_count=0
    for package_path in "$destination"/packages/*.deb; do
        [[ -f "$package_path" ]] || continue
        dpkg-deb --field "$package_path" >> "$package_index"
        printf 'Filename: ./%s\nSize: %s\nSHA256: %s\n\n' \
            "$(basename -- "$package_path")" \
            "$(stat --format='%s' "$package_path")" \
            "$(sha256_file "$package_path")" >> "$package_index"

        package_name="$(dpkg-deb --field "$package_path" Package)"
        package_version="$(dpkg-deb --field "$package_path" Version)"
        package_architecture="$(dpkg-deb --field "$package_path" Architecture)"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$package_name" "$package_version" "$package_architecture" \
            "$(sha256_file "$package_path")" "$(basename -- "$package_path")" \
            >> "$package_manifest"
        ((package_count += 1))
    done
    ((package_count > 0)) || die "Docker prerequisite resolver returned no packages"

    cp -- "$apt_state/docker.asc" "$destination/docker.asc"
    {
        printf 'DISTRO_ID=%s\n' "$DISTRO_ID"
        printf 'DISTRO_VERSION=%s\n' "$DISTRO_VERSION"
        printf 'DISTRO_CODENAME=%s\n' "$DISTRO_CODENAME"
        printf 'DEB_ARCH=%s\n' "$DEB_ARCH"
    } > "$destination/platform.env"

    rmdir -- "$destination/packages/partial" 2>/dev/null || true

    remove_private_tree "$apt_state"
    apt_state=""
)

install_docker_offline() (
    local apt_state=""
    trap '[[ -z "$apt_state" ]] || run_privileged find "$apt_state" -depth -delete' EXIT

    local prerequisite_root="$OFFLINE_BUNDLE/prerequisites/linux-${DISTRO_ID}-${DISTRO_VERSION}-${DEB_ARCH}"
    [[ -f "$prerequisite_root/platform.env" ]] || die "This bundle has no Docker package cache for ${DISTRO_ID} ${DISTRO_VERSION} ${DEB_ARCH}. Install Docker Engine + Compose v2 separately, then rerun with --skip-docker-install."
    [[ -f "$prerequisite_root/packages/Packages" ]] || die "Cached Docker package repository has no Packages index"

    local expected_platform
    expected_platform="DISTRO_ID=${DISTRO_ID}
DISTRO_VERSION=${DISTRO_VERSION}
DISTRO_CODENAME=${DISTRO_CODENAME}
DEB_ARCH=${DEB_ARCH}"
    [[ "$(< "$prerequisite_root/platform.env")" == "$expected_platform" ]] \
        || die "Cached Docker packages do not match this Linux platform"

    note "Installing cached Docker packages"
    check_conflicting_packages
    apt_state="$(mktemp -d)"
    chmod 0755 "$apt_state"
    mkdir -p -- \
        "$apt_state/lists/partial" \
        "$apt_state/archives/partial" \
        "$apt_state/preferences.d"
    : > "$apt_state/preferences"
    : > "$apt_state/extended_states"
    ln -s -- "$prerequisite_root/packages" "$apt_state/repository"
    printf 'deb [trusted=yes] file:%s ./\n' "$apt_state/repository" > "$apt_state/sources.list"

    local apt_options=(
        -o "Dir::Etc::sourcelist=${apt_state}/sources.list"
        -o Dir::Etc::sourceparts=-
        -o "Dir::Etc::preferences=${apt_state}/preferences"
        -o "Dir::Etc::preferencesparts=${apt_state}/preferences.d"
        -o "Dir::State::lists=${apt_state}/lists"
        -o "Dir::State::extended_states=${apt_state}/extended_states"
        -o "Dir::Cache::archives=${apt_state}/archives"
        -o "Dir::Cache::pkgcache=${apt_state}/pkgcache.bin"
        -o "Dir::Cache::srcpkgcache=${apt_state}/srcpkgcache.bin"
        -o APT::Get::List-Cleanup=0
        -o APT::Sandbox::User=root
        -o Acquire::Languages=none
    )
    run_privileged apt-get "${apt_options[@]}" update
    run_privileged apt-get -y "${apt_options[@]}" --no-install-recommends install "${DOCKER_PACKAGES[@]}"
    run_privileged systemctl enable --now docker
    run_privileged find "$apt_state" -depth -delete
    apt_state=""
)

ensure_docker() {
    if docker_is_usable || sudo_docker_is_usable; then
        return
    fi

    if [[ "$SKIP_DOCKER_INSTALL" == true ]]; then
        select_docker_command
        return
    fi

    if [[ -n "$OFFLINE_BUNDLE" ]]; then
        detect_linux_release
        install_docker_offline
    else
        install_docker_online
    fi

    select_docker_command
}

verify_docker_platform() {
    local daemon_os daemon_arch
    daemon_os="$("${DOCKER[@]}" info --format '{{.OSType}}')"
    daemon_arch="$("${DOCKER[@]}" info --format '{{.Architecture}}')"
    [[ "$daemon_os" == linux ]] || die "Docker must be running Linux containers (reported: $daemon_os)"

    case "$daemon_arch" in
        x86_64|amd64) DAEMON_ARCH=amd64 ;;
        aarch64|arm64) DAEMON_ARCH=arm64 ;;
        *) die "Unsupported Docker architecture: $daemon_arch" ;;
    esac

    [[ "$DAEMON_ARCH" == "$HOST_ARCH" ]] || die "Host architecture ($HOST_ARCH) and Docker architecture ($DAEMON_ARCH) do not match"
}

download_plugin_source() {
    local destination="$1"
    mkdir -p -- "$(dirname -- "$destination")"

    if [[ ! -f "$destination" ]] || [[ "$(sha256_file "$destination")" != "$PLUGIN_ARCHIVE_SHA256" ]]; then
        note "Downloading pinned USD/IRT plugin source"
        curl --fail --location --silent --show-error "$PLUGIN_ARCHIVE_URL" --output "$destination"
    fi

    [[ "$(sha256_file "$destination")" == "$PLUGIN_ARCHIVE_SHA256" ]] || die "Plugin source checksum mismatch"
}

image_id() {
    "${DOCKER[@]}" image inspect --format '{{.Id}}' -- "$1"
}

snapshot_deployment_images() {
    INVENTREE_DEPLOY_IMAGE="$(image_id "$INVENTREE_RUNTIME_IMAGE")"
    POSTGRES_DEPLOY_IMAGE="$(image_id "$POSTGRES_RUNTIME_IMAGE")"
    REDIS_DEPLOY_IMAGE="$(image_id "$REDIS_RUNTIME_IMAGE")"
    CADDY_DEPLOY_IMAGE="$(image_id "$CADDY_RUNTIME_IMAGE")"

    local installed_version
    installed_version="$("${DOCKER[@]}" run --rm --entrypoint python "$INVENTREE_DEPLOY_IMAGE" \
        -c 'import importlib.metadata; print(importlib.metadata.version("inventree-usd-irt-exchange-rate"))')"
    [[ "$installed_version" == "$PLUGIN_VERSION" ]] \
        || die "Plugin verification failed: expected ${PLUGIN_VERSION}, got ${installed_version}"
}

acquire_application_images() {
    local persistent_cache="$SCRIPT_DIR/cache"
    local plugin_archive="$persistent_cache/plugin-source.tar.gz"
    local build_context
    download_plugin_source "$plugin_archive"

    note "Pulling pinned InvenTree stack images"
    "${DOCKER[@]}" pull --platform "linux/${DAEMON_ARCH}" "$INVENTREE_BASE_SOURCE"
    "${DOCKER[@]}" pull --platform "linux/${DAEMON_ARCH}" "$POSTGRES_SOURCE"
    "${DOCKER[@]}" pull --platform "linux/${DAEMON_ARCH}" "$REDIS_SOURCE"
    "${DOCKER[@]}" pull --platform "linux/${DAEMON_ARCH}" "$CADDY_SOURCE"

    "${DOCKER[@]}" tag "$POSTGRES_SOURCE" "$POSTGRES_RUNTIME_IMAGE"
    "${DOCKER[@]}" tag "$REDIS_SOURCE" "$REDIS_RUNTIME_IMAGE"
    "${DOCKER[@]}" tag "$CADDY_SOURCE" "$CADDY_RUNTIME_IMAGE"

    note "Building the InvenTree image with plugin ${PLUGIN_VERSION}"
    build_context="$(mktemp -d)"
    trap 'if [[ -n "${build_context:-}" && -d "$build_context" ]]; then find "$build_context" -type f -delete; rmdir -- "$build_context/cache" "$build_context" 2>/dev/null || true; fi' RETURN
    mkdir -p -- "$build_context/cache"
    cp -- "$SCRIPT_DIR/Dockerfile" "$build_context/Dockerfile"
    cp -- "$plugin_archive" "$build_context/cache/plugin-source.tar.gz"
    "${DOCKER[@]}" build \
        --platform "linux/${DAEMON_ARCH}" \
        --build-arg "INVENTREE_BASE_SOURCE=${INVENTREE_BASE_SOURCE}" \
        --build-arg "PLUGIN_ARCHIVE_SHA256=${PLUGIN_ARCHIVE_SHA256}" \
        --build-arg "PLUGIN_ARCHIVE_SUBDIRECTORY=${PLUGIN_ARCHIVE_SUBDIRECTORY}" \
        --build-arg "PLUGIN_VERSION=${PLUGIN_VERSION}" \
        --tag "$INVENTREE_RUNTIME_IMAGE" \
        "$build_context"
    find "$build_context" -type f -delete
    rmdir -- "$build_context/cache" "$build_context"
    trap - RETURN

    snapshot_deployment_images
}

write_bundle_manifest() {
    local destination="$1/bundle.env"
    {
        printf 'INSTALLER_FORMAT_VERSION=%s\n' "$INSTALLER_FORMAT_VERSION"
        printf 'PLATFORM=linux/%s\n' "$DAEMON_ARCH"
        printf 'INVENTREE_IMAGE=%s\n' "$INVENTREE_RUNTIME_IMAGE"
        printf 'INVENTREE_IMAGE_ID=%s\n' "$INVENTREE_DEPLOY_IMAGE"
        printf 'POSTGRES_IMAGE=%s\n' "$POSTGRES_RUNTIME_IMAGE"
        printf 'POSTGRES_IMAGE_ID=%s\n' "$POSTGRES_DEPLOY_IMAGE"
        printf 'REDIS_IMAGE=%s\n' "$REDIS_RUNTIME_IMAGE"
        printf 'REDIS_IMAGE_ID=%s\n' "$REDIS_DEPLOY_IMAGE"
        printf 'CADDY_IMAGE=%s\n' "$CADDY_RUNTIME_IMAGE"
        printf 'CADDY_IMAGE_ID=%s\n' "$CADDY_DEPLOY_IMAGE"
        printf 'PLUGIN_VERSION=%s\n' "$PLUGIN_VERSION"
        printf 'PLUGIN_COMMIT=%s\n' "$PLUGIN_COMMIT"
    } > "$destination"
}

verify_runtime_image_ids() {
    local inventree_id="$1"
    local postgres_id="$2"
    local redis_id="$3"
    local caddy_id="$4"

    [[ "$(image_id "$INVENTREE_RUNTIME_IMAGE")" == "$inventree_id" ]] \
        || die "InvenTree image tag changed during bundle export"
    [[ "$(image_id "$POSTGRES_RUNTIME_IMAGE")" == "$postgres_id" ]] \
        || die "PostgreSQL image tag changed during bundle export"
    [[ "$(image_id "$REDIS_RUNTIME_IMAGE")" == "$redis_id" ]] \
        || die "Redis image tag changed during bundle export"
    [[ "$(image_id "$CADDY_RUNTIME_IMAGE")" == "$caddy_id" ]] \
        || die "Caddy image tag changed during bundle export"
}

export_offline_bundle() {
    local destination="$BUNDLE_DIR"
    local destination_parent="$EXPORT_LOCK_DIR"
    local destination_name
    destination_name="$(basename -- "$destination")"
    [[ -n "$destination_parent" ]] || die "Bundle export lock was not acquired"
    [[ "$destination_parent" == "$(dirname -- "$destination")" ]] \
        || die "Bundle export lock does not cover $destination"

    local previous="${destination}.previous"
    local obsolete=""
    if [[ -e "$previous" || -L "$previous" ]]; then
        [[ -d "$previous" && ! -L "$previous" ]] \
            || die "Previous bundle recovery path is not a regular directory: $previous"
        verify_bundle_directory "$previous"
        if [[ ! -e "$destination" && ! -L "$destination" ]]; then
            note "Recovering the previous complete offline bundle"
            mv -T -- "$previous" "$destination"
        else
            verify_bundle_directory "$destination"
            obsolete="$(mktemp -d --tmpdir="$destination_parent" ".${destination_name}.obsolete.XXXXXXXX")"
            rmdir -- "$obsolete"
            mv -T -- "$previous" "$obsolete"
            if ! remove_private_tree "$obsolete"; then
                printf 'Warning: a superseded bundle could not be fully removed: %s\n' "$obsolete" >&2
            fi
        fi
    fi

    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -d "$destination" && ! -L "$destination" ]] || die "Bundle output is not a regular directory: $destination"
        [[ -n "$(find "$destination" -mindepth 1 -print -quit)" ]] \
            || die "Refusing to replace an unrecognized empty directory: $destination"
        verify_bundle_directory "$destination"
    fi

    EXPORT_STAGING_DIR="$(mktemp -d --tmpdir="$destination_parent" ".${destination_name}.staging.XXXXXXXX")"
    local staging="$EXPORT_STAGING_DIR"
    note "Saving reusable offline bundle to $destination"
    mkdir -p -- "$staging/cache"
    cp -- "$SCRIPT_DIR/compose.yaml" "$SCRIPT_DIR/Caddyfile" "$SCRIPT_DIR/env.template" \
        "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/versions.env" "$SCRIPT_DIR/install-linux.sh" "$staging/"
    [[ -f "$SCRIPT_DIR/README.md" ]] && cp -- "$SCRIPT_DIR/README.md" "$staging/"
    [[ -f "$SCRIPT_DIR/install-windows.ps1" ]] && cp -- "$SCRIPT_DIR/install-windows.ps1" "$staging/"
    cp -- "$SCRIPT_DIR/cache/plugin-source.tar.gz" "$staging/cache/plugin-source.tar.gz"

    "${DOCKER[@]}" image save \
        --output "$staging/images-linux-${DAEMON_ARCH}.tar" \
        "$INVENTREE_DEPLOY_IMAGE" \
        "$POSTGRES_DEPLOY_IMAGE" \
        "$REDIS_DEPLOY_IMAGE" \
        "$CADDY_DEPLOY_IMAGE"
    verify_runtime_image_ids \
        "$INVENTREE_DEPLOY_IMAGE" \
        "$POSTGRES_DEPLOY_IMAGE" \
        "$REDIS_DEPLOY_IMAGE" \
        "$CADDY_DEPLOY_IMAGE"

    write_bundle_manifest "$staging"
    verify_runtime_image_ids \
        "$INVENTREE_DEPLOY_IMAGE" \
        "$POSTGRES_DEPLOY_IMAGE" \
        "$REDIS_DEPLOY_IMAGE" \
        "$CADDY_DEPLOY_IMAGE"
    cache_linux_docker_packages "$staging"

    (
        cd -- "$staging"
        # shellcheck disable=SC2094
        find . -type f ! -path ./SHA256SUMS ! -path ./SHA256SUMS.tmp -print0 \
            | sort -z \
            | xargs -0 sha256sum > SHA256SUMS.tmp
        mv -T -- SHA256SUMS.tmp SHA256SUMS
    )
    verify_bundle_directory "$staging"

    if [[ -d "$destination" ]]; then
        mv -T -- "$destination" "$previous"
    fi
    if ! mv -T -- "$staging" "$destination"; then
        [[ ! -d "$previous" ]] || mv -T -- "$previous" "$destination"
        die "Could not publish the completed offline bundle"
    fi
    EXPORT_STAGING_DIR=""
    if [[ -d "$previous" ]]; then
        obsolete="$(mktemp -d --tmpdir="$destination_parent" ".${destination_name}.obsolete.XXXXXXXX")"
        rmdir -- "$obsolete"
        mv -T -- "$previous" "$obsolete"
    fi
    if [[ -n "$obsolete" ]] && ! remove_private_tree "$obsolete"; then
        printf 'Warning: the new bundle is complete, but the previous bundle could not be fully removed: %s\n' "$obsolete" >&2
    fi
    release_export_lock
}

verify_bundle_structure() {
    local bundle_root="$1"
    [[ -d "$bundle_root" && ! -L "$bundle_root" ]] || die "Offline bundle is not a regular directory: $bundle_root"
    [[ -f "$bundle_root/SHA256SUMS" && ! -L "$bundle_root/SHA256SUMS" ]] || die "Offline bundle has no regular SHA256SUMS"
    [[ -z "$(find "$bundle_root" -type l -print -quit)" ]] || die "Offline bundle contains a symbolic link"

    local checksum_path special_path
    special_path="$(find "$bundle_root" -mindepth 1 ! -type f ! -type d -print -quit)"
    [[ -z "$special_path" ]] || die "Offline bundle contains a special file: $special_path"
    for checksum_path in versions.env bundle.env compose.yaml Caddyfile env.template Dockerfile install-linux.sh; do
        [[ -f "$bundle_root/$checksum_path" && ! -L "$bundle_root/$checksum_path" ]] \
            || die "Offline bundle is missing required file: $checksum_path"
    done
}

verify_bundle_directory() {
    local bundle_root="$1"
    verify_bundle_structure "$bundle_root"

    grep -Fqx "INSTALLER_FORMAT_VERSION=${INSTALLER_FORMAT_VERSION}" "$bundle_root/bundle.env" \
        || die "Offline bundle format does not match this installer"
    grep -Fqx "PLUGIN_COMMIT=${PLUGIN_COMMIT}" "$bundle_root/bundle.env" \
        || die "Offline bundle plugin does not match this installer"

    local actual_paths expected_paths checksum_line checksum_path
    actual_paths="$(mktemp)"
    expected_paths="$(mktemp)"
    : > "$expected_paths"
    while IFS= read -r checksum_line; do
        if [[ ! "$checksum_line" =~ ^[0-9a-fA-F]{64}[[:space:]][[:space:]](\./.+)$ ]]; then
            unlink -- "$actual_paths"
            unlink -- "$expected_paths"
            die "Offline bundle contains an invalid checksum entry"
        fi
        checksum_path="${BASH_REMATCH[1]}"
        if [[ "$checksum_path" == *'/../'* || "$checksum_path" == '../'* || "$checksum_path" == */.. ]]; then
            unlink -- "$actual_paths"
            unlink -- "$expected_paths"
            die "Offline bundle checksum path escapes the bundle"
        fi
        printf '%s\n' "$checksum_path" >> "$expected_paths"
    done < "$bundle_root/SHA256SUMS"

    (
        cd -- "$bundle_root"
        sha256sum --check --strict SHA256SUMS
    )

    (
        cd -- "$bundle_root"
        find . -type f ! -path ./SHA256SUMS -print | sort > "$actual_paths"
        sort -o "$expected_paths" "$expected_paths"
    )
    if ! cmp --silent "$actual_paths" "$expected_paths"; then
        unlink -- "$actual_paths"
        unlink -- "$expected_paths"
        die "Offline bundle contains missing or unlisted files"
    fi
    unlink -- "$actual_paths"
    unlink -- "$expected_paths"
}

verify_bundle_checksums() {
    note "Verifying offline bundle checksums"
    verify_bundle_directory "$OFFLINE_BUNDLE"
}

load_bundle_manifest() {
    local manifest="$OFFLINE_BUNDLE/bundle.env"
    [[ -f "$manifest" ]] || die "Offline bundle has no bundle.env"

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Invalid key in bundle.env: $key"
        printf -v "BUNDLE_${key}" '%s' "$value"
    done < "$manifest"

    [[ "${BUNDLE_INSTALLER_FORMAT_VERSION:-}" == "$INSTALLER_FORMAT_VERSION" ]] || die "Unsupported offline bundle format"
    [[ "${BUNDLE_PLATFORM:-}" == "linux/${DAEMON_ARCH}" ]] || die "Bundle platform ${BUNDLE_PLATFORM:-unknown} does not match linux/${DAEMON_ARCH}"
    [[ "${BUNDLE_PLUGIN_VERSION:-}" == "$PLUGIN_VERSION" ]] || die "Bundle plugin version does not match versions.env"
    [[ "${BUNDLE_PLUGIN_COMMIT:-}" == "$PLUGIN_COMMIT" ]] || die "Bundle plugin commit does not match versions.env"

    local required_key
    for required_key in \
        BUNDLE_INSTALLER_FORMAT_VERSION BUNDLE_PLATFORM \
        BUNDLE_INVENTREE_IMAGE BUNDLE_INVENTREE_IMAGE_ID \
        BUNDLE_POSTGRES_IMAGE BUNDLE_POSTGRES_IMAGE_ID \
        BUNDLE_REDIS_IMAGE BUNDLE_REDIS_IMAGE_ID \
        BUNDLE_CADDY_IMAGE BUNDLE_CADDY_IMAGE_ID \
        BUNDLE_PLUGIN_VERSION BUNDLE_PLUGIN_COMMIT; do
        [[ -n "${!required_key:-}" ]] || die "Bundle manifest is missing ${required_key#BUNDLE_}"
    done

    local image_key manifest_image_key expected_image image_id_key expected_id
    for image_key in INVENTREE POSTGRES REDIS CADDY; do
        case "$image_key" in
            INVENTREE) expected_image="$INVENTREE_RUNTIME_IMAGE" ;;
            POSTGRES) expected_image="$POSTGRES_RUNTIME_IMAGE" ;;
            REDIS) expected_image="$REDIS_RUNTIME_IMAGE" ;;
            CADDY) expected_image="$CADDY_RUNTIME_IMAGE" ;;
        esac
        manifest_image_key="BUNDLE_${image_key}_IMAGE"
        [[ "${!manifest_image_key}" == "$expected_image" ]] \
            || die "Bundle ${image_key} image reference does not match versions.env"
        image_id_key="BUNDLE_${image_key}_IMAGE_ID"
        expected_id="${!image_id_key:-}"
        [[ "$expected_id" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || die "Bundle ${image_key} image ID is invalid"
    done
}

verify_loaded_image() {
    local reference="$1"
    local expected_id="$2"
    local actual_id
    actual_id="$(image_id "$reference" 2>/dev/null || true)"
    [[ "$actual_id" == "$expected_id" ]] || die "Loaded image verification failed for $reference"
}

load_offline_images() {
    load_bundle_manifest
    note "Loading cached application images"
    "${DOCKER[@]}" image load --input "$OFFLINE_BUNDLE/images-linux-${DAEMON_ARCH}.tar"

    INVENTREE_RUNTIME_IMAGE="$BUNDLE_INVENTREE_IMAGE"
    POSTGRES_RUNTIME_IMAGE="$BUNDLE_POSTGRES_IMAGE"
    REDIS_RUNTIME_IMAGE="$BUNDLE_REDIS_IMAGE"
    CADDY_RUNTIME_IMAGE="$BUNDLE_CADDY_IMAGE"

    verify_loaded_image "$BUNDLE_INVENTREE_IMAGE_ID" "$BUNDLE_INVENTREE_IMAGE_ID"
    verify_loaded_image "$BUNDLE_POSTGRES_IMAGE_ID" "$BUNDLE_POSTGRES_IMAGE_ID"
    verify_loaded_image "$BUNDLE_REDIS_IMAGE_ID" "$BUNDLE_REDIS_IMAGE_ID"
    verify_loaded_image "$BUNDLE_CADDY_IMAGE_ID" "$BUNDLE_CADDY_IMAGE_ID"

    INVENTREE_DEPLOY_IMAGE="$BUNDLE_INVENTREE_IMAGE_ID"
    POSTGRES_DEPLOY_IMAGE="$BUNDLE_POSTGRES_IMAGE_ID"
    REDIS_DEPLOY_IMAGE="$BUNDLE_REDIS_IMAGE_ID"
    CADDY_DEPLOY_IMAGE="$BUNDLE_CADDY_IMAGE_ID"
    local installed_version
    installed_version="$("${DOCKER[@]}" run --rm --entrypoint python "$INVENTREE_DEPLOY_IMAGE" \
        -c 'import importlib.metadata; print(importlib.metadata.version("inventree-usd-irt-exchange-rate"))')"
    [[ "$installed_version" == "$PLUGIN_VERSION" ]] || die "Bundled plugin version verification failed"
}

random_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

migrate_deployment_image_references() {
    local keys=(INVENTREE_IMAGE INVENTREE_DB_IMAGE INVENTREE_CACHE_IMAGE INVENTREE_PROXY_IMAGE)
    local mutable_images=(
        "$INVENTREE_RUNTIME_IMAGE"
        "$POSTGRES_RUNTIME_IMAGE"
        "$REDIS_RUNTIME_IMAGE"
        "$CADDY_RUNTIME_IMAGE"
    )
    local immutable_images=(
        "$INVENTREE_DEPLOY_IMAGE"
        "$POSTGRES_DEPLOY_IMAGE"
        "$REDIS_DEPLOY_IMAGE"
        "$CADDY_DEPLOY_IMAGE"
    )
    local configured_value index
    local migration_required=false

    for index in "${!keys[@]}"; do
        configured_value="$(sed -n "s/^${keys[$index]}=//p" "$INSTALL_DIR/.env" | tail -n 1)"
        if [[ "$configured_value" == "${mutable_images[$index]}" ]]; then
            migration_required=true
        elif [[ "$configured_value" != "${immutable_images[$index]}" ]]; then
            die "Existing .env does not select this bundle's ${keys[$index]}. Update it explicitly or use a new install directory."
        fi
    done

    if [[ "$migration_required" == true ]]; then
        note "Replacing installer-owned image tags in $INSTALL_DIR/.env with immutable image IDs"
        ENV_TEMP_FILE="$(mktemp --tmpdir="$INSTALL_DIR" '.env.tmp.XXXXXXXX')"
        chmod 600 "$ENV_TEMP_FILE"
        awk \
            -v inventree_old="$INVENTREE_RUNTIME_IMAGE" \
            -v inventree_new="$INVENTREE_DEPLOY_IMAGE" \
            -v postgres_old="$POSTGRES_RUNTIME_IMAGE" \
            -v postgres_new="$POSTGRES_DEPLOY_IMAGE" \
            -v redis_old="$REDIS_RUNTIME_IMAGE" \
            -v redis_new="$REDIS_DEPLOY_IMAGE" \
            -v caddy_old="$CADDY_RUNTIME_IMAGE" \
            -v caddy_new="$CADDY_DEPLOY_IMAGE" \
            '$0 == "INVENTREE_IMAGE=" inventree_old { $0 = "INVENTREE_IMAGE=" inventree_new }
             $0 == "INVENTREE_DB_IMAGE=" postgres_old { $0 = "INVENTREE_DB_IMAGE=" postgres_new }
             $0 == "INVENTREE_CACHE_IMAGE=" redis_old { $0 = "INVENTREE_CACHE_IMAGE=" redis_new }
             $0 == "INVENTREE_PROXY_IMAGE=" caddy_old { $0 = "INVENTREE_PROXY_IMAGE=" caddy_new }
             { print }' \
            "$INSTALL_DIR/.env" > "$ENV_TEMP_FILE"
        mv -T -- "$ENV_TEMP_FILE" "$INSTALL_DIR/.env"
        ENV_TEMP_FILE=""

        for index in "${!keys[@]}"; do
            configured_value="$(sed -n "s/^${keys[$index]}=//p" "$INSTALL_DIR/.env" | tail -n 1)"
            [[ "$configured_value" == "${immutable_images[$index]}" ]] \
                || die "Could not migrate ${keys[$index]} to an immutable image ID"
        done
    fi
}

prepare_deployment_files() {
    local asset_root="$SCRIPT_DIR"
    [[ -z "$OFFLINE_BUNDLE" ]] || asset_root="$OFFLINE_BUNDLE"

    require_directory_path "$INSTALL_DIR" "Install directory"
    local data_directory
    for data_directory in \
        inventree-data \
        inventree-data/database \
        inventree-data/static \
        inventree-data/media \
        inventree-data/caddy \
        inventree-data/caddy/data \
        inventree-data/caddy/config; do
        require_directory_path "$INSTALL_DIR/$data_directory" "InvenTree data directory"
    done

    require_regular_path "$INSTALL_DIR/.installed" "Installation marker"
    local owned_asset
    for owned_asset in compose.yaml Caddyfile; do
        require_regular_path "$INSTALL_DIR/$owned_asset" "$owned_asset"
        if [[ -e "$INSTALL_DIR/$owned_asset" ]]; then
            cmp --silent "$asset_root/$owned_asset" "$INSTALL_DIR/$owned_asset" \
                || die "Existing $INSTALL_DIR/$owned_asset differs from this installer. Move it aside explicitly or choose a new install directory."
        else
            copy_if_missing "$asset_root/$owned_asset" "$INSTALL_DIR/$owned_asset"
        fi
    done

    require_regular_path "$INSTALL_DIR/.env" ".env"
    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        local db_password
        db_password="$(random_password)"
        ENV_TEMP_FILE="$(mktemp --tmpdir="$INSTALL_DIR" '.env.tmp.XXXXXXXX')"
        chmod 600 "$ENV_TEMP_FILE"
        sed \
            -e "s|__INVENTREE_IMAGE__|${INVENTREE_DEPLOY_IMAGE}|g" \
            -e "s|__POSTGRES_IMAGE__|${POSTGRES_DEPLOY_IMAGE}|g" \
            -e "s|__REDIS_IMAGE__|${REDIS_DEPLOY_IMAGE}|g" \
            -e "s|__CADDY_IMAGE__|${CADDY_DEPLOY_IMAGE}|g" \
            -e "s|__HTTP_PORT__|${HTTP_PORT}|g" \
            -e "s|__DB_PASSWORD__|${db_password}|g" \
            "$asset_root/env.template" > "$ENV_TEMP_FILE"
        mv -T -- "$ENV_TEMP_FILE" "$INSTALL_DIR/.env"
        ENV_TEMP_FILE=""
    else
        note "Checking existing $INSTALL_DIR/.env"
        migrate_deployment_image_references

        local configured_port
        configured_port="$(sed -n 's/^INVENTREE_HTTP_PORT=//p' "$INSTALL_DIR/.env" | tail -n 1)"
        [[ "$configured_port" == "$HTTP_PORT" ]] \
            || die "Existing .env uses HTTP port ${configured_port:-unknown}; rerun with --http-port ${configured_port:-PORT}."
    fi
}

compose() {
    "${DOCKER[@]}" compose \
        --project-directory "$INSTALL_DIR" \
        --file "$INSTALL_DIR/compose.yaml" \
        --env-file "$INSTALL_DIR/.env" \
        "$@"
}

existing_admin_count() {
    compose run --rm --no-deps --entrypoint python inventree-server \
        src/backend/InvenTree/manage.py shell -c \
        'from django.contrib.auth import get_user_model; print(get_user_model().objects.filter(is_superuser=True).count())' \
        | tail -n 1
}

deploy_application() {
    note "Validating deployment configuration"
    compose config --quiet

    note "Stopping application processes before migration"
    compose stop inventree-proxy inventree-worker inventree-server

    note "Starting database and cache"
    compose up -d --pull never --no-build inventree-db inventree-cache

    note "Applying database migrations and collecting static files"
    compose run --rm --no-deps --entrypoint python inventree-server -c \
        "import importlib.metadata; assert importlib.metadata.version('inventree-usd-irt-exchange-rate') == '${PLUGIN_VERSION}'" >/dev/null
    if [[ -f "$INSTALL_DIR/.installed" ]]; then
        note "Backing up the existing InvenTree database and media"
        compose run --rm inventree-server invoke backup
    fi
    compose run --rm inventree-server invoke migrate
    compose run --rm inventree-server invoke static
    compose run --rm inventree-server invoke int.clean-settings

    if [[ "$SKIP_ADMIN" == false ]] && [[ "$(existing_admin_count)" == 0 ]]; then
        note "Create the first InvenTree administrator"
        compose run --rm inventree-server invoke superuser
    fi

    note "Starting InvenTree"
    compose up -d --pull never --no-build --wait --wait-timeout 300 inventree-db inventree-cache inventree-server inventree-proxy
    compose up -d --pull never --no-build inventree-worker

    local worker_attempt
    for ((worker_attempt = 1; worker_attempt <= 12; worker_attempt++)); do
        if compose exec -T inventree-worker invoke worker-health --timeout=3 >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done
    compose exec -T inventree-worker invoke worker-health --timeout=3 >/dev/null \
        || die "InvenTree started, but its background worker is not healthy"

    local installed_version
    installed_version="$(compose exec -T inventree-server python -c 'import importlib.metadata; print(importlib.metadata.version("inventree-usd-irt-exchange-rate"))')"
    [[ "$installed_version" == "$PLUGIN_VERSION" ]] || die "Running plugin verification failed"

    local active_plugin
    active_plugin="$(compose exec -T inventree-server python src/backend/InvenTree/manage.py shell -c \
        "from plugin.registry import registry; print('active' if registry.get_plugin('inventree-usd-irt-exchange-rate') else 'inactive')" \
        | tail -n 1)"
    [[ "$active_plugin" == active ]] || die "The USD/IRT plugin is installed but not active"

    INSTALLED_TEMP_FILE="$(mktemp --tmpdir="$INSTALL_DIR" '.installed.tmp.XXXXXXXX')"
    chmod 600 "$INSTALLED_TEMP_FILE"
    {
        printf 'INSTALLER_FORMAT_VERSION=%s\n' "$INSTALLER_FORMAT_VERSION"
        printf 'PLUGIN_VERSION=%s\n' "$PLUGIN_VERSION"
        printf 'PLUGIN_COMMIT=%s\n' "$PLUGIN_COMMIT"
    } > "$INSTALLED_TEMP_FILE"
    mv -T -- "$INSTALLED_TEMP_FILE" "$INSTALL_DIR/.installed"
    INSTALLED_TEMP_FILE=""

    note "InvenTree is ready at http://localhost:${HTTP_PORT}"
    printf 'Data and automatic backups: %s/inventree-data\n' "$INSTALL_DIR"
    printf 'TGJU live updates are disabled by default. Configure the plugin in Admin Center to enable them.\n'
}

main() {
    parse_arguments "$@"
    detect_platform

    if [[ -n "$OFFLINE_BUNDLE" ]]; then
        SCRIPT_DIR="$OFFLINE_BUNDLE"
        if path_is_within "$INSTALL_DIR" "$OFFLINE_BUNDLE"; then
            die "Install directory cannot equal or be inside the offline bundle"
        fi
        require_command sha256sum
        verify_bundle_structure "$OFFLINE_BUNDLE"
    fi
    load_versions "$SCRIPT_DIR/versions.env"
    if [[ -n "$OFFLINE_BUNDLE" ]]; then
        verify_bundle_checksums
    fi

    ensure_docker
    verify_docker_platform

    if [[ "$PREPARE_ONLY" == false ]]; then
        require_directory_path "$INSTALL_DIR" "Install directory"
        check_install_lock
    fi

    if [[ -z "$OFFLINE_BUNDLE" && "$NO_OFFLINE_CACHE" == false ]]; then
        prepare_bundle_destination
        check_export_lock "$EXPORT_LOCK_DIR"
    fi

    if [[ -n "$OFFLINE_BUNDLE" ]]; then
        load_offline_images
    else
        require_command curl
        require_command sha256sum
        acquire_application_images
        if [[ "$NO_OFFLINE_CACHE" == false ]]; then
            export_offline_bundle
        fi
    fi

    if [[ "$PREPARE_ONLY" == true ]]; then
        note "Preparation complete"
        if [[ -z "$OFFLINE_BUNDLE" && "$NO_OFFLINE_CACHE" == false ]]; then
            printf 'Offline bundle: %s\n' "$BUNDLE_DIR"
            printf 'Container image archive: %s/images-linux-%s.tar\n' "$BUNDLE_DIR" "$DAEMON_ARCH"
            if [[ -d "$BUNDLE_DIR/prerequisites" ]]; then
                printf 'Docker prerequisite cache: %s/prerequisites\n' "$BUNDLE_DIR"
            fi
            printf 'Manual image load: docker image load --input %q\n' \
                "$BUNDLE_DIR/images-linux-${DAEMON_ARCH}.tar"
        fi
        return
    fi

    prepare_deployment_files
    deploy_application
}

main "$@"
