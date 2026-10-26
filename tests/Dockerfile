ARG DEBIAN_VERSION=12
FROM debian:${DEBIAN_VERSION}-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash ca-certificates curl python3 openssh-server iproute2 procps passwd systemd shellcheck \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENV PLEX_TEST_CONTAINER=1
CMD ["bash", "tests/smoke.sh"]
