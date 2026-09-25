#!/usr/bin/env bash
set -Eeuo pipefail

VERBOSE=0
SKIP_WINETRICKS=0
DRY_RUN=0
UPDATE_WINE=0
UPDATE_ONLY=0
_ESYNC_RESTART=0
for arg in "$@"; do
    [[ "$arg" == "--verbose"         || "$arg" == "-v" ]] && VERBOSE=1
    [[ "$arg" == "--skip-winetricks" || "$arg" == "-s" ]] && SKIP_WINETRICKS=1
    [[ "$arg" == "--dry-run"         || "$arg" == "-n" ]] && DRY_RUN=1
    [[ "$arg" == "--update-wine"     || "$arg" == "-w" ]] && UPDATE_WINE=1
    [[ "$arg" == "--update"          || "$arg" == "-u" ]] && UPDATE_ONLY=1
done

CPAK_MODE=0
[[ -n "${CPAK_CONTAINER_ID:-}" || "${CSPENGUIN_CPAK:-0}" == "1" ]] && CPAK_MODE=1

# Debug knob for prefix creation (e.g. CSPENGUIN_WINEBOOT_DEBUG=+loaddll).
# Passed through `cpak run --env` without editing the script.
WINEBOOT_DEBUG="${CSPENGUIN_WINEBOOT_DEBUG:--all}"

DOWNLOAD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/csp-install"

# colors (plain output; no 256-color probing)
# (plain output, no colors)

# formatting
TOTAL_STEPS=7
STEP=0

# _log writes a plain-text (no ANSI codes) trail of what happened to
# LOG_FILE, independent of what run() captures from external commands.
_log() { [[ -n "${LOG_FILE:-}" ]] && echo "$1" >> "$LOG_FILE" 2>/dev/null; }

_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "sudo is required for system changes"
    fi
}

step() {
    STEP=$((STEP + 1))
    echo ""
    echo "[${STEP}/${TOTAL_STEPS}] $1"
    _log "[STEP ${STEP}/${TOTAL_STEPS}] $1"
}

ok()   { echo "+ $1"; _log "OK: $1"; }
warn() { echo "! $1"; _log "WARN: $1"; }
info() { echo "- $1"; _log "INFO: $1"; }
gap()  { echo ""; }
msg()  { echo "$1"; _log "$1"; }

die() {
    echo ""
    echo "ERROR: $1"
    [[ -n "${LOG_FILE:-}" ]] && echo "log: $LOG_FILE"
    echo "https://github.com/SrDicov/CSPenguin-Installer-cpak/issues"
    _log "ERROR: $1"
    exit 1
}

# catch and log command failures
_on_error() {
    local _exit=$? _line="$1" _cmd="$2"
    _log "UNEXPECTED ERROR at line ${_line} (exit ${_exit}): ${_cmd}"
    echo ""
    echo "ERROR: unexpected failure at line ${_line}: ${_cmd} (exit ${_exit})"
    [[ -n "${LOG_FILE:-}" ]] && echo "log: $LOG_FILE"
    echo "https://github.com/SrDicov/CSPenguin-Installer-cpak/issues"
}

# cleanup
_install_ok=0
cleanup() {
    [[ $DRY_RUN -eq 1 ]] && return
    rm -f "$DOWNLOAD_DIR"/*.part 2>/dev/null
    [[ $_install_ok -eq 0 ]] && [[ $UPDATE_ONLY -eq 0 ]] && wineserver -k 2>/dev/null || true
}
trap cleanup EXIT

# paths
_candidate="$(cd "$(dirname "${BASH_SOURCE[0]:-/}")" 2>/dev/null && pwd)"
if [[ -d "$_candidate/patches" ]]; then
    SCRIPT_DIR="$_candidate"
else
    SCRIPT_DIR="$DOWNLOAD_DIR"
fi

WINEPREFIX="${WINEPREFIX:-$HOME/.wine-csp}"
WINEARCH=win64

WINE_VERSION="11.4"
WINE_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/wine-${WINE_VERSION}-amd64.tar.xz"
WINE_SHA256="b98761339edb5cf9a3f622fa08de2d4b453ab96e2b5d8a612aa3687ea6ec523f"
FREETYPE_VERSION="2.13.2"
FREETYPE_URL="https://archive.archlinux.org/packages/f/freetype2/freetype2-${FREETYPE_VERSION}-1-x86_64.pkg.tar.zst"
FREETYPE32_URL="https://archive.archlinux.org/packages/l/lib32-freetype2/lib32-freetype2-${FREETYPE_VERSION}-1-x86_64.pkg.tar.zst"
WEBVIEW2_URL="https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/76eb3dc4-7851-45b7-a392-460523b0e2bb/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
WEBVIEW2_SHA256="9f4b90be849ee2fdb1260ff5236bd0faffc5b3e5b48113918ddc6ab031ebbb9e"
WEBVIEW2_FILE="$DOWNLOAD_DIR/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
WEBVIEW2_MANAGED="/opt/cspenguin/MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
WEBVIEW2_FIXED_ROOT="$WINEPREFIX/drive_c/CSPenguinWebView2"
WEBVIEW2_INSTALLED_ROOT="$WINEPREFIX/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application"
WEBVIEW2_FIXED_DIR=""
WINETRICKS_URL="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
GECKO_VERSION="2.47.4"
GECKO_URL="https://dl.winehq.org/wine/wine-gecko/${GECKO_VERSION}/wine-gecko-${GECKO_VERSION}-x86_64.msi"
GECKO_MSI="$DOWNLOAD_DIR/wine-gecko-${GECKO_VERSION}-x86_64.msi"
GECKO_SHA="e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"
LAUNCHER_DIR="$HOME/.local/share/cspenguin"
WINE_DIR="${CSPENGUIN_WINE_DIR:-$LAUNCHER_DIR/wine-${WINE_VERSION}}"
WINE_BIN="$WINE_DIR/bin/wine"
WINESERVER_BIN="$WINE_DIR/bin/wineserver"
FREETYPE_DIR="$WINE_DIR/lib/freetype2-${FREETYPE_VERSION}"
# Baked Wine runtime shipped inside the cpak image (see Containerfile).
# In cpak mode it takes precedence over the per-user runtime so first-launch
# needs no Wine download; explicit $CSPENGUIN_WINE_DIR still wins.
BAKED_WINE_DIR="/opt/cspenguin/wine-${WINE_VERSION}"
if [[ $CPAK_MODE -eq 1 && -z "${CSPENGUIN_WINE_DIR:-}" && ! -x "$WINE_BIN" && -x "$BAKED_WINE_DIR/bin/wine" ]]; then
    WINE_DIR="$BAKED_WINE_DIR"
    WINE_BIN="$WINE_DIR/bin/wine"
    WINESERVER_BIN="$WINE_DIR/bin/wineserver"
    FREETYPE_DIR="$WINE_DIR/lib/freetype2-${FREETYPE_VERSION}"
fi
WINETRICKS_BIN="$LAUNCHER_DIR/winetricks"
LAUNCH_SCRIPT="$LAUNCHER_DIR/csp-launch.sh"
LAUNCHER_STUDIO="$LAUNCHER_DIR/clipstudio-launch.sh"
CSP_INSTALL_PATH="$WINEPREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5/CLIP STUDIO PAINT/CLIPStudioPaint.exe"
STUDIO_EXE="$WINEPREFIX/drive_c/Program Files/CELSYS/CLIP STUDIO 1.5/CLIP STUDIO/CLIPStudio.exe"
SYS32="$WINEPREFIX/drive_c/windows/system32"
LOG_FILE="${DOWNLOAD_DIR}/csp-install.log"

# helpers
run() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    local _rc
    if [[ $VERBOSE -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        _rc=${PIPESTATUS[0]}
    else
        "$@" >> "$LOG_FILE" 2>&1
        _rc=$?
    fi
    return "$_rc"
}

# copy the newest installed WebView2 runtime into the fixed portable dir
_freeze_webview2_fixed() {
    local _root _dir
    for _root in "$WEBVIEW2_FIXED_ROOT" "$WEBVIEW2_INSTALLED_ROOT"; do
        _dir=$(find "$_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' -print 2>/dev/null | sort -V | tail -n 1 || true)
        if [[ -n "$_dir" && -f "$_dir/msedgewebview2.exe" ]]; then
            WEBVIEW2_FIXED_DIR="$_dir"
            break
        fi
    done
    [[ -n "${WEBVIEW2_FIXED_DIR:-}" && -f "$WEBVIEW2_FIXED_DIR/msedgewebview2.exe" ]] || { WEBVIEW2_FIXED_DIR=""; return 1; }
    if [[ "$WEBVIEW2_FIXED_DIR" == "$WEBVIEW2_FIXED_ROOT"/* ]]; then
        return 0
    fi
    local _version="${WEBVIEW2_FIXED_DIR##*/}" _portable="$WEBVIEW2_FIXED_ROOT/$_version"
    if [[ ! -f "$_portable/msedgewebview2.exe" ]]; then
        mkdir -p "$WEBVIEW2_FIXED_ROOT"
        cp -a "$WEBVIEW2_FIXED_DIR" "$_portable"
    fi
    WEBVIEW2_FIXED_DIR="$_portable"
}

