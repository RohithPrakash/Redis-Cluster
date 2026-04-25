# SPDX-License-Identifier: Apache-2.0

FROM almalinux:9

# Install Redis 7.2 from AlmaLinux AppStream and ensure redis user has UID/GID 999
RUN dnf module enable -y redis:7 && \
    dnf install -y redis && \
    dnf clean all && \
    rm -rf /var/cache/dnf /tmp/* && \
    (getent group 999 >/dev/null 2>&1 && groupmod -g 1999 $(getent group 999 | cut -d: -f1) || true) && \
    (id -u 999 >/dev/null 2>&1 && usermod -u 1999 $(id -un 999) || true) && \
    (getent group redis >/dev/null 2>&1 && groupmod -g 999 redis || groupadd -g 999 redis) && \
    (id -u redis >/dev/null 2>&1 && usermod -u 999 -g 999 redis || useradd -u 999 -g 999 redis) && \
    mkdir -p /data && chown -R redis:redis /data

WORKDIR /data

# Expose Redis client port and cluster bus port
EXPOSE 6379 16379

# Run Redis server using the provided configuration file
CMD ["redis-server", "/etc/redis/redis.conf"]
