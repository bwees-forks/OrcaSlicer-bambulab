#!/bin/bash
set -euo pipefail

PACKAGE_DIR=""
PLUGIN_DIR=""
PLUGIN_CACHE_DIR=""
REPLACE_EXISTING=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -PackageDir)
            PACKAGE_DIR="${2:-}"
            shift 2
            ;;
        -PluginDir)
            PLUGIN_DIR="${2:-}"
            shift 2
            ;;
        -PluginCacheDir)
            PLUGIN_CACHE_DIR="${2:-}"
            shift 2
            ;;
        -ReplaceExisting)
            REPLACE_EXISTING=1
            shift
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$PLUGIN_DIR" ]]; then
    PLUGIN_DIR="$PACKAGE_DIR"
fi
if [[ -z "$PLUGIN_DIR" ]]; then
    echo "PluginDir is required" >&2
    exit 2
fi

APP_SUPPORT_DIR="$HOME/Library/Application Support/OrcaSlicer/macos-bridge"
LOCAL_LIMA_ROOT="$APP_SUPPORT_DIR/lima"
LOCAL_LIMA_BIN="$LOCAL_LIMA_ROOT/bin"
RUNTIME_DIR="${PJARCZAK_MAC_RUNTIME_DIR:-$APP_SUPPORT_DIR/runtime}"
mkdir -p "$APP_SUPPORT_DIR" "$LOCAL_LIMA_ROOT" "$RUNTIME_DIR"

log() {
    printf '[install_runtime_macos] %s\n' "$*" >&2
}

trim_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        return 1
    fi
    LC_ALL=C tr -d '\r' < "$path" | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

find_limactl() {
    if [[ -n "${PJARCZAK_LIMACTL:-}" && -x "${PJARCZAK_LIMACTL}" ]]; then
        printf '%s\n' "$PJARCZAK_LIMACTL"
        return 0
    fi
    if command -v limactl >/dev/null 2>&1; then
        command -v limactl
        return 0
    fi
    if [[ -x "$LOCAL_LIMA_BIN/limactl" ]]; then
        printf '%s\n' "$LOCAL_LIMA_BIN/limactl"
        return 0
    fi
    for candidate in /opt/homebrew/bin/limactl /usr/local/bin/limactl; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

resolve_lima_version_from_redirect() {
    local effective_url=""
    effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/lima-vm/lima/releases/latest || true)
    case "$effective_url" in
        */tag/*)
            printf '%s\n' "${effective_url##*/}"
            return 0
            ;;
    esac
    return 1
}

resolve_lima_version() {
    if [[ -n "${PJARCZAK_LIMA_VERSION:-}" ]]; then
        printf '%s\n' "$PJARCZAK_LIMA_VERSION"
        return 0
    fi

    local version=""
    version=$(curl -fsSL https://api.github.com/repos/lima-vm/lima/releases/latest | awk -F'"' '/"tag_name"[[:space:]]*:/ { print $4; exit }' || true)
    if [[ -n "$version" ]]; then
        printf '%s\n' "$version"
        return 0
    fi

    resolve_lima_version_from_redirect
}

install_lima_binary_locally() {
    local version
    version=$(resolve_lima_version)
    if [[ -z "$version" ]]; then
        echo "failed to resolve latest Lima version from GitHub API" >&2
        return 1
    fi

    local host_arch
    host_arch=$(uname -m)
    case "$host_arch" in
        arm64|aarch64)
            host_arch=arm64
            ;;
        x86_64|amd64)
            host_arch=x86_64
            ;;
        *)
            echo "unsupported macOS architecture for Lima: $host_arch" >&2
            return 1
            ;;
    esac

    local version_no_v="${version#v}"
    local base_url="https://github.com/lima-vm/lima/releases/download/${version}"
    local main_archive="lima-${version_no_v}-Darwin-${host_arch}.tar.gz"
    local guest_archive="lima-additional-guestagents-${version_no_v}-Darwin-${host_arch}.tar.gz"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    log "downloading Lima ${version} (${host_arch})"
    curl -fL --retry 3 --retry-delay 2 "$base_url/$main_archive" -o "$tmpdir/$main_archive"
    tar -xzf "$tmpdir/$main_archive" -C "$LOCAL_LIMA_ROOT"

    if curl -fL --retry 3 --retry-delay 2 "$base_url/$guest_archive" -o "$tmpdir/$guest_archive"; then
        tar -xzf "$tmpdir/$guest_archive" -C "$LOCAL_LIMA_ROOT"
    fi

    [[ -x "$LOCAL_LIMA_BIN/limactl" ]]
}