_webview2_env() {
    [[ -n "$WEBVIEW2_FIXED_DIR" ]] || return 0
    local _path
    _path=$(WINEPREFIX="$WINEPREFIX" winepath -w "$WEBVIEW2_FIXED_DIR" 2>/dev/null || true)
    [[ -n "$_path" ]] && export WEBVIEW2_BROWSER_EXECUTABLE_FOLDER="$_path"
}

GH_RAW="https://raw.githubusercontent.com/parka6060/CSPenguin-Installer/main"

fetch_asset() {
    local rel="$1" dest="$2"
    if [[ -f "$dest" && -s "$dest" ]]; then
        return 0
    fi
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$(dirname "$dest")"
    info "fetching $rel"
    local tmp="${dest}.part"
    wget -q -O "$tmp" "$GH_RAW/$rel" || { rm -f "$tmp"; die "failed to download $rel"; }
    mv "$tmp" "$dest"
}

# winetricks' cjkfonts pulls in a 112MB/28-face font (Source Han Sans >:C) that adds ~60s to every CSP startup. Swap it for something smaller to fix boot time. use --update to update your prefix.
install_cjk_font_fix() {
    local font_file="wqy-microhei.ttc"
    local font_name="WenQuanYi Micro Hei"

    if [[ $DRY_RUN -eq 1 ]]; then
        ok "CJK font: $font_name (dry run)"
        return
    fi

    local font_src="$SCRIPT_DIR/patches/fonts/$font_file"
    fetch_asset "patches/fonts/$font_file" "$font_src"
    if [[ ! -f "$font_src" ]]; then
        warn "CJK font asset missing, skipping"
        return
    fi

    local fonts_dir="$WINEPREFIX/drive_c/windows/Fonts"
    mkdir -p "$fonts_dir"
    cp "$font_src" "$fonts_dir/$font_file"
    rm -f "$fonts_dir/sourcehansans.ttc"

    local temp_dir="$WINEPREFIX/drive_c/windows/Temp"
    mkdir -p "$temp_dir"
    local reg_unix="$temp_dir/cjk-font.reg"
    cat > "$reg_unix" << REGEOF
REGEDIT4

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]
"Source Han Sans SC ExtraLight (TrueType)"=-
"Source Han Sans SC Light (TrueType)"=-
"Source Han Sans SC Normal (TrueType)"=-
"Source Han Sans SC (TrueType)"=-
"Source Han Sans SC Medium (TrueType)"=-
"Source Han Sans SC Bold (TrueType)"=-
"Source Han Sans SC Heavy (TrueType)"=-
"Source Han Sans TC ExtraLight (TrueType)"=-
"Source Han Sans TC Light (TrueType)"=-
"Source Han Sans TC Normal (TrueType)"=-
"Source Han Sans TC (TrueType)"=-
"Source Han Sans TC Medium (TrueType)"=-
"Source Han Sans TC Bold (TrueType)"=-
"Source Han Sans TC Heavy (TrueType)"=-
"Source Han Sans ExtraLight (TrueType)"=-
"Source Han Sans Light (TrueType)"=-
"Source Han Sans Normal (TrueType)"=-
"Source Han Sans (TrueType)"=-
"Source Han Sans Medium (TrueType)"=-
"Source Han Sans Bold (TrueType)"=-
"Source Han Sans Heavy (TrueType)"=-
"Source Han Sans K ExtraLight (TrueType)"=-
"Source Han Sans K Light (TrueType)"=-
"Source Han Sans K Normal (TrueType)"=-
"Source Han Sans K (TrueType)"=-
"Source Han Sans K Medium (TrueType)"=-
"Source Han Sans K Bold (TrueType)"=-
"Source Han Sans K Heavy (TrueType)"=-
"$font_name (TrueType)"="$font_file"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Fonts]
"Source Han Sans SC ExtraLight (TrueType)"=-
"Source Han Sans SC Light (TrueType)"=-
"Source Han Sans SC Normal (TrueType)"=-
"Source Han Sans SC (TrueType)"=-
"Source Han Sans SC Medium (TrueType)"=-
"Source Han Sans SC Bold (TrueType)"=-
"Source Han Sans SC Heavy (TrueType)"=-
"Source Han Sans TC ExtraLight (TrueType)"=-
"Source Han Sans TC Light (TrueType)"=-
"Source Han Sans TC Normal (TrueType)"=-
"Source Han Sans TC (TrueType)"=-
"Source Han Sans TC Medium (TrueType)"=-
"Source Han Sans TC Bold (TrueType)"=-
"Source Han Sans TC Heavy (TrueType)"=-
"Source Han Sans ExtraLight (TrueType)"=-
"Source Han Sans Light (TrueType)"=-
"Source Han Sans Normal (TrueType)"=-
"Source Han Sans (TrueType)"=-
"Source Han Sans Medium (TrueType)"=-
"Source Han Sans Bold (TrueType)"=-
"Source Han Sans Heavy (TrueType)"=-
"Source Han Sans K ExtraLight (TrueType)"=-
"Source Han Sans K Light (TrueType)"=-
"Source Han Sans K Normal (TrueType)"=-
"Source Han Sans K (TrueType)"=-
"Source Han Sans K Medium (TrueType)"=-
"Source Han Sans K Bold (TrueType)"=-
"Source Han Sans K Heavy (TrueType)"=-
"$font_name (TrueType)"="$font_file"

[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]
"Dengxian"="$font_name"
"FangSong"="$font_name"
"KaiTi"="$font_name"
"Microsoft YaHei"="$font_name"
"Microsoft YaHei UI"="$font_name"
"NSimSun"="$font_name"
"SimHei"="$font_name"
"SimKai"="$font_name"
"SimSun"="$font_name"
"SimSun-ExtB"="$font_name"
"DFKai-SB"="$font_name"
"Microsoft JhengHei"="$font_name"
"Microsoft JhengHei UI"="$font_name"
"MingLiU"="$font_name"
"PMingLiU"="$font_name"
"MingLiU-ExtB"="$font_name"
"PMingLiU-ExtB"="$font_name"
"Meiryo"="$font_name"
"Meiryo UI"="$font_name"
"MS Gothic"="$font_name"
"MS PGothic"="$font_name"
"MS Mincho"="$font_name"
"MS PMincho"="$font_name"
"MS UI Gothic"="$font_name"
"Yu Gothic"="$font_name"
"Yu Gothic UI"="$font_name"
"Yu Mincho"="$font_name"
"Batang"="$font_name"
"BatangChe"="$font_name"
"Dotum"="$font_name"
"DotumChe"="$font_name"
"Gulim"="$font_name"
"GulimChe"="$font_name"
"Gungsuh"="$font_name"
"GungsuhChe"="$font_name"
"Malgun Gothic"="$font_name"

[HKEY_CURRENT_USER\Software\Wine\X11 Driver]
"ClientSideAntiAliasWithCore"="Y"
"ClientSideAntiAliasWithRender"="Y"
"ClientSideWithRender"="Y"

[HKEY_CURRENT_USER\Software\Wine\Fonts]
"Cache"="600"
REGEOF

    run wine regedit /S 'C:\windows\Temp\cjk-font.reg'
    rm -f "$reg_unix"

    # Wine caches EnumFontFamiliesEx results; warming the cache here avoids
    # repeated expensive font scans when loading brush/material thumbnails.
    if command -v fc-cache &>/dev/null; then
        info "pre-generating font cache..."
        fc-cache -f "$fonts_dir" >> "$LOG_FILE" 2>&1 || true
    fi

    ok "CJK font: $font_name (was Source Han Sans, ~60s faster CSP startup)"
}

# ============================================================
# install Wine Gecko (the MSHTML/IE engine) into the prefix
# ============================================================
_install_gecko() {
    if [[ -d "$WINEPREFIX/drive_c/windows/system32/gecko/$GECKO_VERSION/wine_gecko" ]]; then
        ok "Wine Gecko ${GECKO_VERSION} (already installed)"
        return
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        ok "Wine Gecko ${GECKO_VERSION} (dry run)"
        return
    fi
    download_progress "Wine Gecko ${GECKO_VERSION}" "$GECKO_URL" "$GECKO_MSI"
    local _sum
    _sum=$(sha256sum "$GECKO_MSI" | cut -d' ' -f1)
    if [[ "$_sum" != "$GECKO_SHA" ]]; then
        die "Wine Gecko checksum mismatch (got $_sum)"
    fi
    wait_for "installing Wine Gecko ${GECKO_VERSION}" env WINEDEBUG=-all wine msiexec /i "$GECKO_MSI" /qn
    [[ -d "$WINEPREFIX/drive_c/windows/system32/gecko/$GECKO_VERSION/wine_gecko" ]] \
        || warn "Wine Gecko ${GECKO_VERSION} did not fully install"
}

wait_for() {
    local msg="$1"; shift
    if [[ $DRY_RUN -eq 1 ]]; then
        ok "$msg (dry run)"
        return
    fi
    info "$msg"
    run "$@" || die "$msg failed"
    ok "$msg"
}

