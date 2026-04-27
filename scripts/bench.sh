#!/usr/bin/env bash
# Apples-to-apples benchmark: produce the same set of three modpacks under
# two different OCI layouts and measure publisher storage + consumer pull
# bandwidth and wall time. Writes a markdown table to $BENCH_OUT (defaults
# to stdout).
#
# Layouts under test:
#   "plain zip"   : each pack ships as one zip containing merged base + overlay
#                   content, pushed as a single-layer OCI artifact. Mirrors
#                   today's GENERIC_PACK distribution shape.
#   "oci layered" : a shared base layer + a per-pack overlay layer, exactly
#                   the layout the main publish workflow produces.
#
# Both layouts are pushed to the same registry over the same network, so the
# only variable is whether layers are deduplicated. Synthetic content is
# generated from /dev/urandom so it is essentially incompressible, which
# means gzip/zip overhead won't distort the layer-reuse signal.
#
# Required env:
#   REGISTRY        e.g. ghcr.io/chipwolf/oci-modpack-demo
#
# Optional env:
#   TAG             defaults to `bench`
#   BASE_BYTES      synthetic shared-base size, default 5 MiB
#   OVERLAY_BYTES   synthetic per-pack overlay size, default 1 MiB
#   PACKS           space-separated pack names, default "tech magic adventure"
#   BENCH_OUT       output file for the markdown table; default stdout
set -euo pipefail

REGISTRY="${REGISTRY:?set REGISTRY (e.g. ghcr.io/chipwolf/oci-modpack-demo)}"
TAG="${TAG:-bench}"
BASE_BYTES="${BASE_BYTES:-5242880}"
OVERLAY_BYTES="${OVERLAY_BYTES:-1048576}"
PACKS="${PACKS:-tech magic adventure}"
BENCH_OUT="${BENCH_OUT:-/dev/stdout}"

# shellcheck disable=SC2086
set -- $PACKS
PACK_COUNT=$#
SECOND_PACK=${2:-$1}

OCI_ARTIFACT_TYPE="application/vnd.itzg.minecraft.modpack.v1+json"
OCI_LAYER_TYPE="application/vnd.itzg.minecraft.modpack.layer.v1.tar+gzip"
ZIP_ARTIFACT_TYPE="application/vnd.itzg.minecraft.modpack-zip.v1+json"
ZIP_LAYER_TYPE="application/zip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/base/mods" "$WORK/out"

echo ">> generating synthetic content (base=${BASE_BYTES}B, overlay=${OVERLAY_BYTES}B per pack)" >&2
head -c "$BASE_BYTES" /dev/urandom > "$WORK/src/base/mods/big.bin"
for p in $PACKS; do
  mkdir -p "$WORK/src/$p/mods"
  head -c "$OVERLAY_BYTES" /dev/urandom > "$WORK/src/$p/mods/$p.bin"
done

echo ">> building plain merged zips" >&2
for p in $PACKS; do
  staging="$WORK/stage-zip-$p"
  mkdir -p "$staging"
  cp -r "$WORK/src/base/." "$staging/"
  cp -r "$WORK/src/$p/." "$staging/"
  # -X strips extra file attributes that vary across runs.
  (cd "$staging" && zip -qr -X "$WORK/out/$p.zip" .)
done

echo ">> building OCI tar.gz layers (deterministic)" >&2
mklayer() {
  tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 \
      --numeric-owner --format=ustar -cf - -C "$1" . | gzip -n > "$2"
}
mklayer "$WORK/src/base" "$WORK/out/base.tar.gz"
for p in $PACKS; do
  mklayer "$WORK/src/$p" "$WORK/out/$p.tar.gz"
done

echo ">> pushing plain-zip artifacts" >&2
for p in $PACKS; do
  ( cd "$WORK/out" && oras push --no-tty \
      --artifact-type "$ZIP_ARTIFACT_TYPE" \
      --annotation "org.opencontainers.image.title=bench-zip-$p" \
      "$REGISTRY/bench-zip-$p:$TAG" \
      "$p.zip:$ZIP_LAYER_TYPE" )
done

