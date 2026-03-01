# syntax=docker/dockerfile:1.6
FROM node:22-slim

ENV OPENCLAW_HOME=/data/openclaw \
    WORKSPACE=/data/openclaw/.openclaw/workspace \
    WORKSPACE_REPO_DIR=/data/repo

RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g openclaw

WORKDIR ${WORKSPACE}

# Base config — full openclaw.json with sane defaults (model, gateway, hooks, etc.)
# The repo only needs a minimal openclaw.json with agent-specific overrides
COPY openclaw/openclaw.json /tmp/base-openclaw.json

EXPOSE 3000

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
