#!/bin/bash
#
# Free re-check of the moderation policy of ADR-0019 (bead openmoji-6dr.8). Builds and runs
# spikes/m2-safety/moderate/main.swift together with the sources of Packages/OpenMojiCore, so it
# exercises the app's own client and ModerationPolicy. See "Re-checking the moderation policy" in
# spikes/m2-safety/README.md. From the repo root:
#
#   bash spikes/m2-safety/moderate.sh --stub                     # offline self-check, no key, no network
#   op run --env-file spikes/m2-safety/op.env -- bash spikes/m2-safety/moderate.sh
#   op run --env-file spikes/m2-safety/op.env -- bash spikes/m2-safety/moderate.sh "my own prompt"
#   op run --env-file spikes/m2-safety/op.env -- bash spikes/m2-safety/moderate.sh --images spikes/m2-safety/out/sticker/new
#
# The moderation endpoint is free: nothing here generates an image. The key comes from
# OPENAI_API_KEY in the environment and is never printed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/openmoji-moderate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

swiftc -swift-version 6 -O -o "$TMP/moderate" \
  "$HERE/moderate/main.swift" \
  "$ROOT"/Packages/OpenMojiCore/Sources/OpenMojiCore/*.swift

"$TMP/moderate" "$@"