echo ">> pushing OCI-layered artifacts" >&2
for p in $PACKS; do
  ( cd "$WORK/out" && oras push --no-tty \
      --artifact-type "$OCI_ARTIFACT_TYPE" \
      --annotation "org.opencontainers.image.title=bench-oci-$p" \
      "$REGISTRY/bench-oci-$p:$TAG" \
      "base.tar.gz:$OCI_LAYER_TYPE" \
      "$p.tar.gz:$OCI_LAYER_TYPE" )
done

# --- measure ---------------------------------------------------------------

# Publisher storage: for plain zip every pack is a unique blob, no dedup.
# For OCI layered: base counted once, overlays once each.
zip_storage=0
for p in $PACKS; do
  zip_storage=$((zip_storage + $(stat -c%s "$WORK/out/$p.zip")))
done

oci_storage=$(stat -c%s "$WORK/out/base.tar.gz")
for p in $PACKS; do
  oci_storage=$((oci_storage + $(stat -c%s "$WORK/out/$p.tar.gz")))
done

# Cold-cache wall time pulling all packs back. Each scheme pulls into a fresh
# directory so neither benefits from filesystem residue. For OCI we pull all
# refs into a single output dir, so when oras sees that base.tar.gz already
# exists from the first pull, it skips the redownload of that blob (this is
# the layer-reuse property the demo is about).
rm -rf "$WORK/pull-zip" "$WORK/pull-oci"
mkdir -p "$WORK/pull-zip" "$WORK/pull-oci"

zip_start=$(date +%s.%N)
for p in $PACKS; do
  oras pull --no-tty "$REGISTRY/bench-zip-$p:$TAG" -o "$WORK/pull-zip/$p" >/dev/null
done
zip_end=$(date +%s.%N)
zip_seconds=$(awk -v a="$zip_end" -v b="$zip_start" 'BEGIN{printf "%.3f", a-b}')

oci_start=$(date +%s.%N)
for p in $PACKS; do
  oras pull --no-tty "$REGISTRY/bench-oci-$p:$TAG" -o "$WORK/pull-oci" >/dev/null
done
oci_end=$(date +%s.%N)
oci_seconds=$(awk -v a="$oci_end" -v b="$oci_start" 'BEGIN{printf "%.3f", a-b}')

# Wire bytes for a content-addressed consumer modeled after how docker /
# oras pull treat blob existence: zips are unique per pack so wire == storage;
# OCI's base layer comes down exactly once, overlays once each.
zip_wire=$zip_storage
oci_wire=$oci_storage

# Incremental cost of adding a new pack on top of an existing install: the
# second pack's bytes for zip, vs. just its overlay layer for OCI (the base
# is already on disk).
zip_extra=$(stat -c%s "$WORK/out/$SECOND_PACK.zip")
oci_extra=$(stat -c%s "$WORK/out/$SECOND_PACK.tar.gz")

human() { numfmt --to=iec --suffix=B --format='%.2f' "$1"; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b==0) print "n/a"; else printf "%.2fx", a/b }'; }

{
  echo
  echo "Synthetic content per pack: base \`$(human "$BASE_BYTES")\`, overlay \`$(human "$OVERLAY_BYTES")\`. ${PACK_COUNT} packs total."
  echo
  echo "| metric                                          | plain zip                  | OCI layered                | reduction |"
  echo "| ----------------------------------------------- | -------------------------- | -------------------------- | --------- |"
  echo "| publisher storage (${PACK_COUNT} packs in registry)         | $(human "$zip_storage")    | $(human "$oci_storage")    | $(ratio "$zip_storage" "$oci_storage")     |"
  echo "| consumer wire bytes, pull all ${PACK_COUNT} cold            | $(human "$zip_wire")       | $(human "$oci_wire")       | $(ratio "$zip_wire" "$oci_wire")     |"
  echo "| consumer pull wall time, all ${PACK_COUNT} cold             | ${zip_seconds}s            | ${oci_seconds}s            | $(ratio "$zip_seconds" "$oci_seconds")     |"
  echo "| incremental cost of adding a pack on a host     | $(human "$zip_extra")      | $(human "$oci_extra")      | $(ratio "$zip_extra" "$oci_extra")     |"
  echo
} > "$BENCH_OUT"

echo ">> done; results written to ${BENCH_OUT}" >&2