download_progress() {
    local name="$1" url="$2" dest="$3"
    if [[ -f "$dest" && -s "$dest" ]]; then
        ok "$name (cached)"
        return
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        ok "$name (dry run)"
        return
    fi
    info "$name"
    local tmp="${dest}.part"
    wget --show-progress -q --timeout=30 --tries=3 -O "$tmp" "$url" || die "download failed: $name"
    mv "$tmp" "$dest"
    ok "$name"
}

_detect_pm() {
    command -v xbps-install >/dev/null 2>&1 && echo "xbps" && return
    command -v pacman >/dev/null 2>&1 && echo "pacman" && return
    command -v dnf    >/dev/null 2>&1 && echo "dnf"    && return
    command -v apt    >/dev/null 2>&1 && echo "apt"    && return
    echo "unknown"
}

# single install abstraction for the detected package manager
_pm_install() {
    case "$(_detect_pm)" in
        xbps)   _root xbps-install -S -y "$@" ;;
        pacman) _root pacman -S --needed --noconfirm "$@" ;;
        dnf)    _root dnf install -y "$@" ;;
        apt)    _root apt install -y "$@" ;;
        *)      die "unsupported distro, install \"$*\" manually" ;;
    esac
}

_gst_ok() { command -v gst-inspect-1.0 >/dev/null 2>&1 && gst-inspect-1.0 h264parse >/dev/null 2>&1; }

# single dependency installer: common tool probes + per-distro extras
_install_deps() {
    local _pm="$(_detect_pm)"
    local pkgs=()
    case "$_pm" in
        xbps)
            xbps-query -l void-repo-multilib 2>/dev/null | grep -q "^ii void-repo-multilib-" \
                || _root xbps-install -S -y void-repo-multilib
            pkgs+=(freetype freetype-32bit shared-mime-info desktop-file-utils) ;;
        dnf)   pkgs+=(freetype.i686) ;;
        apt)   pkgs+=(dirmngr ca-certificates) ;;
        pacman) ;;
        *) die "unsupported distro, install wget, curl, and gstreamer plugins manually" ;;
    esac
    command -v wget >/dev/null 2>&1 || pkgs+=(wget)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)
    command -v unzstd >/dev/null 2>&1 || pkgs+=(zstd)
    command -v cabextract >/dev/null 2>&1 || pkgs+=(cabextract)
    case "$_pm" in
        pacman)
            _gst_ok || pkgs+=(gst-plugins-bad gst-plugins-good) ;;
        dnf)
            _gst_ok || pkgs+=(gstreamer1-tools gstreamer1-plugins-bad-free gstreamer1-plugins-good) ;;
        apt)
            _gst_ok || pkgs+=(gstreamer1.0-plugins-bad gstreamer1.0-plugins-good) ;;
        xbps)
            _gst_ok || pkgs+=(gstreamer1 gst-plugins-base1 gst-plugins-good1 gst-plugins-bad1) ;;
    esac
    [[ ${#pkgs[@]} -gt 0 ]] && _pm_install "${pkgs[@]}"
}

# log file
if [[ $DRY_RUN -eq 1 ]]; then
    LOG_FILE="/dev/null"
else
    mkdir -p "$DOWNLOAD_DIR"
    : > "$LOG_FILE"
    echo "CSPenguin-Installer > $(date)" >> "$LOG_FILE"
fi

# catch anything set -e would otherwise abort on without a friendly message
trap '_on_error "$LINENO" "$BASH_COMMAND"' ERR

# detect Wine version of existing install is actually using
_detect_installed_wine() {
    [[ -f "$LAUNCH_SCRIPT" ]] || return 1
    local _v
    _v=$(grep -oP 'wine-\K[0-9]+\.[0-9]+' "$LAUNCH_SCRIPT" 2>/dev/null | head -1)
    [[ -n "$_v" ]] || return 1
    echo "$_v"
}

# fetch a patch file from local or remote (best effort, no fatal error)
_try_fetch_patch() {
    local _dir="$1" _rel="$2" _file="$3"
    [[ -f "$_dir/$_file" && -s "$_dir/$_file" ]] && return 0
    mkdir -p "$_dir"
    wget -q -O "$_dir/$_file" "$GH_RAW/$_rel/$_file" 2>/dev/null
}

# ============================================================
# extract Wine tarball to LAUNCHER_DIR
# ============================================================
_extract_wine() {
    local _wine_tar="$1"
    if [[ $DRY_RUN -eq 0 ]]; then
        local _sum
        _sum=$(sha256sum "$_wine_tar" | cut -d' ' -f1)
        [[ "$_sum" == "$WINE_SHA256" ]] || die "Wine checksum mismatch (got $_sum)"
    fi
    info "extracting Wine ${WINE_VERSION}..."
    rm -rf "$WINE_DIR"
    mkdir -p "$LAUNCHER_DIR"
    tar -xf "$_wine_tar" -C "$LAUNCHER_DIR"
    for _d in "$LAUNCHER_DIR/wine-${WINE_VERSION}-staging-amd64" \
               "$LAUNCHER_DIR/wine-${WINE_VERSION}-amd64" \
               "$LAUNCHER_DIR/wine-${WINE_VERSION}-plain-amd64"; do
        [[ -d "$_d" ]] && mv "$_d" "$WINE_DIR" && break
    done
    [[ -x "$WINE_BIN" ]] || die "Wine ${WINE_VERSION} extraction failed"
    ok "Wine ${WINE_VERSION} extracted"
}

# ============================================================
# bundle FreeType into WINE_DIR
# ============================================================
# map a missing freetype dependency (.so name) to the distro packages that
# provide it (native + 32-bit variant)
_freetype_dep_pkgs() {
    local lib="$1" pm="$2"
    case "$pm" in
        pacman)
            case "$lib" in
                libz.so*)        echo "zlib lib32-zlib" ;;
                libbz2.so*)      echo "bzip2 lib32-bzip2" ;;
                libpng16.so*)    echo "libpng lib32-libpng" ;;
                libharfbuzz.so*) echo "harfbuzz lib32-harfbuzz" ;;
                libbrotli*.so*)  echo "brotli lib32-brotli" ;;
            esac ;;
        dnf)
            case "$lib" in
                libz.so*)        echo "zlib zlib.i686" ;;
                libbz2.so*)      echo "bzip2-libs bzip2-libs.i686" ;;
                libpng16.so*)    echo "libpng libpng.i686" ;;
                libharfbuzz.so*) echo "harfbuzz harfbuzz.i686" ;;
                libbrotli*.so*)  echo "brotli brotli.i686" ;;
            esac ;;
        apt)
            case "$lib" in
                libz.so*)        echo "zlib1g zlib1g:i386" ;;
                libbz2.so*)      echo "libbz2-1.0 libbz2-1.0:i386" ;;
                libpng16.so*)    echo "libpng16-16 libpng16-16:i386" ;;
                libharfbuzz.so*) echo "libharfbuzz0b libharfbuzz0b:i386" ;;
                libbrotli*.so*)  echo "libbrotli1 libbrotli1:i386" ;;
            esac ;;
        xbps)
            case "$lib" in
                libz.so*)        echo "zlib zlib-32bit" ;;
                libbz2.so*)      echo "bzip2 bzip2-32bit" ;;
                libpng16.so*)    echo "libpng libpng-32bit" ;;
                libharfbuzz.so*) echo "harfbuzz harfbuzz-32bit" ;;
                libbrotli*.so*)  echo "brotli brotli-32bit" ;;
            esac ;;
    esac
}

# unique list of the shared libraries the bundled FreeType cannot resolve
_freetype_missing() {
    ldd "$FREETYPE_DIR/lib64/libfreetype.so.6" "$FREETYPE_DIR/lib32/libfreetype.so.6" 2>/dev/null \
        | grep "not found" \
        | sed 's/^[[:space:]]*\([^ ]*\) => not found.*/\1/' \
        | sort -u \
        || true
}

