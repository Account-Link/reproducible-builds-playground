# syntax=docker/dockerfile:1.7
ARG SOURCE_DATE_EPOCH
ARG DEBIAN_SNAPSHOT

FROM node:18-slim@sha256:f9ab18e354e6855ae56ef2b290dd225c1e51a564f87584b9bd21dd651838830e

ARG SOURCE_DATE_EPOCH
ARG DEBIAN_SNAPSHOT

ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    TZ=UTC \
    npm_config_cache=/npm-cache

RUN echo "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bookworm main" > /etc/apt/sources.list && \
    echo "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bookworm-updates main" >> /etc/apt/sources.list && \
    echo "deb http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} bookworm-security main" >> /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends curl=7.88.1-10+deb12u14 && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/ldconfig/aux-cache && \
    rm -rf /var/log/apt/* && \
    rm -rf /var/log/dpkg.log && \
    find /usr -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +

WORKDIR /app

COPY package.json package-lock.json ./
RUN mkdir -p /npm-cache && \
    npm ci --omit=dev --ignore-scripts && \
    find /app -exec touch -d "@${SOURCE_DATE_EPOCH}" {} + && \
    rm -rf /npm-cache

COPY server.js ./

EXPOSE 3000
CMD ["node", "server.js"]
