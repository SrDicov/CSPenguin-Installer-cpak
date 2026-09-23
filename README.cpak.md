# CSPenguin cpak package

The included GitHub Actions workflow builds and publishes the `linux/amd64` OCI image, then pins its digest in `cpak.json`.

```sh
docker buildx build --platform linux/amd64 --tag ghcr.io/srdicov/cspenguin-installer-cpak:main --push .
cpak validate cpak.json
cpak dev cpak.json --binary /usr/local/bin/cspenguin-cpak
```

Wine 11.4 (Kron4ek, SHA-256 verified) is baked into the image at `/opt/cspenguin/wine-11.4`, so first-launch reuses it instead of downloading a runtime to the user home. An explicit `$CSPENGUIN_WINE` / `$CSPENGUIN_WINE_DIR` still overrides it, and a `--update-wine` inside cpak mode is refused (rebuild the image to change Wine).

## Install

Install cpak and the package with:

```sh
chmod +x install-cpak.sh
./install-cpak.sh
```

If cpak is already installed, use:

```sh
cpak install github.com/srdicov/cspenguin-installer-cpak
```

To download the standalone installer for Linux amd64:

```sh
curl -fL -o CSPenguin-amd64.cpak-installer "https://cpak.it/install/github.com/SrDicov/CSPenguin-Installer-cpak?arch=amd64"
chmod +x CSPenguin-amd64.cpak-installer
./CSPenguin-amd64.cpak-installer
```

The `.cpak-installer` endpoint becomes available after the package is reviewed by the cpak Store.