# ensure the bundled FreeType can resolve its dependencies, installing the
# missing 32-bit libraries when possible; dies with a fix hint if not
_freetype_resolve() {
    local _missing _pkgs=() _lib _pair _pm
    _missing=$(_freetype_missing)
    [[ -n "$_missing" ]] || return 0
    if [[ $DRY_RUN -eq 1 ]]; then
        info "FreeType needs extra libraries (dry run, not installing): $(tr '\n' ' ' <<< "$_missing")"
        return 0
    fi
    _pm="$(_detect_pm)"
    [[ "$_pm" != "unknown" ]] || die "bundled FreeType is missing dependencies: $(tr '\n' ' ' <<< "$_missing")
install the missing 32-bit libraries for your distribution, then re-run the installer"
    while IFS= read -r _lib; do
        read -r -a _pair <<< "$(_freetype_dep_pkgs "$_lib" "$_pm")"
        _pkgs+=("${_pair[@]}")
    done <<< "$_missing"
    if [[ ${#_pkgs[@]} -gt 0 ]]; then
        info "installing FreeType dependencies: ${_pkgs[*]}"
        if [[ "$_pm" == "apt" ]]; then
            _root dpkg --add-architecture i386 2>/dev/null || true
            _root apt update 2>/dev/null || true
        fi
        _pm_install "${_pkgs[@]}" || true
    fi
    _missing=$(_freetype_missing)
    [[ -z "$_missing" ]] || die "bundled FreeType is still missing dependencies: $(tr '\n' ' ' <<< "$_missing")
install the missing 32-bit libraries for your distribution, then re-run the installer"
}

_bundle_freetype() {
    local _freetype_tar="$DOWNLOAD_DIR/freetype2-${FREETYPE_VERSION}-1-x86_64.pkg.tar.zst"
    local _freetype32_tar="$DOWNLOAD_DIR/lib32-freetype2-${FREETYPE_VERSION}-1-x86_64.pkg.tar.zst"
    local _extract_dir
    if [[ $CPAK_MODE -eq 1 ]]; then
        ok "FreeType (cpak runtime)"
        return
    fi
    if [[ "$(_detect_pm)" == "xbps" ]]; then
        info "bundling FreeType from Void packages..."
        rm -rf "$FREETYPE_DIR"
        mkdir -p "$FREETYPE_DIR/lib64" "$FREETYPE_DIR/lib32"
        cp -a /usr/lib/libfreetype.so* "$FREETYPE_DIR/lib64/"
        cp -a /usr/lib32/libfreetype.so* "$FREETYPE_DIR/lib32/"
        _freetype_resolve
        ok "FreeType bundled"
        return
    fi
    if [[ ! -f "$_freetype_tar" ]]; then
        download_progress "FreeType ${FREETYPE_VERSION}" "$FREETYPE_URL" "$_freetype_tar"
    else
        ok "FreeType ${FREETYPE_VERSION} (cached)"
    fi
    if [[ ! -f "$_freetype32_tar" ]]; then
        download_progress "FreeType ${FREETYPE_VERSION} (32-bit)" "$FREETYPE32_URL" "$_freetype32_tar"
    else
        ok "FreeType ${FREETYPE_VERSION} 32-bit (cached)"
    fi
    info "bundling FreeType ${FREETYPE_VERSION} (32-bit + 64-bit)..."
    rm -rf "$FREETYPE_DIR"
    mkdir -p "$FREETYPE_DIR/lib64" "$FREETYPE_DIR/lib32"
    _extract_dir=$(mktemp -d "${TMPDIR:-/tmp}/csp-freetype.XXXXXX")
    (
        trap 'rm -rf -- "$_extract_dir"' EXIT
        unzstd -c "$_freetype_tar" | tar -xf - -C "$_extract_dir"
        cp "$_extract_dir"/usr/lib/libfreetype.so* "$FREETYPE_DIR/lib64/"
        rm -rf "$_extract_dir/usr/lib"
        unzstd -c "$_freetype32_tar" | tar -xf - -C "$_extract_dir"
        cp "$_extract_dir"/usr/lib32/libfreetype.so* "$FREETYPE_DIR/lib32/"
    )
    _freetype_resolve
    ok "FreeType ${FREETYPE_VERSION} bundled"
}

# ============================================================
# write both launcher scripts (PAINT + STUDIO)
# ============================================================
_write_launchers() {
    _freeze_webview2_fixed || true
    # In cpak mode FreeType comes from the image system libraries
    # (_bundle_freetype is a no-op there), so don't point launchers
    # at a bundle directory that was never created.
    local _ft_ld=""
    if [[ $CPAK_MODE -eq 0 ]]; then
        _ft_ld="$FREETYPE_DIR/lib64:$FREETYPE_DIR/lib32:"
    fi
    # environment shared by both launchers; \$ escapes survive into the generated scripts
    local _env
    _env=$(cat << LAUNCHENVEOF
ulimit -n 524288 2>/dev/null || true
export LD_LIBRARY_PATH="$_ft_ld\${LD_LIBRARY_PATH:-}"
export PATH="$WINE_DIR/bin:\$PATH"
export WINESERVER="$WINESERVER_BIN"
export WINEPREFIX="$WINEPREFIX"
export WINEDEBUG=-all
export WINEESYNC=1
export WINEFSYNC=1
export STAGING_SHARED_MEMORY=1
export STAGING_WRITECOPY=1
export WINE_NO_WRITE_CONSOLE=1
export WINEDLLPATH="$LAUNCHER_DIR:\${WINEDLLPATH:-}"
export DXVK_ASYNC=1
export DXVK_STATE_CACHE=1
export DXVK_CONFIG_FILE="$WINEPREFIX/dxvk.conf"
export DXVK_STATE_CACHE_PATH="$WINEPREFIX"
export mesa_glthread=true
export __GL_SHADER_DISK_CACHE=1
export __GL_SHADER_DISK_CACHE_PATH="$WINEPREFIX"
export RADV_PERFTEST=gpl
if [[ -n "\${CPAK_CONTAINER_ID:-}" ]]; then
    export LIBGL_ALWAYS_SOFTWARE="\${LIBGL_ALWAYS_SOFTWARE:-1}"
    export MESA_LOADER_DRIVER_OVERRIDE="\${MESA_LOADER_DRIVER_OVERRIDE:-llvmpipe}"
    export GALLIUM_DRIVER="\${GALLIUM_DRIVER:-llvmpipe}"
fi
export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu --disable-gpu-compositing --disable-gpu-vsync --in-process-gpu --disable-background-networking --no-first-run --disable-sync --disable-renderer-accessibility --disable-extensions --disable-component-extensions-with-background-pages --disk-cache-size=33554432 --disable-features=msEdgeSidebar"
WEBVIEW2_FIXED_DIR="$WEBVIEW2_FIXED_DIR"
if [[ -d "\$WEBVIEW2_FIXED_DIR" ]] && command -v winepath >/dev/null 2>&1; then
    export WEBVIEW2_BROWSER_EXECUTABLE_FOLDER="\$(WINEPREFIX="$WINEPREFIX" winepath --windows "\$WEBVIEW2_FIXED_DIR" 2>/dev/null || true)"
fi
LAUNCHENVEOF
)
    cat > "$LAUNCH_SCRIPT" << LAUNCHEOF
#!/usr/bin/env bash
$_env
CSP_EXE="$CSP_INSTALL_PATH"

if [[ -n "\$1" ]] && command -v winepath &>/dev/null; then
    WIN_PATH="\$(WINEPREFIX="$WINEPREFIX" winepath --windows "\$1")"
    wine "\$CSP_EXE" "\$WIN_PATH" &
else
    wine "\$CSP_EXE" &
fi
WINE_PID=\$!
wait "\$WINE_PID"
LAUNCHEOF
    chmod +x "$LAUNCH_SCRIPT"

    cat > "$LAUNCHER_STUDIO" << LAUNCHEOF
#!/usr/bin/env bash
$_env
exec wine "$STUDIO_EXE"
LAUNCHEOF
    chmod +x "$LAUNCHER_STUDIO"
}

# ponytail: systemd-only; non-systemd systems skip pre-warm instead of a second autostart backend
_write_prewarm_service() {
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/csp-wineserver.service" << EOF
[Unit]
Description=Wine server pre-warm for CSP
After=default.target

[Service]
Type=simple
Environment=PATH=$WINE_DIR/bin:/usr/bin
Environment=WINEPREFIX=$WINEPREFIX
Environment=WINESERVER=$WINESERVER_BIN
Environment=WINEDEBUG=-all
ExecStartPre=-$WINESERVER_BIN -k
ExecStart=$WINESERVER_BIN -f -p
Restart=always
RestartSec=5s

[Install]
WantedBy=default.target
EOF
}

_systemd_user_available() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1
}

_prewarm_enabled() {
    _systemd_user_available && systemctl --user is-enabled csp-wineserver.service >/dev/null 2>&1
}

_enable_prewarm() {
    _systemd_user_available || return 1
    _write_prewarm_service
    systemctl --user daemon-reload 2>/dev/null && systemctl --user enable --now csp-wineserver.service 2>/dev/null
}

_install_patches() {
    local _patches_win="$SCRIPT_DIR/patches/x86_64-windows-wine${WINE_VERSION}"
    local _patches_unix="$SCRIPT_DIR/patches/x86_64-unix-wine${WINE_VERSION}"

    if [[ ! -f "$_patches_win/mfplat.dll" ]] ||
       [[ ! -f "$_patches_win/mfreadwrite.dll" ]] ||
       [[ ! -f "$_patches_win/winegstreamer.dll" ]] ||
       [[ ! -f "$_patches_unix/winegstreamer.so" ]]; then
        # try to fetch the exact version from remote
        local _fallback="$DOWNLOAD_DIR/patches/x86_64-windows-wine${WINE_VERSION}"
        if _try_fetch_patch "$_fallback" "patches/x86_64-windows-wine${WINE_VERSION}" "mfplat.dll" &&
           _try_fetch_patch "$_fallback" "patches/x86_64-windows-wine${WINE_VERSION}" "mfreadwrite.dll" &&
           _try_fetch_patch "$_fallback" "patches/x86_64-windows-wine${WINE_VERSION}" "winegstreamer.dll"; then
            _patches_win="$_fallback"
            local _ufallback="$DOWNLOAD_DIR/patches/x86_64-unix-wine${WINE_VERSION}"
            _try_fetch_patch "$_ufallback" "patches/x86_64-unix-wine${WINE_VERSION}" "winegstreamer.so" || true
            _patches_unix="$_ufallback"
        fi
    fi

    local _ok=0
    if [[ -f "$_patches_win/mfplat.dll" ]] &&
       [[ -f "$_patches_win/mfreadwrite.dll" ]] &&
       [[ -f "$_patches_win/winegstreamer.dll" ]] &&
       [[ -f "$_patches_unix/winegstreamer.so" ]]; then
        mkdir -p "$SYS32"
        local _wine_win="$WINE_DIR/lib/wine/x86_64-windows"
        [[ -d "$_wine_win" ]] || _wine_win="$WINE_DIR/lib64/wine/x86_64-windows"
        local _wine_unix="$WINE_DIR/lib/wine/x86_64-unix"
        [[ -d "$_wine_unix" ]] || _wine_unix="$WINE_DIR/lib64/wine/x86_64-unix"

        if [[ -d "$_wine_win" ]]; then
            for dll in mfplat.dll mfreadwrite.dll winegstreamer.dll; do
                [[ -f "$_patches_win/$dll" ]] && cp "$_patches_win/$dll" "$_wine_win/$dll" && cp "$_patches_win/$dll" "$SYS32/$dll"
            done
            _ok=1
        fi
        if [[ -d "$_patches_unix" ]] && [[ -d "$_wine_unix" ]]; then
            [[ -f "$_patches_unix/winegstreamer.so" ]] && cp "$_patches_unix/winegstreamer.so" "$_wine_unix/winegstreamer.so"
        fi
    fi

    if [[ $_ok -eq 1 ]]; then
        if ! run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "mfplat" /t REG_SZ /d "native,builtin" /f ||
           ! run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "mfreadwrite" /t REG_SZ /d "native,builtin" /f; then
            # wine reg add can potentially fail during a Wine version upgrade (prefix migration,
            # new wineserver not ready).  Fall back to writing a .reg file directly.
            local _reg_tmp="$WINEPREFIX/drive_c/windows/Temp/mf-overrides.reg"
            cat > "$_reg_tmp" << 'REGEOF'
REGEDIT4

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"mfplat"="native,builtin"
"mfreadwrite"="native,builtin"
REGEOF
            run wine regedit /S 'C:\windows\Temp\mf-overrides.reg' || warn "failed to set mfplat/mfreadwrite overrides"
            rm -f "$_reg_tmp"
        fi
        ok "patches applied: video export"
    else
        warn "exact patches not available for Wine ${WINE_VERSION}; video export may not work"
    fi
}

# existing install found and no mode flag given -- ask what to do
if [[ $UPDATE_ONLY -eq 0 ]] && [[ $UPDATE_WINE -eq 0 ]] && [[ -f "$LAUNCH_SCRIPT" ]]; then
    _found_wine=$(_detect_installed_wine || echo "unknown")
    echo ""
    echo "  existing CSPenguin install found (Wine $_found_wine, $LAUNCHER_DIR)"
    echo ""
    echo "    1) update       - regenerate launch scripts/config only; keeps your CSP install and Wine version as-is (fast)"
    echo "    2) update wine  - install or repair the supported bundled Wine runtime"
    echo "    3) reinstall    - run the full installer again"
    echo "    4) cancel"
    echo ""
    _choice=""
    read -t 10 -rp "  choice [will automatically cancel in 10s]: " _choice </dev/tty || true
    echo ""
    _log "menu (existing install found): choice='${_choice:-<empty/timeout>}'"
    case "${_choice:-4}" in
        1) UPDATE_ONLY=1; info "selected: update" ;;
        2) UPDATE_WINE=1; info "selected: update wine" ;;
        3) ok "proceeding with fresh install" ;;
        *) info "cancelled"; exit 0 ;;
    esac
