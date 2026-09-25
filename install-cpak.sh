#!/usr/bin/env bash
set -Eeuo pipefail

CPAK_VERSION=v2.13.3
CPAK_ORIGIN=github.com/srdicov/cspenguin-installer-cpak
INSTALL_DIR="${CPAK_INSTALL_DIR:-$HOME/.local/bin}"

[[ "$(uname -m)" == "x86_64" ]] || {
    printf '%s\n' "This package requires Linux amd64." >&2
    exit 1
}

for command_name in sha256sum install mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf '%s\n' "Missing command: $command_name" >&2
        exit 1
    }
done

command -v curl >/dev/null 2>&1 || {
    printf '%s\n' "curl is required." >&2
    exit 1
}

download() {
    curl -fL --retry 3 --connect-timeout 30 -o "$2" "$1"
}

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
RELEASE_URL="https://github.com/Containerpak/cpak/releases/download/$CPAK_VERSION"

download "$RELEASE_URL/cpak-linux-amd64" "$TEMP_DIR/cpak-linux-amd64"
download "$RELEASE_URL/cpak-storaged-linux-amd64" "$TEMP_DIR/cpak-storaged-linux-amd64"
download "$RELEASE_URL/SHA256SUMS" "$TEMP_DIR/SHA256SUMS"

(
    cd "$TEMP_DIR"
    sha256sum -c --ignore-missing SHA256SUMS
)

install -Dm755 "$TEMP_DIR/cpak-linux-amd64" "$INSTALL_DIR/cpak"
install -Dm755 "$TEMP_DIR/cpak-storaged-linux-amd64" "$INSTALL_DIR/cpak-storaged"

"$INSTALL_DIR/cpak" doctor
exec "$INSTALL_DIR/cpak" install -y "$CPAK_ORIGIN"
