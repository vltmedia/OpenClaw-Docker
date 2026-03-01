# OpenClaw Agent Server — Repo-Driven Docker Deployment

A generic Docker deployment of an [OpenClaw](https://docs.openclaw.ai) agent that pulls its entire identity — config, skills, memory, plugins, and workspace files — from a Git repository at runtime. One image, any agent. Just point `WORKSPACE_REPO` at a repo with an `openclaw/` directory.

## How It Works

On every container start the entrypoint:

1. **Clones** (or pulls) the repo specified by `WORKSPACE_REPO`
2. **Seeds** (first run) or **merges** (subsequent runs) the repo's `openclaw/` directory into the running OpenClaw config
3. **Deletes** the cloned repo to avoid duplicate files confusing the agent
4. **Applies** any runtime env var patches (`GATEWAY_TOKEN`, `ALLOWED_ORIGINS`)
5. **Starts** the OpenClaw Gateway + Control UI

On subsequent runs, `openclaw.json` is deep-merged (repo values win, but runtime keys like onboarded credentials are preserved). Workspace files, skills, memory, and plugins are overlaid (repo wins on conflict, existing files not in the repo are kept).

## Example Agent:
You can go to this [Outline Plugin Example Repo](https://github.com/vltmedia/Outline-Agent-OpenClaw) to see a working example of an agent repo structure, which you can point `WORKSPACE_REPO` at directly.

## Agent Repo Structure

Your `WORKSPACE_REPO` must contain an `openclaw/` directory at the root:

```
your-agent-repo/
└── openclaw/
    ├── openclaw.json              # Gateway + agent configuration
    ├── plugins/                   # Optional — plugin directories
    │   └── my-plugin/
    │       ├── index.ts
    │       ├── openclaw.plugin.json
    │       └── skills/
    │           └── SKILLS.md
    └── workspace/                 # Optional — workspace files
        ├── IDENTITY.md            # Agent persona / identity
        ├── SOUL.md                # Agent personality
        ├── AGENTS.md              # Sub-agent definitions
        ├── BOOTSTRAP.md           # Startup instructions
        ├── HEARTBEAT.md           # Periodic task instructions
        ├── TOOLS.md               # Tool usage guidelines
        ├── USER.md                # User context
        ├── memory/                # Pre-seeded memory files
        │   └── *.md
        └── skills/                # Skill definitions
            └── my_skill/
                └── SKILL.md
```

Any files or directories you place in `workspace/` will be copied into the agent's working workspace — you can add datasets, configs, reference docs, or anything else the agent should have access to.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- A Git-accessible agent repo with an `openclaw/` directory
- An LLM API key (OpenAI, Anthropic, etc.)

## Quick Start

### 1. Create a `.env` file

```bash
cp .env.example .env
```

Edit `.env` and set:

```
WORKSPACE_REPO=https://github.com/your-org/your-agent-repo
```

### 2. Build and start the container

```bash
docker compose up --build -d
```

### 3. Run onboarding (first time only)

The agent needs your LLM API key stored in its credential store. Shell into the running container and run the onboard wizard:

```bash
docker compose exec outline_claw openclaw onboard
```

This walks you through:
- Accepting the terms
- Selecting your model provider (OpenAI or Anthropic)
- Entering your API key

The key is saved inside the persistent Docker volume, so you only need to do this once.

### 4. Restart the gateway

After onboarding, restart so the gateway picks up the new credentials:

```bash
docker compose restart
```

### 5. Open the Control UI

Navigate to:

```
http://localhost:3349
```

Enter the gateway auth token when prompted (see [Authentication](#authentication) below).

## Authentication

The gateway uses **token-based auth**. When you open the Control UI, you'll be asked for a token.

### Default token

The default token is set in your agent repo's `openclaw/openclaw.json` under `gateway.auth.token`. Enter that value in the Control UI prompt.

### Overriding the token at runtime

Set the `GATEWAY_TOKEN` environment variable — no rebuild needed:

```yaml
# docker-compose.yml
environment:
  GATEWAY_TOKEN: "my-secret-token"
```

### Device pairing

Device pairing is **disabled** in this deployment (`dangerouslyDisableDeviceAuth: true`) for convenience. Any browser with the token can connect without an additional approval step.

To re-enable pairing for tighter security, set `dangerouslyDisableDeviceAuth` to `false` in your agent repo's `openclaw/openclaw.json`.

### Allowed origins

The Control UI enforces CORS via `allowedOrigins`. To allow additional origins, set the `ALLOWED_ORIGINS` environment variable as a comma-separated list:

```yaml
# docker-compose.yml
environment:
  ALLOWED_ORIGINS: "http://localhost:3349,https://myhost.example.com"
```

The entrypoint patches the config at runtime, so you don't need to rebuild.

### Security notes

- The gateway binds to `0.0.0.0` inside the container (`bind: "lan"`) so Docker can route traffic. It is only exposed on the mapped host port.
- Do **not** expose the port to the public internet without setting a strong token and re-enabling device auth.

## Running Without Docker Compose

### 1. Build the image

```bash
docker build -t openclaw-agent .
```

### 2. Create a volume for persistent data

```bash
docker volume create openclaw_agent_state
```

### 3. Run the container

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/your-agent-repo \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  --tty --interactive \
  openclaw-agent
```

### 4. Run onboarding (first time only)

```bash
docker exec -it my_agent openclaw onboard
docker restart my_agent
```

### 5. Open the Control UI

Navigate to `http://localhost:3349` and enter the auth token.

### Useful commands

```bash
# View logs
docker logs -f my_agent

# Shell into the container
docker exec -it my_agent bash

# List skills
docker exec my_agent openclaw skills list

# Stop and remove
docker stop my_agent && docker rm my_agent

# Fully reset (remove persistent data)
docker volume rm openclaw_agent_state
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `WORKSPACE_REPO` | Yes | Git URL for the agent definition repo (must contain an `openclaw/` directory) |
| `GIT_TOKEN` | No | Git access token for cloning private repos (GitHub PAT, GitLab token, etc.) |
| `GIT_USER` | No | Git username for private repo auth (default: `git`) |
| `OPENCLAW_HOME` | No | OpenClaw data directory (default: `/data/openclaw`) |
| `ALLOWED_ORIGINS` | No | Comma-separated list of allowed CORS origins for the Control UI |
| `GATEWAY_TOKEN` | No | Override the gateway auth token at runtime |

## Mounting Local Files

You can mount a local directory into the agent's workspace so it can read, edit, and create files on your machine. The mount must be inside the agent's workspace path (`/data/openclaw/.openclaw/workspace/`) — this lets the agent access the files without additional permission prompts.

### Docker Compose

Add a bind mount under `volumes` in your `docker-compose.yml`:

```yaml
volumes:
  - openclaw_agent_state:/data/openclaw
  - /path/to/your/project:/data/openclaw/.openclaw/workspace/work
```

### Plain Docker

```bash
docker run -d \
  --name my_agent \
  -e WORKSPACE_REPO=https://github.com/your-org/your-agent-repo \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  -v /path/to/your/project:/data/openclaw/.openclaw/workspace/work \
  --tty --interactive \
  openclaw-agent
```

### How it works

- The agent's workspace is `/data/openclaw/.openclaw/workspace/`. Anything inside this path is accessible to the agent without permission prompts.
- `/data/openclaw/.openclaw/workspace/work` is the agent's default working directory — mounting here puts your files right where the agent operates.
- Files the agent creates or edits in `work/` will appear on your local disk in real time, and vice versa.
- You can mount to any subdirectory inside the workspace (e.g., `workspace/data`, `workspace/docs`) if you want to keep your files separate from the agent's working directory.
- The persistent volume (`openclaw_agent_state`) still handles credentials, config, and session state separately — your mounted directory is not affected by factory resets unless you delete it yourself.

### Example use cases

- Mount a codebase for the agent to review, refactor, or generate code in
- Mount a data directory for the agent to analyze or transform files
- Mount a docs folder for the agent to read as reference material while working

## Private Repositories

To use a private Git repo as your agent source, set `GIT_TOKEN` in your `.env`:

```
WORKSPACE_REPO=https://github.com/your-org/private-agent-repo
GIT_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The entrypoint configures git's credential store automatically before cloning. Works with GitHub PATs, GitLab tokens, Gitea tokens, etc.

For GitHub, you can optionally set `GIT_USER` (defaults to `git`, which works for PAT auth). For GitLab or other providers that require a specific username:

```
GIT_USER=oauth2
GIT_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx
```

If `GIT_TOKEN` is not set, the entrypoint skips credential setup entirely and clones normally (public repos only).

## Project Structure

```
.
├── Dockerfile              # Node 22 base, installs OpenClaw via npm (generic, no agent files)
├── docker-compose.yml      # Service definition, port mapping, volume
├── entrypoint.sh           # Clones agent repo, merges config, starts gateway
└── .env                    # Environment variables (WORKSPACE_REPO, etc.)
```

## Configuration

### Changing the model

Edit `openclaw.json` in your agent repo and update the model fields, e.g.:

```json
"model": {
  "primary": "openai/gpt-5.1-codex"
}
```

### Changing the port

The gateway listens on port `3000` inside the container. To change the host port, edit `docker-compose.yml`:

```yaml
ports:
  - "YOUR_PORT:3000"
```

Then update `gateway.controlUi.allowedOrigins` in your agent repo's `openclaw.json` to match.

### How merging works

- **First boot**: Everything from the repo's `openclaw/` directory is copied directly (no merge needed since nothing exists yet).
- **Subsequent boots**: `openclaw.json` is deep-merged (repo values win, but keys only in the existing config — like onboarded credentials — are preserved). Workspace files, skills, memory, and plugins are overlaid (repo files overwrite matching names, but existing files not in the repo are kept).
- **Repo cleanup**: After merging, the cloned repo is deleted so the agent only sees a single canonical `.openclaw/` directory.

### Persistent data

The Docker volume persists:
- OpenClaw credentials (from onboarding)
- Session history and memory
- Config and workspace files (merged from repo on each boot)

### Factory reset

If you need to start completely fresh, stop the container and delete the volume. **Be careful — this is a full factory reset** that deletes all onboarded credentials, session history, memory, runtime config changes, and any skills or plugins added via the UI. You will need to re-run onboarding afterward.

```bash
# Docker Compose
docker compose down -v

# Plain Docker
docker stop openclaw_agent && docker rm openclaw_agent
docker volume rm openclaw_agent_state
```

## Troubleshooting

### "WORKSPACE_REPO not set"
Make sure the `WORKSPACE_REPO` environment variable is set in your `.env` file or `docker-compose.yml`.

### "Repo does not contain an openclaw/ directory"
Your agent repo must have an `openclaw/` directory at the root containing at least `openclaw.json`.

### "Gateway token missing"
Enter the auth token in the Control UI prompt.

### Skill not showing up
Verify the skill was copied:

```bash
docker compose exec outline_claw ls /data/openclaw/.openclaw/workspace/skills/
```

### Onboarding credentials lost
If you removed the Docker volume, re-run onboarding:

```bash
docker compose exec outline_claw openclaw onboard
docker compose restart
```