fi

# --update/--update-wine given but no existing install found
if [[ $UPDATE_ONLY -eq 1 || $UPDATE_WINE -eq 1 ]] && [[ ! -f "$LAUNCH_SCRIPT" ]]; then
    _flag_name="--update"
    [[ $UPDATE_WINE -eq 1 ]] && _flag_name="--update-wine"
    echo ""
    echo "  no existing CSPenguin install found ($LAUNCHER_DIR)"
    echo "  $_flag_name needs an existing install to update."
    echo ""
    echo "    1) install now - run a full fresh install instead"
    echo "    2) cancel"
    echo ""
    _choice=""
    read -t 10 -rp "  choice [will automatically cancel in 10s]: " _choice </dev/tty || true
    echo ""
    _log "menu (no existing install, $_flag_name given): choice='${_choice:-<empty/timeout>}'"
    case "${_choice:-2}" in
        1) UPDATE_ONLY=0; UPDATE_WINE=0; ok "proceeding with fresh install" ;;
        *) info "cancelled"; exit 0 ;;
    esac
fi

# ============================================================
# --update-wine / -w : install the supported Wine runtime without reinstalling CSP
# ============================================================
if [[ $UPDATE_WINE -eq 1 ]]; then
    if [[ $CPAK_MODE -eq 1 ]]; then
        die "Wine is baked into the cpak image; rebuild the image to change Wine versions"
    fi
    echo ""
    echo "  [*] Wine update mode"
    echo ""

    # detect currently installed Wine version
    _current_wine=$(_detect_installed_wine) \
        || die "could not detect installed Wine version from $LAUNCH_SCRIPT"
    info "currently installed:     Wine $_current_wine"
    info "this installer supports: Wine $WINE_VERSION"

    if [[ "$_current_wine" == "$WINE_VERSION" ]]; then
        echo ""
        echo "  already at supported Wine $WINE_VERSION -- nothing to update"
        echo ""
        echo "    1) update    - regenerate launch scripts/config anyway"
        echo "    2) reinstall - run the full installer again"
        echo "    3) cancel"
        echo ""
        _choice=""
        read -t 10 -rp "  choice [will automatically cancel in 10s]: " _choice </dev/tty || true
        echo ""
        _log "menu (already at supported Wine $WINE_VERSION): choice='${_choice:-<empty/timeout>}'"
        case "${_choice:-3}" in
            1) UPDATE_WINE=0; UPDATE_ONLY=1; info "selected: update" ;;
            2) UPDATE_WINE=0; UPDATE_ONLY=0; ok "proceeding with fresh install" ;;
            *) info "cancelled"; exit 0 ;;
        esac
    else
        if [[ "$_current_wine" != "$WINE_VERSION" && "$(printf '%s\n%s\n' "$WINE_VERSION" "$_current_wine" | sort -V | tail -1)" == "$_current_wine" ]]; then
            echo ""
            echo "  current wine version: $_current_wine is newer than the recommended wine version: $WINE_VERSION"
            echo "  continuing will downgrade to $WINE_VERSION to ensure compatibility."
            echo ""
            _confirm=""
            read -t 10 -rp "  continue with downgrade? [y/N, cancels in 10s]: " _confirm </dev/tty || true
            _log "downgrade confirmation ($_current_wine -> $WINE_VERSION): answer='${_confirm:-<empty/timeout>}'"
            [[ "$_confirm" =~ ^[Yy]$ ]] || { info "cancelled"; exit 0; }
            ok "downgrading Wine $_current_wine -> $WINE_VERSION"
        else
            ok "upgrading Wine $_current_wine -> $WINE_VERSION"
        fi

        # download the supported Wine build
        _wine_url="https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/wine-${WINE_VERSION}-amd64.tar.xz"
        _wine_tar="$DOWNLOAD_DIR/wine-${WINE_VERSION}-amd64.tar.xz"
        mkdir -p "$DOWNLOAD_DIR"
        download_progress "Wine ${WINE_VERSION}" "$_wine_url" "$_wine_tar"

        _extract_wine "$_wine_tar"
        _bundle_freetype

        # Keep an existing opt-in pre-warm service pointed at the new runtime.
        if _prewarm_enabled; then
            _write_prewarm_service
            systemctl --user daemon-reload 2>/dev/null || warn "could not reload wineserver service"
            systemctl --user restart csp-wineserver.service 2>/dev/null \
                || warn "could not restart wineserver service"
        fi

        # clean up old Wine version
        _old_wine_dir="$LAUNCHER_DIR/wine-${_current_wine}"
        if [[ -d "$_old_wine_dir" ]] && [[ "$_old_wine_dir" != "$WINE_DIR" ]]; then
            rm -rf "$_old_wine_dir"
            info "removed old Wine ${_current_wine}"
        fi

        export PATH="$WINE_DIR/bin:$PATH"
        export WINEPREFIX WINEARCH WINESERVER="$WINESERVER_BIN"

        # dcomp (login/store panels) – always needed
        DCOMP_DLL="$SCRIPT_DIR/patches/dcomp/dcomp.dll"
        PTHREAD_DLL="$SCRIPT_DIR/patches/dcomp/libwinpthread-1.dll"
        fetch_asset "patches/dcomp/dcomp.dll"          "$DCOMP_DLL"
        fetch_asset "patches/dcomp/libwinpthread-1.dll" "$PTHREAD_DLL"
        [[ -f "$DCOMP_DLL" ]] || die "dcomp.dll not found"
        cp "$DCOMP_DLL"    "$LAUNCHER_DIR/dcomp.dll"
        mkdir -p "$SYS32"
        cp "$DCOMP_DLL"    "$SYS32/dcomp.dll"
        cp "$PTHREAD_DLL"  "$SYS32/libwinpthread-1.dll"
        run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dcomp" /t REG_SZ /d "native,builtin" /f || true
        ok "dcomp.dll (login/store panels)"

        _install_patches

        _write_launchers
        info "launcher scripts regenerated"

        # refresh desktop database
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

        # kill old wineserver, start new one
        "$WINESERVER_BIN" -k 2>/dev/null || true

        ok "update to Wine ${WINE_VERSION} complete!"
        exit 0
    fi