ensure_lima_installed() {
    LIMACTL=$(find_limactl || true)
    if [[ -n "$LIMACTL" ]]; then
        log "using existing limactl: $LIMACTL"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        log "installing Lima via Homebrew"
        brew install lima
        LIMACTL=$(find_limactl || true)
        if [[ -n "$LIMACTL" ]]; then
            return 0
        fi
    fi

    install_lima_binary_locally
    LIMACTL=$(find_limactl || true)
    [[ -n "$LIMACTL" ]]
}

maybe_install_rosetta() {
    if [[ "$(uname -m)" != "arm64" ]]; then
        return 0
    fi
    if pgrep -q oahd >/dev/null 2>&1; then
        return 0
    fi
    log "installing Rosetta 2 (required to run x86_64 linux binaries on arm64)"
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license >/dev/null 2>&1 || true
}

copy_runtime_payload() {
    local src_dir="$1"
    local dst_dir="$2"
    local file
    local required_files=(
        libbambu_networking.so
        libBambuSource.so
        pjarczak_bambu_linux_host
        pjarczak_bambu_linux_host_abi1
        pjarczak_bambu_linux_host_abi0
        ca-certificates.crt
        slicer_base64.cer
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "$src_dir/$file" ]]; then
            echo "missing required runtime payload file: $file" >&2
            exit 1
        fi
        cp -f "$src_dir/$file" "$dst_dir/$file"
    done

    for file in liblive555.so libagora_rtc_sdk.so libagora-fdkaac.so; do
        if [[ -f "$src_dir/$file" ]]; then
            cp -f "$src_dir/$file" "$dst_dir/$file"
        fi
    done

    # Mirror the Lima instance descriptor and helper scripts into the runtime
    # dir so the host wrapper can resolve the instance name even when the
    # bridge dylib invokes it without a PJARCZAK_MAC_LIMA_INSTANCE env var.
    for file in pjarczak_lima_instance.txt linux_payload_manifest.json; do
        if [[ -f "$src_dir/$file" ]]; then
            cp -f "$src_dir/$file" "$dst_dir/$file"
        fi
    done

    chmod 755 "$dst_dir/pjarczak_bambu_linux_host" "$dst_dir/pjarczak_bambu_linux_host_abi1" "$dst_dir/pjarczak_bambu_linux_host_abi0"
}

resolve_instance_name() {
    if [[ -n "${PJARCZAK_MAC_LIMA_INSTANCE:-}" ]]; then
        printf '%s\n' "$PJARCZAK_MAC_LIMA_INSTANCE"
        return 0
    fi

    local candidate
    for candidate in "$PLUGIN_DIR/pjarczak_lima_instance.txt" "$RUNTIME_DIR/pjarczak_lima_instance.txt"; do
        local value
        value=$(trim_file "$candidate" 2>/dev/null || true)
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done

    printf '%s\n' "orcaslicer-bambu-network"
}

instance_exists() {
    "$LIMACTL" list --format='{{.Name}}' 2>/dev/null | grep -qx "$INSTANCE"
}

instance_reachable() {
    "$LIMACTL" shell "$INSTANCE" -- /usr/bin/env true >/dev/null 2>&1
}

start_or_create_instance() {
    local -a start_args=(start "--name=${INSTANCE}" --tty=false --mount-writable)
    local macos_major
    macos_major=$(sw_vers -productVersion | awk -F. '{print $1}')
    if [[ "${macos_major:-0}" -ge 13 ]]; then
        start_args+=(--vm-type=vz --network=vzNAT)
        if [[ "$(uname -m)" == "arm64" ]]; then
            start_args+=(--rosetta)
        fi
    fi

    if instance_exists; then
        log "starting existing Lima instance '$INSTANCE'"
        "$LIMACTL" start "$INSTANCE" >/dev/null
    else
        log "creating new Lima instance '$INSTANCE' from template:default"
        "$LIMACTL" "${start_args[@]}" template://default
    fi
}

