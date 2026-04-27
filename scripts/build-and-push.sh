#!/usr/bin/env bash
# Build the demo modpacks as OCI artifacts and (optionally) push them to a
# registry. Requires `oras` and a POSIX `tar` that supports the
# `--sort`/`--mtime`/`--owner`/`--group` reproducibility flags (GNU tar).
#
# Usage:
#   REGISTRY=ghcr.io/owner/oci-modpack-demo TAG=v0.1.0 ./scripts/build-and-push.sh
#   PUSH=false ./scripts/build-and-push.sh   # dry-run; build artifacts only
#
# Environment:
#   REGISTRY  Registry+namespace prefix. Each pack is pushed as
#             $REGISTRY/<pack>:<tag>. Required when PUSH=true.
#   TAG       Image tag. Defaults to `latest`.
#   PUSH      `true` (default) to push, `false` to skip the network call.
#   OUT_DIR   Where to write intermediate tarballs. Defaults to ./out.
set -euo pipefail

REGISTRY="${REGISTRY:-}"
TAG="${TAG:-latest}"
PUSH="${PUSH:-true}"
OUT_DIR="${OUT_DIR:-out}"
ARTIFACT_TYPE="application/vnd.itzg.minecraft.modpack.v1+json"
LAYER_TYPE="application/vnd.itzg.minecraft.modpack.layer.v1.tar+gzip"

PACKS=(tech magic adventure)

if [[ "${PUSH}" == "true" && -z "${REGISTRY}" ]]; then
  echo "REGISTRY must be set when PUSH=true (e.g. REGISTRY=ghcr.io/me/oci-modpack-demo)" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
mkdir -p "${OUT_DIR}"

# Deterministic tar.gz: stable file order, fixed mtime/owner/group, no gzip
# timestamp. This is what guarantees the *base* layer has an identical
# sha256 digest across every pack we build, which is the whole point of
# the demo.
make_layer() {
  local src="$1"
  local dst="$2"
  tar \
    --sort=name \
    --mtime='UTC 2020-01-01' \
    --owner=0 --group=0 --numeric-owner \
    --format=ustar \
    -cf - -C "${src}" . \
  | gzip -n > "${dst}"
}

echo ">> building shared base layer"
make_layer packs/base "${OUT_DIR}/base.tar.gz"

# Show the digest so a reader can confirm reuse across the three pushes.
BASE_DIGEST="$(sha256sum "${OUT_DIR}/base.tar.gz" | awk '{print $1}')"
echo "   base.tar.gz sha256:${BASE_DIGEST}"

for pack in "${PACKS[@]}"; do
  echo ">> building overlay layer for ${pack}"
  make_layer "packs/${pack}" "${OUT_DIR}/${pack}.tar.gz"
  digest="$(sha256sum "${OUT_DIR}/${pack}.tar.gz" | awk '{print $1}')"
  echo "   ${pack}.tar.gz sha256:${digest}"
done

if [[ "${PUSH}" != "true" ]]; then
  echo ">> PUSH=false, skipping registry upload"
  exit 0
fi

for pack in "${PACKS[@]}"; do
  ref="${REGISTRY}/${pack}:${TAG}"
  echo ">> pushing ${ref}"
  # Layer order matters: the base goes first so that consumers apply it
  # first and the pack overlay wins on conflicts. ORAS preserves the order
  # in the manifest's `.layers` array.
  oras push "${ref}" \
    --artifact-type "${ARTIFACT_TYPE}" \
    --annotation "org.opencontainers.image.title=${pack}" \
    --annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-OWNER/oci-modpack-demo}" \
    --annotation "org.opencontainers.image.description=Demo Minecraft modpack (${pack}) shipped as an OCI artifact" \
    "${OUT_DIR}/base.tar.gz:${LAYER_TYPE}" \
    "${OUT_DIR}/${pack}.tar.gz:${LAYER_TYPE}"
done

echo
echo ">> done. Manifests (note the identical first-layer digest across packs):"
for pack in "${PACKS[@]}"; do
  ref="${REGISTRY}/${pack}:${TAG}"
  echo "--- ${ref} ---"
  oras manifest fetch "${ref}" | jq '{artifactType, layers: [.layers[] | {mediaType, digest, size}]}'
done
