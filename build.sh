#!/bin/bash
# Builds the patched multi-PAN RCP firmware in Docker (x86_64 host). Output: dist/*.gbl and
# dist/SHA256SUMS.
#
#   ./build.sh            patched firmware (VERSION below)
#   ./build.sh --stock    the same build without patches (to compare with Nerivec's release)
set -euo pipefail

# Nerivec/silabs-firmware-builder tag v2024.6.2: build script, ZBDongle-E project and manifest.
BUILDER_REPO=https://github.com/Nerivec/silabs-firmware-builder.git
BUILDER_COMMIT=830267e6859bc8696eee7eb3963e512e95d84967
MANIFEST=manifests/sonoff_zbdonglee_rcp-uart-802154-blehci-sw_460800.yaml
VERSION=cpcfix.1

here=$(cd "$(dirname "$0")" && pwd)
patches=1 suffix=$VERSION
if [[ ${1:-} == --stock ]]; then patches=0 suffix=stock; fi
out=$here/dist
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The image tag follows the Dockerfile, so an edited Dockerfile builds a new image.
image=zbdonglee-multipan-builder:$(sha256sum "$here/Dockerfile" | cut -c1-12)
docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$here"

git -C "$work" init -q builder
git -C "$work/builder" fetch -q --depth 1 "$BUILDER_REPO" "$BUILDER_COMMIT"
git -C "$work/builder" checkout -q FETCH_HEAD
sed -e "s/^filename: .*/filename: \"{manifest_name}_{sdk_version}-$suffix\"/" \
  "$work/builder/$MANIFEST" > "$work/builder/manifests/zbdonglee-multipan.yaml"
mkdir "$work/patches"
if ((patches)); then cp "$here"/patches/*.patch "$work/patches/"; fi

docker run --rm -v "$work:/w" -w /w/builder "$image" bash -euc "
  for p in /w/patches/*.patch; do
    [ -e \"\$p\" ] || continue
    patch -d /simplicity_sdk -p1 --forward < \"\$p\"
  done
  slc signature trust --sdk /simplicity_sdk >/dev/null 2>&1 || true
  python3 tools/build_project.py --sdk /simplicity_sdk \
    --toolchain /opt/arm-gnu-toolchain-12.2.rel1-x86_64-arm-none-eabi \
    --manifest manifests/zbdonglee-multipan.yaml --build-dir build --build-system makefile \
    --output-dir outputs --output gbl
  chown -R $(id -u):$(id -g) /w
"

name=sonoff_zbdonglee_rcp-uart-802154-blehci-sw_460800_2024.6.2-$suffix.gbl
cp "$work"/builder/outputs/*.gbl "$out/$name"
(cd "$out" && sha256sum ./*.gbl | sed 's# \./# #' > SHA256SUMS && cat SHA256SUMS)
