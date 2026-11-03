# Build environment for Silicon Labs SiSDK 2024.6.2 firmware on a current machine.
# Nerivec/silabs-firmware-builder's own Dockerfile at tag v2024.6.2 no longer builds (Silicon
# Labs moved the slc and Commander downloads), so this takes slc and Commander from Silicon Labs'
# `slt` package manager and adds the toolchain and SDK that release was built with.
FROM debian:bookworm-20261005-slim

ARG SLT_SHA256=b0757c79d5dd03f41ff3b2bf2074d918e5e4d5c56835506a2887d5b4275384dc
ARG GCC_SHA256=84be93d0f9e96a15addd490b6e237f588c641c8afdf90e7610a628007fc96867
ARG SDK_SHA256=7e4337c7cc68262dd3a83c8528095774634a0478d40b1c1fd2b462e86236af8a

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libarchive-tools bzip2 xz-utils git make patch jq yq \
        python3 python3-ruamel.yaml \
        libstdc++6 libgl1 libglib2.0-0 libdbus-1-3 libpng16-16 libpcre2-16-0 \
    && rm -rf /var/lib/apt/lists/* \
    && git config --global --add safe.directory '*'

# slc (project generator) and Commander (GBL packaging), both via slt.
RUN set -e \
    && curl -fsSL -o /tmp/slt.zip https://www.silabs.com/documents/public/software/slt-cli-1.2.2-linux-x64.zip \
    && echo "$SLT_SHA256  /tmp/slt.zip" | sha256sum -c - \
    && bsdtar -xf /tmp/slt.zip -C /usr/bin && rm /tmp/slt.zip && chmod +x /usr/bin/slt \
    && slt --non-interactive install conan \
    && slt --non-interactive install commander/1.25.0 slc-cli/6.0.25 \
    && rm -rf /root/.silabs/slt/installs/archive/*.zip /root/.silabs/slt/installs/archive/*.tar.* \
              /root/.silabs/slt/installs/conan/p/*/d/ /root/.silabs/slt/installs/conan/download_cache \
    && ln -s "$(slt where java21)/jre/bin/java" /usr/local/bin/java \
    && ln -s "$(slt where commander)/commander" /usr/local/bin/commander \
    && printf '#!/bin/sh\nexec "%s/slc" "$@"\n' "$(slt where slc-cli)" > /usr/local/bin/slc \
    && chmod +x /usr/local/bin/slc

# GCC 12.2.rel1: the toolchain SiSDK 2024.6.2 projects ask for (Arm's published checksum).
RUN set -e \
    && curl -fsSL -o /tmp/gcc.tar.xz https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/12.2.rel1/binrel/arm-gnu-toolchain-12.2.rel1-x86_64-arm-none-eabi.tar.xz \
    && echo "$GCC_SHA256  /tmp/gcc.tar.xz" | sha256sum -c - \
    && tar -C /opt -xf /tmp/gcc.tar.xz && rm /tmp/gcc.tar.xz

RUN set -e \
    && curl -fsSL -o /tmp/sdk.zip https://github.com/SiliconLabs/simplicity_sdk/releases/download/v2024.6.2/gecko-sdk.zip \
    && echo "$SDK_SHA256  /tmp/sdk.zip" | sha256sum -c - \
    && unzip -q -d /simplicity_sdk /tmp/sdk.zip && rm /tmp/sdk.zip

WORKDIR /build