INSTANCE=$(resolve_instance_name)
log "lima instance: $INSTANCE"
log "runtime dir:   $RUNTIME_DIR"
log "plugin dir:    $PLUGIN_DIR"

copy_runtime_payload "$PLUGIN_DIR" "$RUNTIME_DIR"
ensure_lima_installed
maybe_install_rosetta

if [[ "$REPLACE_EXISTING" -eq 1 ]] && instance_exists; then
    log "stopping and removing existing instance for clean reinstall"
    "$LIMACTL" stop --force "$INSTANCE" >/dev/null 2>&1 || true
    "$LIMACTL" delete "$INSTANCE" >/dev/null 2>&1 || true
fi

if ! instance_reachable; then
    start_or_create_instance
fi

"$LIMACTL" start-at-login "$INSTANCE" --enabled >/dev/null 2>&1 || true

if ! instance_reachable; then
    log "Lima instance did not come up after start; check 'limactl list' and logs in ~/.lima/$INSTANCE/" >&2
    exit 1
fi

log "verifying linux host binary is executable inside the VM"
if ! "$LIMACTL" shell "$INSTANCE" -- test -x "$RUNTIME_DIR/pjarczak_bambu_linux_host"; then
    log "linux host binary not visible inside the VM; ensure $HOME is mounted (Lima default template mounts the user home)" >&2
    exit 1
fi

# The bundled linux host and .so files are x86_64. On Apple Silicon the VM is
# arm64 with Rosetta 2 registered for x86_64 binfmt, but Rosetta only handles
# instruction translation — the VM still needs an x86_64 dynamic linker
# (/lib64/ld-linux-x86-64.so.2) and basic userland libraries to actually load
# the binary. Provision them now, idempotently, so the host is loadable on
# first run. On x86_64 Macs (vm-type=vz, native x86_64 Ubuntu) these are
# already present, but `dpkg --add-architecture amd64` is a no-op there.
if [[ "$(uname -m)" == "arm64" ]]; then
    log "provisioning x86_64 multiarch runtime inside Lima (one-time)"
    PROBE_LD_PATH='/lib64/ld-linux-x86-64.so.2'
    if ! "$LIMACTL" shell "$INSTANCE" -- test -e "$PROBE_LD_PATH" >/dev/null 2>&1; then
        # Stock arm64 Ubuntu sources point at ports.ubuntu.com which has no
        # amd64 packages — apt 404s on every amd64 fetch. Add archive.ubuntu.com
        # as an amd64-only source and pin the existing sources to arm64 first.
        if ! "$LIMACTL" shell "$INSTANCE" -- sudo /bin/bash -c '
            set -e
            export DEBIAN_FRONTEND=noninteractive
            . /etc/os-release
            CN="${UBUNTU_CODENAME:-noble}"
            if [ -f /etc/apt/sources.list.d/ubuntu.sources ] && ! grep -q "^Architectures:" /etc/apt/sources.list.d/ubuntu.sources; then
                sed -i "/^Types:/a Architectures: arm64" /etc/apt/sources.list.d/ubuntu.sources
            fi
            cat > /etc/apt/sources.list.d/orca-amd64.sources <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: ${CN} ${CN}-updates ${CN}-backports
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            cat > /etc/apt/sources.list.d/orca-amd64-security.sources <<EOF
Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: ${CN}-security
Components: main restricted universe multiverse
Architectures: amd64
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
            dpkg --add-architecture amd64
            apt-get update -qq
            # Try the t64 names first (Ubuntu 24.04+); fall back to legacy names.
            apt-get install -y --no-install-recommends \
                libc6:amd64 libstdc++6:amd64 zlib1g:amd64 \
                libssl3t64:amd64 libcurl4t64:amd64 \
              || apt-get install -y --no-install-recommends \
                libc6:amd64 libstdc++6:amd64 zlib1g:amd64 \
                libssl3:amd64 libcurl4:amd64
        ' >&2; then
            log "WARNING: x86_64 multiarch provisioning failed; linux host may fail to load" >&2
        fi
    else
        log "x86_64 dynamic linker already present in VM"
    fi
fi

printf 'runtime installed\n'
