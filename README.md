# OpenClaw Agent Server — Repo-Driven Docker Deployment

A generic Docker deployment of an [OpenClaw](https://docs.openclaw.ai) agent that pulls its entire identity — config, skills, memory, plugins, and workspace files — from a Git repository at runtime. One image, any agent. Just point `WORKSPACE_REPO` at a repo with an `openclaw/` directory.

## How It Works

On every container start the entrypoint:

1. **Clones** (or pulls) the repo specified by `WORKSPACE_REPO`
2. **Runs `build.sh`** if present in the repo root (first run and `SYNC_MODE=true` only)
3. **Seeds** (first run) or **merges** (subsequent runs) the repo's `openclaw/` directory into the running OpenClaw config
4. **Deletes** the cloned repo to avoid duplicate files confusing the agent
5. **Applies** any runtime env var patches (`GATEWAY_TOKEN`, `ALLOWED_ORIGINS`)
6. **Starts** the OpenClaw Gateway + Control UI

On subsequent runs, `openclaw.json` is deep-merged (repo values win, but runtime keys like onboarded credentials are preserved). Workspace files, skills, memory, and plugins are overlaid (repo wins on conflict, existing files not in the repo are kept).

## Example Agent:
You can go to this [Outline Plugin Example Repo](https://github.com/vltmedia/Outline-Agent-OpenClaw) to see a working example of an agent repo structure, which you can point `WORKSPACE_REPO` at directly.

## Agent Repo Structure

Your `WORKSPACE_REPO` must contain an `openclaw/` directory at the root:

```
your-agent-repo/
├── build.sh                       # Optional — runs on first boot and SYNC_MODE=true
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

### Build Script (`build.sh`)

If your agent repo has a `build.sh` in the root directory, the entrypoint will run it **before** merging the `openclaw/` directory. This lets you do any custom setup — cloning additional repos, compiling assets, generating config files, installing dependencies, etc.

`build.sh` only runs during:
- **First boot** (no existing config)
- **Sync mode** (`SYNC_MODE=true`)

On normal subsequent boots it is skipped, since the build artifacts are already persisted on the volume. If `build.sh` exits with a non-zero status, the entire entrypoint stops — so you can use `exit 1` for validation (e.g., checking that required env vars are set).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- A Git-accessible agent repo with an `openclaw/` directory
- An LLM API key (OpenAI, Anthropic, etc.)

## Quick Start

### 1. Create a `.env` file

```bash
cp .env.example .env
```

Edit `.env` and set your agent repo and API key:

```
WORKSPACE_REPO=https://github.com/your-org/your-agent-repo
OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
GATEWAY_TOKEN=my-secret-token
```

That's the minimum — the entrypoint handles everything else automatically. See [Environment Variables](#environment-variables) for the full list of options.

### 2. Build and start the container

```bash
docker compose up --build -d
```

The container will clone the repo, merge the config, provision the API key, and start the gateway. No manual onboarding needed.

### 3. Open the Control UI

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
  -e OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  -e GATEWAY_TOKEN=my-secret-token \
  -e OPENCLAW_HOME=/data/openclaw \
  -p 3349:3000 \
  -v openclaw_agent_state:/data/openclaw \
  --tty --interactive \
  openclaw-agent
```

### 4. Open the Control UI

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

All configuration is done through environment variables. Set them in your `.env` file, `docker-compose.yml`, or pass them with `-e` flags. The entrypoint patches everything at runtime so credentials and config survive container recreation (e.g., Coolify redeploys) without needing to run `openclaw onboard`.

### Required

| Variable | Description |
|----------|-------------|
| `WORKSPACE_REPO` | Git URL for the agent definition repo (must contain an `openclaw/` directory) |

### LLM API Keys

Set at least one of these. The entrypoint writes the key directly into the agent's auth store, replacing the need for `openclaw onboard`.

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
- Session history and memory
- Config and workspace files (merged from repo on each boot)

### Factory reset

If you need to start completely fresh, stop the container and delete the volume. **Be careful — this is a full factory reset** that deletes all session history, memory, runtime config changes, and any skills or plugins added via the UI. Since credentials are set via env vars, you don't need to re-onboard — just start the container again.

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

### API key not working after redeploy
Make sure `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` is set in your environment variables. The entrypoint provisions the key on every boot, so it survives container recreation automatically.