fi

# --update: skip install steps, just regenerate launch scripts + config
if [[ $UPDATE_ONLY -eq 1 ]]; then
    # WINE_VERSION above is the pin, not necessarily what's on disk -- if it
    # doesn't exist, fall back to whatever Wine version is actually installed.
    if [[ ! -d "$WINE_DIR" ]]; then
        _installed_wine=$(_detect_installed_wine || true)
        if [[ -n "$_installed_wine" ]] && [[ -d "$LAUNCHER_DIR/wine-${_installed_wine}" ]]; then
            WINE_VERSION="$_installed_wine"
            WINE_DIR="$LAUNCHER_DIR/wine-${WINE_VERSION}"
            WINE_BIN="$WINE_DIR/bin/wine"
            WINESERVER_BIN="$WINE_DIR/bin/wineserver"
            FREETYPE_DIR="$WINE_DIR/lib/freetype2-${FREETYPE_VERSION}"
        fi
    fi

    export PATH="$WINE_DIR/bin:$PATH"
    export WINEPREFIX WINEARCH WINESERVER="$WINESERVER_BIN"

    if [[ ! -d "$WINE_DIR" ]]; then
        die "Wine not found at $WINE_DIR — run a full install first"
    fi
    if [[ ! -f "$CSP_INSTALL_PATH" ]]; then
        die "CSP not found at $CSP_INSTALL_PATH — run a full install first"
    fi

    echo ""
    echo "  CSPenguin update mode"
    echo "  regenerating launch scripts, config, and service"
    echo ""

    # registry tweaks
    step "configuration"
    run wine reg add "HKCU\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f || true
    run wine reg add "HKLM\\System\\CurrentControlSet\\Services\\PlugPlay" /v Start /t REG_DWORD /d 4 /f || true
    run wine reg add "HKLM\\System\\CurrentControlSet\\Services\\WineBus" /v Start /t REG_DWORD /d 4 /f || true
    cat > "$WINEPREFIX/dxvk.conf" << 'DXVKEOF'
dxgi.deferSurfaceCreation = True
dxvk.enableGraphicsPipelineLibrary = True
dxvk.numCompilerThreads = 0
dxvk.maxChunkSize = 16
DXVKEOF
    ok "registry + dxvk.conf"
    install_cjk_font_fix
    _bundle_freetype
    _install_gecko

    # fall through to step 6 and step 7, heh 6 7 >:D
fi

if [[ $UPDATE_ONLY -eq 0 ]]; then

# banner + version select

echo ""
echo ""
echo "          .--."
echo "         |o_o |  CSPenguin-Installer!"
echo "         |:_/ |  Never stop drawing."
echo '        //   \ \'
if [[ $CPAK_MODE -eq 1 ]]; then
    echo "       (|     | )  running inside the cpak environment"
    echo "      /'\_   _/\`\\  without changing host packages"
    echo "      \___)=(___/  or host system limits."
else
    echo "       (|     | )  this script will ask for your password"
    echo "      /'\_   _/\`\\  once or twice to install packages"
    echo "      \___)=(___/  and set system limits."
fi
echo ""
echo ""
echo "  Which version of Clip Studio Paint?"
echo "    1) 5.1.2 (latest)"
echo "    2) 5.0.4 (perpetual)"
echo "    3) 4.1.0"
echo "    4) 4.0.10 (perpetual)"
echo "    5) 3.2.3"
echo "    6) 3.0.8 (perpetual)"
echo "    7) 2.3.4"
echo "    8) 2.0.6 (perpetual)"
echo "    9) 1.13.2"
echo "    10) custom installer path or URL"
echo ""

CSP_VERSION="" CSP_URL="" CSP_EXE_NAME=""
while true; do
    if [[ $CPAK_MODE -eq 1 ]]; then
        choice="${CSPENGUIN_CSP_VERSION:-1}"
    else
        read -rp "  choice [1]: " choice </dev/tty
    fi
    choice="${choice:-1}"
    case "$choice" in
        1) CSP_VERSION="512"; break ;;
        2) CSP_VERSION="504"; break ;;
        3) CSP_VERSION="410"; break ;;
        4) CSP_VERSION="4010"; break ;;
        5) CSP_VERSION="323"; break ;;
        6) CSP_VERSION="308"; break ;;
        7) CSP_VERSION="234"; break ;;
        8) CSP_VERSION="206"; break ;;
        9) CSP_VERSION="1132"; break ;;
        10)
            read -rp "  path or URL: " custom </dev/tty
            if [[ "$custom" == http* ]]; then
                CSP_URL="$custom"
                CSP_EXE_NAME="$(basename "$custom")"
                CSP_VERSION="custom"
            elif [[ -f "$custom" ]]; then
                CSP_EXE_NAME="$(basename "$custom")"
                if [[ $DRY_RUN -eq 0 ]]; then
                    mkdir -p "$DOWNLOAD_DIR"
                    cp "$(realpath "$custom")" "$DOWNLOAD_DIR/$CSP_EXE_NAME"
                fi
                CSP_URL=""
                CSP_VERSION="custom"
            else
                echo "  file not found: $custom"; continue
            fi
            break ;;
        *) echo "  pick 1-10" ;;
    esac
done

if [[ "$CSP_VERSION" != "custom" ]]; then
    CSP_URL="https://vd.clipstudio.net/clipcontent/paint/app/${CSP_VERSION}/CSP_${CSP_VERSION}w_setup.exe"
    CSP_EXE_NAME="CSP_${CSP_VERSION}w_setup.exe"
fi
# [1/7] dependencies

step "dependencies"
info "checking for required system packages..."

if [[ $CPAK_MODE -eq 1 ]]; then
    ok "dependencies (cpak runtime)"
