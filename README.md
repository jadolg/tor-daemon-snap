This repository contains configuration to package the tor binary as a snap and run it as a daemon.

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/tor-daemon)

To configure the service, edit the default configuration at `/var/snap/tor-daemon/current/usr/local/etc/tor/torrc`

This is not an "official" package distribution nor is it associated with the Tor project.

## Source verification

The Tor tarball is not bundled. At build time the `tor` part downloads it from
`dist.torproject.org` and, before using it, verifies its integrity and authenticity:

1. The PGP signature on Tor's published `sha256sum` file is checked against the
   pinned release-signing keys (`KEYS` in `snap/snapcraft.yaml`).
2. That signed hash must equal the pinned `EXPECTED_SHA256`.
3. The downloaded tarball must match `EXPECTED_SHA256`.

This gives a full chain: Tor developers' signatures → pinned hash → tarball bytes.
Snapcraft has no built-in PGP verification for source downloads, so this is done at
build time.

The verification logic lives in a single place — the `fetch-source` target in the
`Makefile`. The snap build invokes it from the part's `override-pull` (which is why
`make` is a build dependency), and `make verify` runs the exact same target locally.
The pinned data (`version`, `EXPECTED_SHA256`, `KEYS`) lives only in
`snap/snapcraft.yaml`.

## Building

```sh
make build      # runs snapcraft
make verify     # download the pinned release and verify its signature + hash
```

## Updating to a new Tor release

Check the latest stable release upstream:

```sh
make latest
```

The version lives once in the top-level `version:` field and the hash once in
`EXPECTED_SHA256`. Both are updated for you:

```sh
make bump VERSION=$(make latest)
```

This downloads the new release's signed checksum, verifies the signature against the
pinned keys, and rewrites `version:` and `EXPECTED_SHA256` in `snap/snapcraft.yaml`.

If the release was signed by a key that is not already trusted, `make bump` stops and
prints the signer's fingerprint and identity. Confirm it belongs to a genuine Tor
developer (cross-check the Tor project's signing keys), then re-run to trust it:

```sh
make bump VERSION=0.4.9.10 TRUST_NEW=1
```

The new key is added to `KEYS`. This trust decision is intentionally manual — it must
not be automated, or a tarball signed by an attacker's key would be trusted blindly.
