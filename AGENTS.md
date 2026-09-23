# AGENTS.md

Small repo: CSPenguin (Clip Studio Paint on Linux via Wine) packaged as cpak. No app source, no test/lint/typecheck suite. Work is shell scripts + `Containerfile` + cpak manifest.

## Layout

- `install.sh` (~1950 lines) — host installer: deps → downloads → Wine prefix → runtime/patches → CSP install → desktop integration. Source of truth for versions and prefix layout.
- `cpak-launcher.sh` — first-launch/runtime launcher, installed as **two binaries from one file** distinguished by `basename $0` (`cspenguin-cpak` = Paint, `cspenguin-studio-cpak` = CLIP STUDIO). Never split into two files; `Containerfile` copies it twice.
- `Containerfile` — image build (`ghcr.io/containerpak/wine` pinned digest + apt list, `COPY`s of scripts/desktops, `chmod 0755`).
- `cpak.json` — package manifest (binaries, desktop entries, permissions, WebView2 `runtime_sources`). `cpak.lock.json` is generated.
- `install-cpak.sh` — end-user bootstrap (installs cpak v2.13.3, then `cpak install`). `cspenguin{,-studio}.desktop` — desktop entries. `README.cpak.md` — maintainer notes; `STORE-README.md` — store listing copy.

## Commands

No tests or linters configured. Verify with:

```sh
bash -n install.sh && bash -n cpak-launcher.sh && bash -n install-cpak.sh
cpak validate cpak.json
```

`install.sh` flags: `--verbose/-v`, `--skip-winetricks/-s`, `--dry-run/-n` (safe syntax/path check), `--update-wine/-w`, `--update/-u` (regen launchers/config only).
Flow detail: `bash install.sh --dry-run` then `bash install.sh --verbose` for real runs.

## Gotchas

- `install.sh` is interactive with 10s `/dev/tty` timeouts: existing-install menu auto-cancels, missing-install menu auto-installs. Non-interactive agents should pass an explicit flag (`--update`, `--update-wine`) or expect the default. In cpak mode (`CPAK_CONTAINER_ID` set or `CSPENGUIN_CPAK=1`) the CSP version prompt defaults to choice 1 unless `CSPENGUIN_CSP_VERSION` is set.
- Keep version pins in sync across files: Wine `11.4` + SHA-256 (`install.sh` `WINE_SHA256`, `cpak-launcher.sh`, `Containerfile` `ARG WINE_SHA256` — all `b98761339edb5cf9a3f622fa08de2d4b453ab96e2b5d8a612aa3687ea6ec523f`), WebView2 URL + `sha256` (`cpak.json` `runtime_sources` and `install.sh` `WEBVIEW2_*`), FreeType `2.13.2`, Gecko `2.47.4`. Wine is **baked into the image** at `/opt/cspenguin/wine-11.4` (see `Containerfile`); `cpak-launcher.sh` search order: `$CSPENGUIN_WINE` → baked `/opt/cspenguin/wine-*/bin/wine` → `~/.local/share/cspenguin/wine-*/bin/wine` → cpak data dir → `PATH` → download Kron4ek build with checksum (fallback only). In cpak mode `install.sh` prefers the baked runtime and `--update-wine` is refused (rebuild the image instead).
- Key paths (overridable): `WINEPREFIX` default `~/.wine-csp`; launchers `~/.local/share/cspenguin/` (`csp-launch.sh`, `clipstudio-launch.sh`); cpak data `${XDG_DATA_HOME:-~/.local/share}/cspenguin-cpak`; download cache `${XDG_CACHE_HOME:-~/.cache}/csp-install`.
- Do NOT hand-edit the `image:` digest in `cpak.json` or `cpak.lock.json`. CI (`.github/workflows/publish-cpak.yml`, trigger: push to `main` touching `Containerfile`, scripts, desktops, or workflow) rebuilds `linux/amd64`, pins the digest via `jq`, runs `cpak validate` + `cpak lock --origin github.com/srdicov/cspenguin-installer-cpak`, and commits `chore: pin cpak image digest`.
- `opencode-x86_64.AppImage` in root is untracked local tooling, not part of the package. Ignore it.
