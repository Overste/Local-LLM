FROM node:22-bookworm-slim

ARG OPENCODE_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        curl \
        ripgrep \
        fd-find \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@opencode/cli@${OPENCODE_VERSION}"

# The container may run as any uid (see CONTAINER_USER in bin/lib.sh), so its
# home is writable by all.
ENV HOME=/home/opencode
RUN mkdir -p /home/opencode/.config/opencode /home/opencode/.local /workspace \
    && chmod -R 777 /home/opencode

WORKDIR /workspace

CMD ["opencode"]
