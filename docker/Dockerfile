# ---- Build stage: compile chan-quectel ----
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    autoconf \
    automake \
    libtool \
    pkg-config \
    asterisk-dev \
    libsqlite3-dev \
    libasound2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/myleo1/asterisk-chan-quectel-lts.git /tmp/chan-quectel

WORKDIR /tmp/chan-quectel

# EC20F firmware may only emit NO CARRIER when the remote party hangs up.
# Patch chan_quectel so that event releases the Asterisk channel instead of
# leaving the driver stuck in Active/Dialing.
COPY docker/patches/ec20f-no-carrier-release.patch /tmp/ec20f-no-carrier-release.patch
RUN git apply --check /tmp/ec20f-no-carrier-release.patch \
    && git apply /tmp/ec20f-no-carrier-release.patch

RUN ./bootstrap

# The upstream Makefile always creates chan_quectel.so in the build directory.
# Do not depend on its install DESTDIR when exporting the module between stages;
# copy the build artifact directly and assert that it exists.
RUN ASTERISK_VER=$(dpkg-query -W -f='${Version}' asterisk-dev | sed 's/.*://' | sed 's/~.*//') \
    && ./configure DESTDIR=/tmp --with-astversion=${ASTERISK_VER} \
    && make \
    && test -s ./chan_quectel.so \
    && cp ./chan_quectel.so /tmp/chan-quectel.so

# ---- Runtime stage ----
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    asterisk \
    asterisk-dev \
    ca-certificates \
    libasound2t64 \
    libsqlite3-0 \
    python3 \
    python3-requests \
    python3-socks \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled chan-quectel module to correct arch path
COPY --from=builder /tmp/chan-quectel.so /tmp/chan-quectel.so
RUN cp /tmp/chan-quectel.so /usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/asterisk/modules/chan_quectel.so

# Asterisk directories
RUN mkdir -p /etc/asterisk/templates /etc/asterisk/scripts /etc/asterisk/certs \
    /var/log/asterisk /var/lib/asterisk/smsdb

# Timezone
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

EXPOSE 52060/tcp 42077-42126/udp

COPY start.sh /start.sh
COPY docker/entrypoint-clcc-sync.sh /entrypoint-clcc-sync.sh
RUN chmod +x /start.sh /entrypoint-clcc-sync.sh

ENTRYPOINT ["/entrypoint-clcc-sync.sh"]
