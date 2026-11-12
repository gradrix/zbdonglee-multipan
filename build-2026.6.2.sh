#!/bin/bash
# Builds the SiSDK 2026.6.2 multi-PAN RCP for the ZBDongle-E in Docker (x86_64 host; Silicon Labs'
# toolchain is x86_64 only). Output: dist/*.gbl and dist/SHA256SUMS.
#
#   ./build-2026.6.2.sh            patched firmware (VERSION below)
#   ./build-2026.6.2.sh --stock    Silicon Labs' sample with only the stick's settings (silent on
#                                  this chip, see README)
#
# The base project is Silicon Labs' own sample, copied unchanged from the SDK in the builder image
# (openthread_app/ot-ncp/cpc/rcp-uart-802154: "OpenThread Zigbee CMP - RCP UART", quality:
# production) with three additions: the SDK pin, the CPC fix (patches-2026.6.2/, applied to the
# SDK) and firmware-2026.6.2/efmreset.c with DEBUG_EFM/DEBUG_EFM_USER defined. Without those two
# defines the build stays silent on this chip (cause open, TODO.md); with them a failed assert
# resets the chip. The manifest (firmware-2026.6.2/) supplies the stick's pins and settings.
set -euo pipefail

BUILDER_REPO=https://github.com/Nerivec/silabs-firmware-builder.git
BUILDER_COMMIT=78b7e414faaa6a76b7903662b11ddf53c7036e1e  # branch sisdk-2026.6.x, 2026-10-23
SDK_VERSION=2026.6.2
VERSION=cpcfix.1

here=$(cd "$(dirname "$0")" && pwd)
patches=1 suffix=$VERSION
if [[ ${1:-} == --stock ]]; then patches=0 suffix=stock; fi
out=$here/dist
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$work" init -q builder
git -C "$work/builder" fetch -q --depth 1 "$BUILDER_REPO" "$BUILDER_COMMIT"
git -C "$work/builder" checkout -q FETCH_HEAD

# The builder's own Dockerfile at that commit (slt, slc, Commander, GCC 14.2.1, SiSDK 2026.6.2).
image=zbdonglee-multipan-builder:sisdk-${SDK_VERSION}-${BUILDER_COMMIT:0:8}
docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$work/builder"

mkdir -p "$work/builder/manifests/zbdonglee-multipan" "$work/fw/patches"
cp "$here/firmware-2026.6.2/sonoff_zbdonglee_multipan_rcp.yaml" "$here/firmware-2026.6.2/efmreset.c" "$work/fw/"
if ((patches)); then cp "$here"/patches-2026.6.2/*.patch "$work/fw/patches/"; fi
cp "$work/fw/sonoff_zbdonglee_multipan_rcp.yaml" "$work/builder/manifests/zbdonglee-multipan/"

# The patches go into the container's copy of the SDK (--rm), never into the cached image.
docker run --rm -v "$work/builder:/repo" -v "$work/fw:/fw:ro" --entrypoint sh "$image" -euc "
  sdk=\$(slt where simplicity-sdk)
  for p in /fw/patches/*.patch; do [ -e \"\$p\" ] && (cd \$sdk && git apply -v \$p); done
  src=\$sdk/openthread_app/ot-ncp/cpc
  mkdir -p /repo/src/multipan_rcp
  cp \$src/rcp-uart-802154.slcp \$src/app.c \$src/app.h \$src/README-MP-RCP.md /repo/src/multipan_rcp/
  printf 'sdk:\n  vendor: silabs\n  id: simplicity_sdk\n  version: ${SDK_VERSION}\n' >> /repo/src/multipan_rcp/rcp-uart-802154.slcp
  if [ $patches = 1 ]; then
    cp /fw/efmreset.c /repo/src/multipan_rcp/
    sed -i 's/^  - path: app.c\$/  - path: app.c\\n  - path: efmreset.c/' /repo/src/multipan_rcp/rcp-uart-802154.slcp
    printf 'define:\\n  - name: DEBUG_EFM_USER\\n  - name: DEBUG_EFM\\n' >> /repo/src/multipan_rcp/rcp-uart-802154.slcp
  fi
  /opt/venv/bin/python3 tools/build_project.py \
    --manifest manifests/zbdonglee-multipan/sonoff_zbdonglee_multipan_rcp.yaml \
    --build-dir build --output-dir outputs --output gbl \
    --repo-owner gradrix --repo-hash ${BUILDER_COMMIT:0:8}
  chown -R $(id -u):$(id -g) /repo
"

name=sonoff_zbdonglee_rcp-uart-802154_460800_${SDK_VERSION}-$suffix.gbl
cp "$work"/builder/outputs/*.gbl "$out/$name"
(cd "$out" && sha256sum ./*.gbl | sed 's# \./# #' > SHA256SUMS && cat SHA256SUMS)
