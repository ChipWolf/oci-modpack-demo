#!/usr/bin/env bash
# Reference flow for *consuming* an OCI modpack artifact, written in the
# shape that itzg/docker-minecraft-server's existing GENERIC_PACKS handler
# would slot into. The intent of this script is to be readable, not to be
# the final implementation.
#
# Inputs:
#   GENERIC_PACKS_OCI   Comma- or newline-separated OCI references, e.g.
#                         ghcr.io/owner/oci-modpack-demo/tech:latest
#                         ghcr.io/owner/oci-modpack-demo/magic:v0.1.0
#   DATA_DIR            Where to apply pack contents (defaults to /data).
#
# What it does:
#   1. For each ref, `oras pull` into a per-ref staging dir. ORAS writes
#      each layer as a separate file using the digest as the filename.
#   2. Sorts the resulting tarballs by their position in the manifest's
#      `.layers` array (so base layer applies first, overlay second).
#   3. Hands each tarball off to the existing GENERIC_PACK extraction path.
#      In docker-minecraft-server today that's just "untar into /data with
#      env-var interpolation", which already exists for GENERIC_PACK*.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
STAGE="${STAGE:-/tmp/oci-modpacks}"
mkdir -p "${DATA_DIR}" "${STAGE}"

REFS=()
if [[ -n "${GENERIC_PACKS_OCI:-}" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//,/$'\n'}"
    while IFS= read -r r; do
      r="$(echo "$r" | tr -d '[:space:]')"
      [[ -n "$r" ]] && REFS+=("$r")
    done <<< "$line"
  done <<< "${GENERIC_PACKS_OCI}"
fi

if [[ ${#REFS[@]} -eq 0 ]]; then
  echo "no GENERIC_PACKS_OCI refs supplied; nothing to do"
  exit 0
fi

apply_layer() {
  local tarball="$1"
  echo ">>   applying $(basename "${tarball}")"
  # NOTE: in docker-minecraft-server this should call the same code path
  # that GENERIC_PACK uses, so SYNC_SKIP_NEWER_IN_DESTINATION,
  # REPLACE_ENV_DURING_SYNC, etc. continue to apply uniformly.
  tar -xzf "${tarball}" -C "${DATA_DIR}"
}

for ref in "${REFS[@]}"; do
  echo ">> pulling ${ref}"
  dest="${STAGE}/$(echo "${ref}" | tr '/:@' '___')"
  rm -rf "${dest}"
  mkdir -p "${dest}"

  # Pull all layer blobs into ${dest}.
  oras pull "${ref}" --output "${dest}"

  # Walk the manifest in order so we apply base before overlay.
  manifest_json="$(oras manifest fetch "${ref}")"
  echo "${manifest_json}" \
    | jq -r '.layers[] | "\(.digest)\t\(.annotations["org.opencontainers.image.title"] // "")"' \
    | while IFS=$'\t' read -r digest title; do
        # ORAS names layer files using their `org.opencontainers.image.title`
        # annotation when present, otherwise it falls back to the digest.
        # Our build script doesn't set per-layer titles, so we look for the
        # plain `<basename>.tar.gz` files we know we pushed.
        candidate=""
        for f in "${dest}"/*.tar.gz; do
          [[ -e "$f" ]] || continue
          actual="sha256:$(sha256sum "$f" | awk '{print $1}')"
          if [[ "${actual}" == "${digest}" ]]; then
            candidate="$f"
            break
          fi
        done
        if [[ -z "${candidate}" ]]; then
          echo "could not locate pulled blob for ${digest}" >&2
          exit 1
        fi
        apply_layer "${candidate}"
      done
done

echo ">> done"
