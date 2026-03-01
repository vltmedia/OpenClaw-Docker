# OpenClaw Agent Server

A generic, repo-driven Docker image for running [OpenClaw](https://docs.openclaw.ai) agents. Point `WORKSPACE_REPO` at any Git repository with an `openclaw/` directory and the container pulls the agent's config, skills, memory, plugins, and workspace files at runtime. One image, any agent.

## Quick Start

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/your-agent-repo \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  --tty --interactive \
  your-image-name:latest
```

Then run onboarding to set up your API key (first time only):

```bash
docker exec -it my_agent openclaw onboard
docker restart my_agent
```

Open the Control UI at **http://localhost:3349** and enter the auth token from your agent repo's `openclaw.json`.

## How It Works

On every container start:

1. Clones (or pulls) the repo from `WORKSPACE_REPO`
2. Seeds (first run) or merges (subsequent runs) the `openclaw/` directory into the running config
3. Removes the cloned repo to keep the workspace clean
4. Applies runtime env var patches (tokens, CORS origins)
5. Starts the OpenClaw Gateway

On subsequent boots, `openclaw.json` is deep-merged — repo values win, but runtime-only keys (like onboarded credentials) are preserved. Workspace files, skills, memory, and plugins are overlaid (repo wins on name conflicts, existing files not in the repo are kept).

## Agent Repo Structure

Your `WORKSPACE_REPO` must contain an `openclaw/` directory:

```
your-agent-repo/
└── openclaw/
    ├── openclaw.json
    ├── plugins/
    │   └── my-plugin/
    │       ├── index.ts
    │       ├── openclaw.plugin.json
    │       └── skills/
    └── workspace/
        ├── IDENTITY.md
        ├── SOUL.md
        ├── BOOTSTRAP.md
        ├── memory/
        └── skills/
            └── my_skill/
                └── SKILL.md
```

Any files or directories in `workspace/` are copied into the agent's working directory — add datasets, configs, reference docs, or anything else the agent should have access to.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `WORKSPACE_REPO` | Yes | Git URL for the agent definition repo (must contain `openclaw/`) |
| `GIT_TOKEN` | No | Git access token for cloning private repos (GitHub PAT, GitLab token, etc.) |
| `GIT_USER` | No | Git username for private repo auth (default: `git`) |
| `OPENCLAW_HOME` | No | OpenClaw data directory (default: `/data/openclaw`) |
| `ALLOWED_ORIGINS` | No | Comma-separated list of allowed CORS origins for the Control UI |
| `GATEWAY_TOKEN` | No | Override the gateway auth token at runtime |

## Ports

| Container Port | Description |
|----------------|-------------|
| `3000` | OpenClaw Gateway + Control UI |

Map it to any host port you like (e.g., `-p 3349:3000`).

## Volumes

| Path | Description |
|------|-------------|
| `/data/openclaw` | Persistent storage for credentials, config, and session data |

## Authentication

The gateway requires a token to connect. The default token is set in your agent repo's `openclaw/openclaw.json` under `gateway.auth.token`.

Override the token and allowed origins via environment variables — no rebuild needed:

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/your-agent-repo \
  -e OPENCLAW_HOME=/data/openclaw \
  -e GATEWAY_TOKEN=my-secret-token \
  -e ALLOWED_ORIGINS="http://localhost:3349,https://myhost.example.com" \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  --tty --interactive \
  your-image-name:latest
```

## Onboarding

First time you run the container, register your LLM provider credentials:

```bash
docker exec -it my_agent openclaw onboard
```

The wizard asks you to:
1. Accept the terms
2. Choose a model provider (OpenAI or Anthropic)
3. Enter your API key

Credentials are stored in the persistent volume — you only need to do this once unless you remove the volume.

## Private Repositories

To clone from a private repo, set `GIT_TOKEN`:

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/private-agent-repo \
  -e GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  --tty --interactive \
  your-image-name:latest
```

Works with GitHub PATs, GitLab tokens (`GIT_USER=oauth2`), Gitea tokens, etc. If `GIT_TOKEN` is not set, credentials are skipped (public repos only).

## Docker Compose

```yaml
services:
  my_agent:
    image: your-image-name:latest
    environment:
      WORKSPACE_REPO: https://github.com/your-org/your-agent-repo
      OPENCLAW_HOME: /data/openclaw
      # ALLOWED_ORIGINS: "http://localhost:3349,https://myhost.example.com"
      # GATEWAY_TOKEN: "my-secret-token"
    ports:
      - "3349:3000"
    volumes:
      - openclaw_agent_state:/data/openclaw
    tty: true
    stdin_open: true

volumes:
  openclaw_agent_state:
```

## Factory Reset

If you need to start completely fresh, stop the container and delete the volume. **Be careful — this is a full factory reset** that deletes all onboarded credentials, session history, memory, runtime config changes, and any skills or plugins added via the UI. You will need to re-run onboarding afterward.

```bash
docker stop my_agent && docker rm my_agent
docker volume rm openclaw_agent_state
```

## Links

- [OpenClaw Documentation](https://docs.openclaw.ai)
- [Source & Dockerfile](https://github.com/vltmedia/OpenClaw-Docker)
