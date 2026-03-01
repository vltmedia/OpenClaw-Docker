# OpenClaw Agent Server

A generic, repo-driven Docker image for running [OpenClaw](https://docs.openclaw.ai) agents. Point `WORKSPACE_REPO` at any Git repository with an `openclaw/` directory and the container pulls the agent's config, skills, memory, plugins, and workspace files at runtime. One image, any agent.

## Quick Start

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/your-agent-repo \
  -e OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  -e GATEWAY_TOKEN=my-secret-token \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  --tty --interactive \
  your-image-name:latest
```

Open the Control UI at **http://localhost:3349** and enter the gateway token. No onboarding needed — the API key is provisioned automatically from the env var.

## How It Works

On every container start:

1. Clones (or pulls) the repo from `WORKSPACE_REPO`
2. Seeds (first run) or merges (subsequent runs) the `openclaw/` directory into the running config
3. Removes the cloned repo to keep the workspace clean
4. Provisions API keys, Discord tokens, and plugin configs from env vars
5. Applies runtime patches (gateway token, CORS origins)
6. Starts the OpenClaw Gateway

All credentials are set from environment variables on every boot, so they survive container recreation (e.g., Coolify redeploys, `docker compose up --force-recreate`) without needing to re-run onboarding.

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

All configuration is done through environment variables. The entrypoint patches everything at runtime, so credentials and config survive container recreation without manual setup.

### Required

| Variable | Description |
|----------|-------------|
| `WORKSPACE_REPO` | Git URL for the agent definition repo (must contain `openclaw/`) |

### LLM API Keys

Set at least one. The entrypoint writes the key directly into the agent's auth store — no `openclaw onboard` needed.

| Variable | Description |
|----------|-------------|
| `OPENAI_API_KEY` | OpenAI API key — required if your agent uses an OpenAI model (e.g., `gpt-5.1-codex`) |
| `ANTHROPIC_API_KEY` | Anthropic API key — required if your agent uses a Claude model |

### Integrations

| Variable | Description |
|----------|-------------|
| `DISCORD_BOT_TOKEN` | Discord bot token — enables the agent as a Discord bot |
| `OUTLINE_URL` | Outline instance base URL (e.g., `https://docs.example.com`) |
| `OUTLINE_TOKEN` | Outline API token for the `outline_tools` plugin |
| `OUTLINE_ROOT_DOC` | Outline root document URL for the `outline_tools` plugin |

### Gateway & Access

| Variable | Description |
|----------|-------------|
| `GATEWAY_TOKEN` | Override the gateway auth token at runtime |
| `ALLOWED_ORIGINS` | Comma-separated list of allowed CORS origins for the Control UI |

### Git & Repo

| Variable | Description |
|----------|-------------|
| `GIT_TOKEN` | Git access token for cloning private repos (GitHub PAT, GitLab token, etc.) |
| `GIT_USER` | Git username for private repo auth (default: `git`) |
| `SYNC_MODE` | Set to `true` to force-refresh config/skills/plugins from the repo (repo wins on conflict) |
| `OPENCLAW_HOME` | OpenClaw data directory (default: `/data/openclaw`) |

## Ports

| Container Port | Description |
|----------------|-------------|
| `3000` | OpenClaw Gateway + Control UI |

Map it to any host port you like (e.g., `-p 3349:3000`).

## Volumes

| Path | Description |
|------|-------------|
| `/data/openclaw` | Persistent storage for credentials, config, and session data |

## Mounting Local Files

Mount a local directory into the agent's workspace so it can read, edit, and create files on your machine:

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/your-agent-repo \
  -e OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  -v /path/to/your/project:/data/openclaw/.openclaw/workspace/work \
  --tty --interactive \
  your-image-name:latest
```

The mount must be inside `/data/openclaw/.openclaw/workspace/` — this is the agent's workspace path, so anything inside it is accessible without permission prompts. The `work` subdirectory is the agent's default working directory, putting your files right where it operates. Changes are synced in real time — files the agent creates appear on your local disk, and local edits are immediately visible to the agent.

## Authentication

The gateway requires a token to connect. Set `GATEWAY_TOKEN` in your environment:

```bash
-e GATEWAY_TOKEN=my-secret-token
```

To allow access from additional origins (e.g., remote hosts):

```bash
-e ALLOWED_ORIGINS="http://localhost:3349,https://myhost.example.com"
```

## Private Repositories

To clone from a private repo, set `GIT_TOKEN`:

```bash
-e GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Works with GitHub PATs, GitLab tokens (`GIT_USER=oauth2`), Gitea tokens, etc. If `GIT_TOKEN` is not set, credentials are skipped (public repos only).

## Docker Compose

```yaml
services:
  my_agent:
    image: your-image-name:latest
    environment:
      WORKSPACE_REPO: https://github.com/your-org/your-agent-repo
      OPENAI_API_KEY: sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
      # ANTHROPIC_API_KEY: sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx
      # DISCORD_BOT_TOKEN: your-discord-bot-token
      GATEWAY_TOKEN: my-secret-token
      OPENCLAW_HOME: /data/openclaw
      # ALLOWED_ORIGINS: "http://localhost:3349,https://myhost.example.com"
      # SYNC_MODE: "true"
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

If you need to start completely fresh, stop the container and delete the volume. **Be careful — this is a full factory reset** that deletes all session history, memory, runtime config changes, and any skills or plugins added via the UI.

```bash
docker stop my_agent && docker rm my_agent
docker volume rm openclaw_agent_state
```

Since all credentials are set via env vars, you don't need to re-run onboarding after a reset — just start the container again.

## Links

- [OpenClaw Documentation](https://docs.openclaw.ai)
- [Source & Dockerfile](https://github.com/vltmedia/OpenClaw-Docker)
