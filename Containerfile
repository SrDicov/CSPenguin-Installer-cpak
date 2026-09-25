FROM ghcr.io/containerpak/wine@sha256:349a09eac549c9cddd5b6b40d892d72b4a5b92b25bd210a8e20075072969a97a

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        cabextract \
        curl \
        desktop-file-utils \
        file \
        fontconfig \
        fonts-dejavu-core \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-tools \
        libfreetype6 \
        libfreetype6:i386 \
        tar \
        wget \
        wmctrl \
        x11-utils \
        xfonts-base \
        xterm \
        xz-utils \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# Baked Wine runtime (Kron4ek build, checksum-verified).
# First-launch then reuses this instead of downloading Wine to the user home.
ARG WINE_VERSION=11.4
ARG WINE_SHA256=b98761339edb5cf9a3f622fa08de2d4b453ab96e2b5d8a612aa3687ea6ec523f

RUN mkdir -p /opt/cspenguin \
    && curl -fL --retry 3 --connect-timeout 30 \
        -o /tmp/wine-${WINE_VERSION}-amd64.tar.xz \
        "https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}/wine-${WINE_VERSION}-amd64.tar.xz" \
    && printf '%s  %s\n' "${WINE_SHA256}" "/tmp/wine-${WINE_VERSION}-amd64.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/wine-${WINE_VERSION}-amd64.tar.xz -C /opt/cspenguin \
    && for d in /opt/cspenguin/wine-${WINE_VERSION}-staging-amd64 \
                /opt/cspenguin/wine-${WINE_VERSION}-amd64 \
                /opt/cspenguin/wine-${WINE_VERSION}-plain-amd64; do \
         if [ -d "$d" ]; then mv "$d" /opt/cspenguin/wine-${WINE_VERSION}; break; fi; \
       done \
    && rm -f /tmp/wine-${WINE_VERSION}-amd64.tar.xz \
    && test -x /opt/cspenguin/wine-${WINE_VERSION}/bin/wine

COPY install.sh /opt/cspenguin/install.sh
COPY cpak-launcher.sh /usr/local/bin/cspenguin-cpak
COPY cpak-launcher.sh /usr/local/bin/cspenguin-studio-cpak
COPY cspenguin.desktop /usr/share/applications/com.cspenguin.ClipStudioPaint.desktop
COPY cspenguin-studio.desktop /usr/share/applications/com.cspenguin.ClipStudio.desktop

RUN chmod 0755 /opt/cspenguin/install.sh /usr/local/bin/cspenguin-cpak /usr/local/bin/cspenguin-studio-cpak
