SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:

SNAPCRAFT := snap/snapcraft.yaml
BASE := https://dist.torproject.org
KEYSERVERS := hkps://keys.openpgp.org hkps://keyserver.ubuntu.com

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make latest                       Print the latest stable Tor version on $(BASE)"
	@echo "  make verify                       Download the pinned release, verify signature + hash"
	@echo "  make bump VERSION=x               Verify release x and rewrite version + EXPECTED_SHA256"
	@echo "  make bump VERSION=x TRUST_NEW=1   Same, but also trust any new signer key"
	@echo "  make build                        Build the snap (snapcraft)"

# Download, verify (signature + hash) and extract a Tor release into DEST.
# Pure: all inputs are passed in. This is the single implementation used by both
# the snap build (snap/snapcraft.yaml override-pull) and `make verify`.
.PHONY: fetch-source
fetch-source:
	@test -n "$(VERSION)"        || { echo "ERROR: VERSION required"; exit 1; }
	test -n "$(EXPECTED_SHA256)" || { echo "ERROR: EXPECTED_SHA256 required"; exit 1; }
	test -n "$(KEYS)"            || { echo "ERROR: KEYS required"; exit 1; }
	test -n "$(DEST)"            || { echo "ERROR: DEST required"; exit 1; }
	WORK="$$(mktemp -d)"; trap 'rm -rf "$$WORK"' EXIT
	export GNUPGHOME="$$WORK"
	TARBALL="tor-$(VERSION).tar.gz"

	recvd=0
	for ks in $(KEYSERVERS); do
	  if gpg --batch --keyserver "$$ks" --recv-keys $(KEYS); then recvd=1; break; fi
	done
	[ "$$recvd" = 1 ] || { echo "ERROR: could not fetch signing keys"; exit 1; }

	curl -sSfL -o "$$WORK/$$TARBALL"      "$(BASE)/$$TARBALL"
	curl -sSfL -o "$$WORK/sha256sum"     "$(BASE)/$$TARBALL.sha256sum"
	curl -sSfL -o "$$WORK/sha256sum.asc" "$(BASE)/$$TARBALL.sha256sum.asc"

	gpg --batch --verify "$$WORK/sha256sum.asc" "$$WORK/sha256sum"

	SIGNED="$$(awk -v f="$$TARBALL" '$$2==f {print $$1}' "$$WORK/sha256sum")"
	if [ "$$SIGNED" != "$(EXPECTED_SHA256)" ]; then
	  echo "ERROR: Tor-signed hash ($$SIGNED) != pinned EXPECTED_SHA256 ($(EXPECTED_SHA256))"; exit 1
	fi
	echo "$(EXPECTED_SHA256)  $$WORK/$$TARBALL" | sha256sum -c -

	mkdir -p "$(DEST)"
	tar -xzf "$$WORK/$$TARBALL" --strip-components=1 -C "$(DEST)"
	echo "OK: tor-$(VERSION) verified and extracted to $(DEST)"

.PHONY: verify
verify:
	@VERSION="$$(grep -oE '^version:.*' $(SNAPCRAFT) | grep -oE '[0-9]+(\.[0-9]+)+')"
	EXPECTED="$$(grep -oE 'EXPECTED_SHA256=[0-9a-f]+' $(SNAPCRAFT) | cut -d= -f2)"
	KEYS="$$(grep -oE 'KEYS="[0-9A-F ]+"' $(SNAPCRAFT) | sed -E 's/KEYS="([^"]+)"/\1/')"
	D="$$(mktemp -d)"; trap 'rm -rf "$$D"' EXIT
	$(MAKE) --no-print-directory fetch-source \
	  VERSION="$$VERSION" EXPECTED_SHA256="$$EXPECTED" KEYS="$$KEYS" DEST="$$D"

.PHONY: bump
bump:
	@test -n "$(VERSION)" || { echo "Usage: make bump VERSION=x.y.z.w [TRUST_NEW=1]"; exit 1; }
	WORK="$$(mktemp -d)"; trap 'rm -rf "$$WORK"' EXIT
	export GNUPGHOME="$$WORK"
	TARBALL="tor-$(VERSION).tar.gz"

	echo ">> Fetching checksum + signature for $$TARBALL"
	curl -sSfL -o "$$WORK/sha256sum"     "$(BASE)/$$TARBALL.sha256sum"
	curl -sSfL -o "$$WORK/sha256sum.asc" "$(BASE)/$$TARBALL.sha256sum.asc"

	SIGNERS="$$(gpg --verify "$$WORK/sha256sum.asc" "$$WORK/sha256sum" 2>&1 \
	  | sed -n 's/.*using [A-Z0-9]* key //p' || true)"
	test -n "$$SIGNERS" || { echo "ERROR: could not read signer fingerprints"; exit 1; }

	for fp in $$SIGNERS; do
	  for ks in $(KEYSERVERS); do
	    gpg --batch --keyserver "$$ks" --recv-keys "$$fp" && break
	  done
	done
	gpg --batch --verify "$$WORK/sha256sum.asc" "$$WORK/sha256sum"

	echo ">> Signed by:"
	for fp in $$SIGNERS; do
	  printf '   %s  %s\n' "$$fp" "$$(gpg --list-keys --with-colons "$$fp" | awk -F: '/^uid:/{print $$10; exit}')"
	done

	PINNED="$$(grep -oE 'KEYS="[0-9A-F ]+"' $(SNAPCRAFT) | sed -E 's/KEYS="([^"]+)"/\1/')"
	NEW=""
	for fp in $$SIGNERS; do
	  case " $$PINNED " in *" $$fp "*) ;; *) NEW="$$NEW $$fp" ;; esac
	done
	if [ -n "$$NEW" ] && [ -z "$(TRUST_NEW)" ]; then
	  echo
	  echo "ERROR: release signed by key(s) not currently trusted:$$NEW"
	  echo "Confirm the identity above is a genuine Tor developer, then re-run with TRUST_NEW=1."
	  exit 1
	fi

	HASH="$$(awk -v f="$$TARBALL" '$$2==f {print $$1}' "$$WORK/sha256sum")"
	test -n "$$HASH" || { echo "ERROR: hash for $$TARBALL not found in checksum file"; exit 1; }

	sed -i -E "s/^version:.*/version: '$(VERSION)'/" $(SNAPCRAFT)
	sed -i -E "s/(EXPECTED_SHA256=)[0-9a-f]+/\1$$HASH/" $(SNAPCRAFT)
	if [ -n "$$NEW" ]; then
	  UNION="$$(echo $$PINNED $$SIGNERS | tr ' ' '\n' | sort -u | paste -sd' ')"
	  sed -i -E "s/(KEYS=\")[0-9A-F ]+\"/\1$$UNION\"/" $(SNAPCRAFT)
	  echo ">> Added new signer key(s) to KEYS:$$NEW"
	fi
	echo ">> Updated $(SNAPCRAFT): version $(VERSION), sha256 $$HASH"

.PHONY: latest
latest:
	@curl -sSfL "$(BASE)/" \
	  | grep -oE 'tor-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
	  | sed -E 's/^tor-(.+)\.tar\.gz$$/\1/' \
	  | sort -V | tail -1

.PHONY: build
build:
	@snapcraft
