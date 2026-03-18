FROM node:22-slim

# Install system tools first (git required by npm install openclaw)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git python3 curl ca-certificates imagemagick lsof && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g openclaw@latest

# Kata VM patches: increase timeouts for slow event loop in Kata VMs.
# WebSocket handshake + plugin registration takes ~15s from tmpfs; when the
# gateway event loop is busy (bot executing CLI internally), it can exceed 30s.
# Patch 1: Client-side connect challenge timeout  2s → 60s
# Patch 2: Server-side handshake timeout           3s → 60s
# Patch 3: CLI gateway RPC default timeout        30s → 120s  (gateway-rpc-*.js)
# Patch 4: CLI command default timeout             10s → 120s  (gateway-cli, daemon-cli, channels-cli)
# Patch 5: CLI command default timeout (expression) 1e4 → 12e4 (rpc-*.js, devices-cli-*.js)
RUN find /usr/local/lib/node_modules/openclaw/dist -name '*.js' \
      -exec sed -i \
        -e 's/rawConnectDelayMs)) : 2e3/rawConnectDelayMs)) : 6e4/' \
        -e 's/DEFAULT_HANDSHAKE_TIMEOUT_MS = 3e3/DEFAULT_HANDSHAKE_TIMEOUT_MS = 6e4/' \
        -e 's/"Timeout in ms", "30000"/"Timeout in ms", "120000"/' \
        -e 's/"Timeout in ms", "10000"/"Timeout in ms", "120000"/' \
        -e 's/timeoutMs ?? 1e4/timeoutMs ?? 12e4/' \
        {} +

# Pre-pack openclaw as a tarball for fast tmpfs extraction in Kata VMs.
# Reduces startup copy from ~90s (37K virtiofs reads) to ~10s (1 sequential read + local untar).
RUN tar cf /opt/openclaw-bundle.tar -C /usr/local/lib/node_modules openclaw

# Gateway helper scripts (systemd unavailable in containers).
# Gateway runs as PID 1 (container entrypoint via exec), so killing it causes
# K8s to restart the entire container — which restarts the gateway automatically.
# chown to node(1000) so the entrypoint (running as uid 1000) can write the
# openclaw CLI wrapper into this directory at startup.
RUN mkdir -p /home/node/bin && \
    printf '#!/bin/sh\n# Gateway IS the container entrypoint (PID 1).\n# Killing PID 1 causes K8s to restart the container, which restarts Gateway.\necho "Restarting gateway (killing PID 1 -> K8s will restart container)..."\nkill 1\n' > /home/node/bin/gateway-restart.sh && \
    printf '#!/bin/sh\n# Gateway IS PID 1. Stopping it stops the container; K8s will restart it.\necho "Stopping gateway (PID 1)..."\nkill 1\n' > /home/node/bin/gateway-stop.sh && \
    printf '#!/bin/sh\n# Gateway is the container entrypoint (PID 1). It starts automatically.\nif lsof -nP -iTCP:18789 -sTCP:LISTEN -t > /dev/null 2>&1; then\n  echo "Gateway is already running (PID $(lsof -nP -iTCP:18789 -sTCP:LISTEN -t))"\nelse\n  echo "Gateway is NOT running. Container may be starting up or crashed."\nfi\n' > /home/node/bin/gateway-start.sh && \
    chmod +x /home/node/bin/gateway-*.sh && \
    chown -R 1000:1000 /home/node/bin

# Agent documentation (readable by the AI agent inside the container)
# AGENTS.md: always overwrite workspace copy (pick up updates)
# TOOLS.md: only copy if not exist (agent may customize)
# MEMORY.md: only copy if not exist (agent maintains this)
COPY --chown=1000:1000 AGENTS.md TOOLS.md MEMORY.md /home/node/workspace-defaults/

# Non-root user
USER 1000
WORKDIR /home/node/.openclaw/workspace

ENTRYPOINT ["openclaw", "gateway", "run"]
