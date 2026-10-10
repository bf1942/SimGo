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

# EC20F can emit remote hangup as NO CARRIER without the call-end URC that
# chan_quectel expects. Apply a semantic source rewrite that turns NO CARRIER
# into the same Released state transition used by the normal CEND path.
COPY docker/patch-chan-quectel-ec20f.sh /tmp/patch-chan-quectel-ec20f.sh
RUN chmod +x /tmp/patch-chan-quectel-ec20f.sh \
    && /tmp/patch-chan-quectel-ec20f.sh /tmp/chan-quectel/at_response.c \
    && grep -q 'SimGo EC20F: remote hangup may only emit NO CARRIER' /tmp/chan-quectel/at_response.c

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
