#!/usr/bin/env bash
set -euo pipefail

REPO="${WASMZ_REPO:-Ray-D-Song/wasmz}"
INSTALL_DIR="${WASMZ_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${WASMZ_VERSION:-latest}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

info() {
    echo "» $*"
}

usage() {
    cat <<'EOF'
Install the latest wasmz GitHub release into your user bin directory.

Usage:
  ./install.sh [--dir DIR] [--tag TAG] [--repo OWNER/REPO]

Options:
  --dir DIR        Install into DIR instead of ~/.local/bin
  --tag TAG        Install a specific release tag instead of the latest release
  --repo REPO      GitHub repository to install from (default: Ray-D-Song/wasmz)
  -h, --help       Show this help text

Environment variables:
  WASMZ_INSTALL_DIR   Same as --dir
  WASMZ_VERSION       Same as --tag (use "latest" for latest stable release)
  WASMZ_REPO          Same as --repo
  GH_TOKEN            Optional GitHub token for API requests
  GITHUB_TOKEN        Optional GitHub token for API requests
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            [[ $# -ge 2 ]] || die "--dir requires a value"
            INSTALL_DIR="$2"
            shift 2
            ;;
        --tag)
            [[ $# -ge 2 ]] || die "--tag requires a value"
            VERSION="$2"
            shift 2
            ;;
        --repo)
            [[ $# -ge 2 ]] || die "--repo requires a value"
            REPO="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

need_cmd curl
need_cmd uname
need_cmd mktemp

OS="$(uname -s)"
ARCH="$(uname -m)"

platform_suffix() {
    local os="$1"
    local arch="$2"
    local platform
    local machine

    case "$os" in
        Linux)
            platform="linux"
            ;;
        Darwin)
            platform="macos"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            platform="windows"
            ;;
        *)
            die "Unsupported operating system: $os"
            ;;
    esac

    case "$arch" in
        x86_64|amd64)
            machine="x86_64"
            ;;
        aarch64|arm64)
            machine="arm64"
            ;;
        riscv64)
            machine="riscv64"
            ;;
        loongarch64)
            machine="loongarch64"
            ;;
        *)
            die "Unsupported architecture: $arch"
            ;;
    esac

    case "$platform-$machine" in
        macos-x86_64|macos-arm64|windows-x86_64|windows-arm64|linux-x86_64|linux-arm64|linux-riscv64|linux-loongarch64)
            printf '%s\n' "$platform-$machine"
            ;;
        *)
            die "No published wasmz release artifact for $platform-$machine"
            ;;
    esac
}

PLATFORM_SUFFIX="$(platform_suffix "$OS" "$ARCH")"

ARCHIVE_EXT="tar.gz"
BINARY_NAME="wasmz"
if [[ "$PLATFORM_SUFFIX" == windows-* ]]; then
    ARCHIVE_EXT="zip"
    BINARY_NAME="wasmz.exe"
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

curl_headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
)

if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

resolve_tag() {
    local repo="$1"
    local requested="$2"

    if [[ "$requested" != "latest" ]]; then
        printf '%s\n' "$requested"
        return 0
    fi

    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    local response
    if ! response="$(curl -fsSL "${curl_headers[@]}" "$api_url")"; then
        die "Unable to fetch latest release from ${repo}. Make sure at least one GitHub release has been published."
    fi

    local tag
    tag="$(printf '%s\n' "$response" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [[ -n "$tag" ]] || die "Failed to parse latest release tag from GitHub API response."
    printf '%s\n' "$tag"
}

extract_zip() {
    local archive="$1"
    local dest="$2"

    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$archive" -d "$dest"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$archive" "$dest" <<'PY'
import sys
import zipfile

archive, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as zf:
    zf.extractall(dest)
PY
        return 0
    fi

    die "Need 'unzip' or 'python3' to extract zip archives."
}

install_file() {
    local src="$1"
    local dst="$2"
    local tmp_dst="${dst}.tmp.$$"

    cp "$src" "$tmp_dst"
    chmod 755 "$tmp_dst"
    mv "$tmp_dst" "$dst"
}

TAG="$(resolve_tag "$REPO" "$VERSION")"
ARCHIVE_NAME="wasmz-${TAG}-${PLATFORM_SUFFIX}.${ARCHIVE_EXT}"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ARCHIVE_NAME}"
ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE_NAME}"
EXTRACT_DIR="${TMP_DIR}/extract"
TARGET_PATH="${INSTALL_DIR}/${BINARY_NAME}"

mkdir -p "$INSTALL_DIR" "$EXTRACT_DIR"

info "Resolved release tag: ${TAG}"
info "Detected platform: ${PLATFORM_SUFFIX}"
info "Downloading ${DOWNLOAD_URL}"

if ! curl -fL --progress-bar -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"; then
    die "Failed to download ${ARCHIVE_NAME}. The release may not contain an artifact for ${PLATFORM_SUFFIX}."
fi

case "$ARCHIVE_EXT" in
    tar.gz)
        tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
        ;;
    zip)
        extract_zip "$ARCHIVE_PATH" "$EXTRACT_DIR"
        ;;
    *)
        die "Unsupported archive format: $ARCHIVE_EXT"
        ;;
esac

SOURCE_PATH="${EXTRACT_DIR}/${BINARY_NAME}"
[[ -f "$SOURCE_PATH" ]] || die "Downloaded archive did not contain ${BINARY_NAME}"

install_file "$SOURCE_PATH" "$TARGET_PATH"

info "Installed ${BINARY_NAME} to ${TARGET_PATH}"

case ":${PATH}:" in
    *:"${INSTALL_DIR}":*)
        ;;
    *)
        warn "${INSTALL_DIR} is not in your PATH."
        warn "Add this to your shell profile:"
        warn "  export PATH=\"${INSTALL_DIR}:\$PATH\""
        ;;
esac