else
    _missing=()
    command -v wget >/dev/null 2>&1 || _missing+=(wget)
    command -v curl >/dev/null 2>&1 || _missing+=(curl)
    command -v unzstd >/dev/null 2>&1 || _missing+=(zstd)
    command -v cabextract >/dev/null 2>&1 || _missing+=(cabextract)
    _gst_ok || _missing+=("gstreamer plugins")
    if [[ "$(_detect_pm)" == "xbps" ]]; then
        [[ -e /lib/ld-musl-$(uname -m).so.1 ]] && die "Void musl is not supported by the bundled Wine runtime"
        xbps-query -l void-repo-multilib 2>/dev/null | grep -q "^ii void-repo-multilib-" || _missing+=(void-repo-multilib)
        xbps-query -l freetype 2>/dev/null | grep -q "^ii freetype-" || _missing+=(freetype)
        xbps-query -l freetype-32bit 2>/dev/null | grep -q "^ii freetype-32bit-" || _missing+=(freetype-32bit)
    fi

    if [[ ${#_missing[@]} -gt 0 ]]; then
        warn "missing: ${_missing[*]}"
        _pm="$(_detect_pm)"
        if [[ "$_pm" == "unknown" ]]; then
            die "unsupported distro, install wget, curl, and gstreamer plugins manually"
        fi
                read -rp "  install automatically? [Y/n]: " _ans </dev/tty
        if [[ "${_ans:-y}" =~ ^[Yy]$ ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                ok "dependencies (dry run)"
            else
                _install_deps
            fi
        else
            die "install dependencies manually, then re-run"
        fi
    fi
fi

ok "dependencies"

# [2/7] downloads

step "downloads"
info "grabbing Wine, WebView2, and the CSP installer."
if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$DOWNLOAD_DIR" "$LAUNCHER_DIR"
fi

_wine_tar="$DOWNLOAD_DIR/wine-${WINE_VERSION}-amd64.tar.xz"
_need_wine=0
[[ ! -x "$WINE_BIN" ]] && _need_wine=1

if [[ -n "${CSP_URL:-}" ]]; then
    download_progress "Clip Studio Paint" "$CSP_URL" "$DOWNLOAD_DIR/$CSP_EXE_NAME"
else
    ok "Clip Studio Paint (local file)"
fi

_dl_pids=()
_dl_names=()
_dl_dests=()
_dl_tmps=()

_queue_dl() {
    local name="$1" url="$2" dest="$3"
    if [[ -f "$dest" && -s "$dest" ]]; then
        ok "$name (cached)"
        return
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        ok "$name (dry run)"
        return
    fi
    local tmp="${dest}.part"
    wget -q --timeout=30 --tries=3 -O "$tmp" "$url" &
    _dl_pids+=($!)
    _dl_names+=("$name")
    _dl_dests+=("$dest")
    _dl_tmps+=("$tmp")
}

if [[ $_need_wine -eq 1 ]]; then
    _queue_dl "Wine ${WINE_VERSION}" "$WINE_URL" "$_wine_tar"
elif [[ "$WINE_DIR" == "$BAKED_WINE_DIR" ]]; then
    ok "Wine ${WINE_VERSION} (baked into image)"
else
    ok "Wine ${WINE_VERSION} (cached)"
fi
if [[ $CPAK_MODE -eq 1 ]]; then
    WEBVIEW2_INSTALLER="$WEBVIEW2_MANAGED"
    [[ $DRY_RUN -eq 1 || -f "$WEBVIEW2_INSTALLER" ]] || die "WebView2 runtime source is missing"
else
    WEBVIEW2_INSTALLER="$WEBVIEW2_FILE"
    _queue_dl "WebView2 Runtime" "$WEBVIEW2_URL" "$WEBVIEW2_INSTALLER"
fi
_queue_dl "winetricks" "$WINETRICKS_URL" "$WINETRICKS_BIN"

if [[ ${#_dl_pids[@]} -gt 0 ]]; then
    for _j in "${!_dl_pids[@]}"; do
        wait "${_dl_pids[$_j]}" || die "download failed: ${_dl_names[$_j]}"
        mv "${_dl_tmps[$_j]}" "${_dl_dests[$_j]}"
        ok "${_dl_names[$_j]}"
    done
fi

if [[ $CPAK_MODE -eq 0 && $DRY_RUN -eq 0 ]]; then
    _sum=$(sha256sum "$WEBVIEW2_INSTALLER" | cut -d' ' -f1)
    [[ "$_sum" == "$WEBVIEW2_SHA256" ]] || die "WebView2 checksum mismatch (got $_sum)"
fi

if [[ $_need_wine -eq 1 ]] && [[ $DRY_RUN -eq 0 ]]; then
    _extract_wine "$_wine_tar"
    _bundle_freetype
fi

if [[ $DRY_RUN -eq 0 ]]; then
    chmod +x "$WINETRICKS_BIN"
    export PATH="$WINE_DIR/bin:$PATH"
fi

# For debugging when using a VM, avoids error during testing
if [[ -z "${LIBGL_ALWAYS_SOFTWARE:-}" ]] \
    && command -v systemd-detect-virt >/dev/null 2>&1 \
    && [[ "$(systemd-detect-virt 2>/dev/null)" != "none" ]]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
    ok "Mesa software rendering (VM without working DRI3)"
fi

if [[ $CPAK_MODE -eq 1 ]]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
    export GALLIUM_DRIVER=llvmpipe
    export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu --disable-gpu-compositing --disable-gpu-vsync --in-process-gpu --disable-background-networking --no-first-run --disable-sync --disable-renderer-accessibility --disable-extensions --disable-component-extensions-with-background-pages --disk-cache-size=33554432 --disable-features=msEdgeSidebar"
    ok "software rendering for cpak display"
fi

# [3/7] wine prefix

step "wine prefix"
info "setting up a fresh Wine environment for CSP."
if [[ ! -x "$WINE_BIN" ]]; then
    die "Wine binary not found at $WINE_BIN"
fi
if [[ $DRY_RUN -eq 0 ]]; then
    if ! "$WINE_BIN" --version >> "$LOG_FILE" 2>&1; then
        die "Wine runtime at $WINE_DIR failed to start (see $LOG_FILE)"
    fi
    ok "Wine runtime smoke test ($(basename "$WINE_DIR"))"
fi
if [[ $DRY_RUN -eq 0 ]]; then
    export WINEPREFIX WINEARCH WINESERVER="$WINESERVER_BIN"
    # A prefix booted against a half-dead wineserver fails with
    # "could not load kernel32.dll, status c0000135", so ask any
    # stale server to stop and wait until it is really gone.
    "$WINESERVER_BIN" -k 2>/dev/null || true
    wineserver -k 2>/dev/null || true
    timeout 15 "$WINESERVER_BIN" -w 2>/dev/null || true
fi
# wineboot flops intermittently inside constrained sandboxes with
# "could not load kernel32.dll, status c0000135" (~50%); a retry
# usually boots fine, so don't die on the first attempt.
# (Subshell: wait_for's die() aborts the attempt, not the installer.
# Never rm the prefix here: on reinstalls it holds the user's CSP.)
_prefix_done=0
for _attempt in 1 2 3; do
    if [[ $_attempt -gt 1 ]]; then
        warn "prefix init failed, retrying ($_attempt/3)..."
        "$WINESERVER_BIN" -k 2>/dev/null || true
        timeout 15 "$WINESERVER_BIN" -w 2>/dev/null || true
    fi
    ( wait_for "initialising prefix" env "WINEDEBUG=$WINEBOOT_DEBUG" wineboot --init ) \
        && { _prefix_done=1; break; }
done
[[ $_prefix_done -eq 1 ]] || die "initialising prefix failed"

if [[ $CPAK_MODE -eq 1 ]]; then
    ok "esync file limits (cpak runtime)"
elif [[ $DRY_RUN -eq 1 ]]; then
    ok "esync file limits (dry run)"
else
    _nofile=$(ulimit -n 2>/dev/null || echo 0)
    if [[ "$_nofile" -ge 524288 ]]; then
        ok "esync file limits ($_nofile)"
    else
        _esync_set=0
        if _systemd_user_available; then
            mkdir -p "$HOME/.config/systemd/user.conf.d"
            cat > "$HOME/.config/systemd/user.conf.d/cspenguin-limits.conf" << 'EOF'
[Manager]
DefaultLimitNOFILE=524288
EOF
            ok "esync (systemd user config)"
            _esync_set=1
        fi
        _current_user="$(whoami)"
        if _root mkdir -p /etc/security/limits.d && _root tee /etc/security/limits.d/cspenguin.conf > /dev/null << EOF
$_current_user soft nofile 524288
$_current_user hard nofile 524288
EOF
        then
            [[ $_esync_set -eq 0 ]] && ok "esync (limits.d)"
            _esync_set=1
        fi
        if [[ $_esync_set -eq 0 ]]; then
            warn "could not set file limit"
        else
            _ESYNC_RESTART=1
        fi
    fi
fi

# [4/7] runtime + patches

step "runtime + patches"
info "installing fonts, libraries, and fixes."

if [[ $SKIP_WINETRICKS -eq 1 ]]; then
    ok "winetricks (skipped)"
else
    _wt_log="$WINEPREFIX/winetricks.log"
    _wt_needed=()
    for pkg in corefonts vcrun2022 dotnet48 dxvk vkd3d; do
        grep -qx "$pkg" "$_wt_log" 2>/dev/null || _wt_needed+=("$pkg")
    done
    if [[ ${#_wt_needed[@]} -eq 0 ]]; then
        ok "winetricks packages (already installed)"
    else
        [[ " ${_wt_needed[*]} " == *" dotnet48 "* ]] && warn "this can take 10-30 min, go pet a cat!"
        wait_for "${_wt_needed[*]}" env WINEDEBUG=-all "$WINETRICKS_BIN" -q "${_wt_needed[@]}"
    fi
fi

_install_gecko

# compatibility settings (must be after winetricks, dotnet48 resets the version)
if [[ $DRY_RUN -eq 0 ]]; then
    run wine reg add "HKCU\\Software\\Wine" /v Version /t REG_SZ /d "win10" /f || warn "failed to set windows version"
    run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "concrt140" /t REG_SZ /d "native,builtin" /f || warn "failed to set concrt140 override"
    run wine reg add "HKCU\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f || warn "failed to suppress crash dialog"

    # Disable unnecessary Wine services that slow down startup
    run wine reg add "HKLM\\System\\CurrentControlSet\\Services\\PlugPlay" /v Start /t REG_DWORD /d 4 /f || true
    run wine reg add "HKLM\\System\\CurrentControlSet\\Services\\WineBus" /v Start /t REG_DWORD /d 4 /f || true

    cat > "$WINEPREFIX/dxvk.conf" << 'EOF'
dxgi.deferSurfaceCreation = True
dxvk.enableGraphicsPipelineLibrary = True
dxvk.numCompilerThreads = 0
dxvk.maxChunkSize = 16
EOF
fi
ok "windows version: win10"
ok "dll overrides + dxvk.conf"

if [[ $DRY_RUN -eq 1 ]]; then
    ok "dcomp.dll (login/store panels)"
    ok "mfplat + winegstreamer (video export)"
    ok "CJK font: WenQuanYi Micro Hei (dry run)"
else
    mkdir -p "$LAUNCHER_DIR"

    DCOMP_DLL="$SCRIPT_DIR/patches/dcomp/dcomp.dll"
    PTHREAD_DLL="$SCRIPT_DIR/patches/dcomp/libwinpthread-1.dll"
    fetch_asset "patches/dcomp/dcomp.dll"          "$DCOMP_DLL"
    fetch_asset "patches/dcomp/libwinpthread-1.dll" "$PTHREAD_DLL"
    [[ -f "$DCOMP_DLL" ]] || die "dcomp.dll not found"

    cp "$DCOMP_DLL"    "$LAUNCHER_DIR/dcomp.dll"
    cp "$DCOMP_DLL"    "$SYS32/dcomp.dll"
    cp "$PTHREAD_DLL"  "$SYS32/libwinpthread-1.dll"
    run wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dcomp" /t REG_SZ /d "native,builtin" /f || warn "failed to set dcomp override"
    ok "dcomp.dll (login/store panels)"

    _install_patches
    install_cjk_font_fix
fi

# [5/7] install CSP

step "install CSP"

if [[ $DRY_RUN -eq 1 ]]; then
    ok "WebView2 Runtime (dry run)"
    ok "Clip Studio Paint (dry run)"
else
    _freeze_webview2_fixed || true
    if [[ -n "$WEBVIEW2_FIXED_DIR" ]]; then
        _webview2_env
        ok "WebView2 Runtime (fixed)"
    else
        info "installing WebView2 (for login/store panels)."
        timeout --foreground --kill-after=15s 120s \
            env WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d" \
            wine "$WEBVIEW2_INSTALLER" /silent /install >> "$LOG_FILE" 2>&1 || true
        env WINEDEBUG=-all wineserver -k 2>/dev/null || true
        _freeze_webview2_fixed || true
        if [[ -n "$WEBVIEW2_FIXED_DIR" ]]; then
            _webview2_env
            ok "WebView2 Runtime (fixed)"
        else
            warn "WebView2 runtime was not detected"
        fi
    fi
    sleep 1

    gap
    msg "press enter to launch the CSP installer."
    msg "complete the installer as normal."
    gap
        read -rp "press enter to continue..." </dev/tty
    info "CSP installer running, come back when done..."
    run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\$CSP_EXE_NAME" /v Version /t REG_SZ /d "win81" /f || warn "failed to set installer compatibility"
    env WINEDEBUG=-all \
        WINEDLLOVERRIDES="winemenubuilder.exe=d;d3d11=b;dxgi=b;d3d10core=b;dcomp=b" \
        WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="$WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS" \
        wine "$DOWNLOAD_DIR/$CSP_EXE_NAME" >> "$LOG_FILE" 2>&1 &
    wait $! || die "CSP installer failed"
    [[ -f "$CSP_INSTALL_PATH" ]] || die "CSP not found after install, did you complete the installer?"

    find "$HOME/.local/share/applications" -name "*CLIP STUDIO PAINT*.desktop" -delete 2>/dev/null || true
    find "$HOME/Desktop" -name "*CLIP STUDIO PAINT*.desktop" -delete 2>/dev/null || true
    ok "Removed installer-generated launchers"

    ok "Clip Studio Paint"

    run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\msedgewebview2.exe" /v Version /t REG_SZ /d "win7" /f || warn "failed to set webview2 version"
    run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\CLIPStudioPaint.exe" /v Version /t REG_SZ /d "win81" /f || warn "failed to set CSP version"
    run wine reg add "HKCU\\Software\\Wine\\AppDefaults\\CLIPStudio.exe" /v Version /t REG_SZ /d "win81" /f || warn "failed to set CLIP STUDIO version"
fi

fi # end UPDATE_ONLY skip

# [6/7] desktop integration

step "desktop integration"
if [[ $CPAK_MODE -eq 1 ]]; then
    ok "desktop integration (cpak manifest)"
else
    info "creating app shortcuts and file previews."

if [[ $DRY_RUN -eq 1 ]]; then
    ok "launch scripts (dry run)"
    ok "desktop entries (dry run)"
    ok ".clip thumbnails + MIME type (dry run)"
else

# --- APP ICONS ---
# We pull the icons from the Wikimedea Commons and avoid shipping them in the repo to comply with trademark laws.
# This way if an icon is missing for some reason we still have a backup icon to use.
ICON_THEME_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
ICON_PAINT="$ICON_THEME_DIR/clipstudiopaint.png"
ICON_STUDIO="$ICON_THEME_DIR/clipstudio.png"
ICON_URL="https://upload.wikimedia.org/wikipedia/commons/1/14/Clipstudiopaint_app_logo.png"
mkdir -p "$ICON_THEME_DIR"

# ponytail: plain download, no file(1) PNG validation; a corrupt icon is cosmetic
_fetch_icon() {
    local dest="$1"
    if [[ -s "$dest" ]]; then
        ok "icon: $(basename "$dest") (cached)"
        return
    fi
    local tmp="${dest}.part"
    if wget -q --timeout=30 --tries=3 -O "$tmp" "$ICON_URL"; then
        mv "$tmp" "$dest"
        ok "icon: $(basename "$dest")"
    else
        rm -f "$tmp" 2>/dev/null || true
        warn "icon download failed: $(basename "$dest")"
    fi
}

_fetch_icon "$ICON_PAINT"
_fetch_icon "$ICON_STUDIO"

_write_launchers
ok "launch scripts"

DESKTOP_FILE="$HOME/.local/share/applications/clipstudiopaint.desktop"
DESKTOP_STUDIO="$HOME/.local/share/applications/clipstudio.desktop"
mkdir -p "$HOME/.local/share/applications"

cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=Clip Studio Paint
Exec=$LAUNCH_SCRIPT %f
Terminal=false
Type=Application
Categories=Graphics;
MimeType=application/x-clip;
StartupWMClass=clipstudiopaint.exe
Icon=$ICON_PAINT
EOF

cat > "$DESKTOP_STUDIO" << EOF
[Desktop Entry]
Name=CLIP STUDIO
Exec=$LAUNCHER_STUDIO
Terminal=false
Type=Application
Categories=Graphics;
StartupWMClass=clipstudio.exe
Icon=$ICON_STUDIO
EOF

chmod +x "$DESKTOP_FILE" "$DESKTOP_STUDIO"
ok "desktop entries"

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

THUMBNAILER_SRC="$SCRIPT_DIR/patches/thumbnailer/clip-thumbnailer"
THUMBNAILER_BIN="$HOME/.local/bin/clip-thumbnailer"
fetch_asset "patches/thumbnailer/clip-thumbnailer" "$THUMBNAILER_SRC"

mkdir -p "$HOME/.local/bin"
if [[ -x "$THUMBNAILER_BIN" ]]; then
    ok ".clip thumbnails (already installed)"
else
    install -Dm755 "$THUMBNAILER_SRC" "$THUMBNAILER_BIN"

    _MIME_DIR="$HOME/.local/share/mime"
    mkdir -p "$_MIME_DIR/packages"
    if [[ ! -f "$_MIME_DIR/packages/clip.xml" ]]; then
        cat > "$_MIME_DIR/packages/clip.xml" << 'MIMEEOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-clip">
    <comment>Clip Studio Paint file</comment>
    <glob pattern="*.clip"/>
  </mime-type>
</mime-info>
MIMEEOF
        update-mime-database "$_MIME_DIR" 2>/dev/null || true
    fi

    _THUMB_DIR="$HOME/.local/share/thumbnailers"
    mkdir -p "$_THUMB_DIR"
    if [[ ! -f "$_THUMB_DIR/clip.thumbnailer" ]]; then
        cat > "$_THUMB_DIR/clip.thumbnailer" << THUMBEOF
[Thumbnailer Entry]
TryExec=$THUMBNAILER_BIN
Exec=$THUMBNAILER_BIN %i %o
MimeType=application/x-clip;
THUMBEOF
    fi
    ok ".clip thumbnails + MIME type"
fi

fi

fi

# [7/7] finishing up

step "finishing up"

if pgrep -fi huion >/dev/null 2>&1; then
    warn "Huion proprietary driver detected"
    info "this can block pen pressure in CSP under Wine"
    info "try uninstalling the Huion driver if pressure"
    info "doesn't work, your kernel likely supports it"
    gap
fi

info "pre-warming the wineserver at login"
info "reduces startup time by ~5-10s."
gap
if [[ $CPAK_MODE -eq 1 ]]; then
    _prewarm="n"
    ok "wineserver managed by cpak"
elif ! _systemd_user_available; then
    _prewarm="n"
    ok "wineserver pre-warm skipped (no systemd user session)"
elif [[ $UPDATE_ONLY -eq 1 ]] && _prewarm_enabled; then
    _prewarm="y"
    info "updating existing wineserver service"
else
    read -rp "enable wineserver pre-warm? [Y/n] " _prewarm </dev/tty
fi
if [[ "${_prewarm,,}" != "n" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        ok "wineserver service (dry run)"
    elif _enable_prewarm; then
        ok "wineserver service enabled"
    else
        warn "could not enable wineserver pre-warm"
    fi
else
    ok "wineserver pre-warm skipped"
fi

_install_ok=1

_divider=$(printf '━%.0s' $(seq 1 46))
echo ""
echo "  ${_divider}"
echo ""
echo "  + all done!"
echo ""
echo "  find Clip Studio Paint in your"
echo "  app menu, or launch via terminal:"
echo "  $LAUNCH_SCRIPT"
echo ""
if [[ $_ESYNC_RESTART -eq 1 ]]; then
echo "  note"
echo "    log out and back in for esync to take effect"
echo ""
fi
echo "  tips"
echo "    pen pressure  Preferences > Tablet > mouse mode"
echo "    hidpi         winecfg > Graphics > DPI"
echo "    thumbnails    enable in file manager preview settings"
echo "                   (Dolphin: Configure Dolphin > Interface > Previews"
echo "                    > tick \"Clip Studio Paint File\", then restart Dolphin)"
echo ""
echo "  something not working? open an issue at"
  echo "  https://github.com/SrDicov/CSPenguin-Installer-cpak"
echo ""
echo "  installer by https://eninabox.art"
echo ""
echo "  ${_divider}"
echo ""
