#!/bin/bash
set -e

# ── Validate required env ────────────────────────────────────────────
if [ -z "$WORKSPACE_REPO" ]; then
  echo "WORKSPACE_REPO not set"
  exit 1
fi

WORKSPACE_REPO_DIR="${WORKSPACE_REPO_DIR:-/data/repo}"

# ── Configure git credentials for private repos (optional) ───────────
if [ -n "$GIT_TOKEN" ]; then
  echo "Configuring git credentials for private repo access..."
  git config --global credential.helper store
  # Extract host from WORKSPACE_REPO (works for https://github.com/... style URLs)
  REPO_HOST=$(echo "$WORKSPACE_REPO" | sed -n 's|https\?://\([^/]*\).*|\1|p')
  if [ -n "$REPO_HOST" ]; then
    echo "https://${GIT_USER:-git}:${GIT_TOKEN}@${REPO_HOST}" > ~/.git-credentials
    chmod 600 ~/.git-credentials
  fi
fi

# ── Clone or pull the agent repo ─────────────────────────────────────
if [ ! -d "$WORKSPACE_REPO_DIR/.git" ]; then
  echo "Cloning repo from $WORKSPACE_REPO..."
  git clone --recursive "$WORKSPACE_REPO" "$WORKSPACE_REPO_DIR"
else
  echo "Repo already exists, pulling latest..."
  cd "$WORKSPACE_REPO_DIR"
  git pull
  git submodule update --init --recursive
fi

REPO_OPENCLAW="$WORKSPACE_REPO_DIR/openclaw"

if [ ! -d "$REPO_OPENCLAW" ]; then
  echo "ERROR: Repo does not contain an openclaw/ directory"
  exit 1
fi

# ── Ensure target directories exist ──────────────────────────────────
mkdir -p /data/openclaw/.openclaw/workspace/memory
mkdir -p /data/openclaw/.openclaw/workspace/skills
mkdir -p /data/openclaw/.openclaw/plugins
mkdir -p /root/.openclaw/workspace/memory
mkdir -p /root/.openclaw/workspace/skills

# ── Helper: deep-merge JSON (source wins on conflict) ────────────────
# Used by first run + SYNC_MODE — repo values overwrite existing values
# Arrays of objects with 'id' fields are merged by matching id (not replaced wholesale)
deep_merge_json() {
  local target="$1"
  local source="$2"
  node -e "
    const fs = require('fs');
    const mergeArrays = (targetArr, sourceArr, mergeFn) => {
      const result = [...targetArr];
      for (let i = 0; i < sourceArr.length; i++) {
        const srcItem = sourceArr[i];
        if (srcItem && typeof srcItem === 'object' && !Array.isArray(srcItem)) {
          if (srcItem.id) {
            // Has id — match by id
            const idx = result.findIndex(t => t && t.id === srcItem.id);
            if (idx >= 0) { result[idx] = mergeFn(result[idx], srcItem); }
            else { result.push(srcItem); }
          } else if (i < result.length && result[i] && typeof result[i] === 'object') {
            // No id — merge positionally into same-index target item
            result[i] = mergeFn(result[i], srcItem);
          } else {
            result.push(srcItem);
          }
        } else if (!result.includes(srcItem)) {
          result.push(srcItem);
        }
      }
      return result;
    };
    const deepMerge = (target, source) => {
      for (const key of Object.keys(source)) {
        if (Array.isArray(source[key]) && Array.isArray(target[key])) {
          target[key] = mergeArrays(target[key], source[key], deepMerge);
        } else if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key])
            && target[key] && typeof target[key] === 'object' && !Array.isArray(target[key])) {
          deepMerge(target[key], source[key]);
        } else {
          target[key] = source[key];
        }
      }
      return target;
    };
    const existing = JSON.parse(fs.readFileSync('$target', 'utf8'));
    const incoming = JSON.parse(fs.readFileSync('$source', 'utf8'));
    const merged = deepMerge(existing, incoming);
    fs.writeFileSync('$target', JSON.stringify(merged, null, 2) + '\n');
  "
}

# ── Helper: append-merge JSON (only adds new keys, never overwrites) ──
# Used by normal runs — repo can add new skills/plugins/agents but can't
# overwrite anything the user changed at runtime
# Arrays of objects with 'id' fields: new ids are appended, existing ids are skipped
append_merge_json() {
  local target="$1"
  local source="$2"
  node -e "
    const fs = require('fs');
    const appendMerge = (target, source) => {
      for (const key of Object.keys(source)) {
        if (!(key in target)) {
          target[key] = source[key];
        } else if (Array.isArray(source[key]) && Array.isArray(target[key])) {
          // Append items with new ids; no-id items merge positionally (append-only)
          for (let i = 0; i < source[key].length; i++) {
            const srcItem = source[key][i];
            if (srcItem && typeof srcItem === 'object' && !Array.isArray(srcItem)) {
              if (srcItem.id) {
                if (!target[key].some(t => t && t.id === srcItem.id)) {
                  target[key].push(srcItem);
                }
              } else if (i < target[key].length && target[key][i] && typeof target[key][i] === 'object') {
                // No id — append-merge positionally
                appendMerge(target[key][i], srcItem);
              } else {
                target[key].push(srcItem);
              }
            } else if (!target[key].includes(srcItem)) {
              target[key].push(srcItem);
            }
          }
        } else if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key])
            && target[key] && typeof target[key] === 'object' && !Array.isArray(target[key])) {
          appendMerge(target[key], source[key]);
        }
        // Key exists and is not a nested object/array — skip
      };
      return target;
    };
    const existing = JSON.parse(fs.readFileSync('$target', 'utf8'));
    const incoming = JSON.parse(fs.readFileSync('$source', 'utf8'));
    const merged = appendMerge(existing, incoming);
    fs.writeFileSync('$target', JSON.stringify(merged, null, 2) + '\n');
  "
}

# ── Helper: overlay files without overwriting existing ones ───────────
# Used by normal runs — only copies files that don't already exist at dst
overlay_dir_no_clobber() {
  local src="$1"
  local dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    # cp -a --no-clobber copies everything but skips files that already exist
    cp -a --no-clobber "$src/." "$dst/"
  fi
}

# ── Helper: overlay files, overwriting on conflict ────────────────────
# Used by first run and SYNC_MODE — repo wins on name conflicts
overlay_dir_force() {
  local src="$1"
  local dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    cp -a "$src/." "$dst/"
  fi
}

# ── First run: seed base config from image, then layer repo on top ────
if [ ! -f /data/openclaw/.openclaw/flag.json ]; then
  echo "First run detected — seeding base config + repo..."

  # Start with the full base config baked into the image
  cp /tmp/base-openclaw.json /data/openclaw/.openclaw/openclaw.json
  cp /tmp/base-openclaw.json /root/.openclaw/openclaw.json
  echo "  Copied base openclaw.json from image"

  # Then deep-merge the repo's minimal openclaw.json on top (repo values win)
  if [ -f "$REPO_OPENCLAW/openclaw.json" ]; then
    for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
      deep_merge_json "$cfg" "$REPO_OPENCLAW/openclaw.json"
    done
    echo "  Merged repo openclaw.json overrides on top"
  fi

  # Workspace + plugins: straight copy from repo
  overlay_dir_force "$REPO_OPENCLAW/workspace" /data/openclaw/.openclaw/workspace
  overlay_dir_force "$REPO_OPENCLAW/workspace" /root/.openclaw/workspace
  overlay_dir_force "$REPO_OPENCLAW/plugins" /data/openclaw/.openclaw/plugins

  touch /data/openclaw/.openclaw/flag.json
  echo "First run seeding complete"

# ── Sync mode: force-refresh from repo (repo wins on conflict) ───────
elif [ "$SYNC_MODE" = "true" ]; then
  echo "Sync mode: force-refreshing from repo..."

  # Config: deep merge (repo values win, but runtime-only keys are preserved)
  if [ -f "$REPO_OPENCLAW/openclaw.json" ]; then
    for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
      if [ -f "$cfg" ]; then
        deep_merge_json "$cfg" "$REPO_OPENCLAW/openclaw.json"
      fi
    done
    echo "  Merged openclaw.json (repo wins on conflict)"
  fi

  # Workspace + plugins: force overlay (repo wins on conflict)
  overlay_dir_force "$REPO_OPENCLAW/workspace" /data/openclaw/.openclaw/workspace
  overlay_dir_force "$REPO_OPENCLAW/workspace" /root/.openclaw/workspace
  overlay_dir_force "$REPO_OPENCLAW/plugins" /data/openclaw/.openclaw/plugins
  echo "  Overlaid workspace + plugins (repo wins on conflict)"

  echo "Sync complete"

# ── Normal run: append-only merge (never overwrites runtime changes) ──
else
  echo "Merging new items from repo (preserving all runtime changes)..."

  # Config: append-merge (only adds new keys, never overwrites existing)
  if [ -f "$REPO_OPENCLAW/openclaw.json" ]; then
    for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
      if [ -f "$cfg" ]; then
        append_merge_json "$cfg" "$REPO_OPENCLAW/openclaw.json"
      fi
    done
    echo "  Append-merged openclaw.json (new keys only)"
  fi

  # Workspace + plugins: no-clobber overlay (only copies files that don't exist yet)
  overlay_dir_no_clobber "$REPO_OPENCLAW/workspace" /data/openclaw/.openclaw/workspace
  overlay_dir_no_clobber "$REPO_OPENCLAW/workspace" /root/.openclaw/workspace
  overlay_dir_no_clobber "$REPO_OPENCLAW/plugins" /data/openclaw/.openclaw/plugins
  echo "  Overlaid workspace + plugins (new files only)"

  echo "Merge complete"
fi

# ── Clean up repo to avoid duplicate skills/plugins confusing the agent ──
echo "Removing cloned repo (already merged into .openclaw)..."
rm -rf "$WORKSPACE_REPO_DIR"

# ── Runtime patches (env var overrides) ──────────────────────────────

# Always enable gateway control UI access
for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
  if [ -f "$cfg" ]; then
    node -e "
      const fs = require('fs');
      const cfg = JSON.parse(fs.readFileSync('$cfg', 'utf8'));
      cfg.gateway = cfg.gateway || {};
      cfg.gateway.controlUi = cfg.gateway.controlUi || {};
      cfg.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
      cfg.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;
      fs.writeFileSync('$cfg', JSON.stringify(cfg, null, 2) + '\n');
    "
  fi
done

# Patch allowedOrigins if ALLOWED_ORIGINS is set (comma-separated)
if [ -n "$ALLOWED_ORIGINS" ]; then
  ORIGINS_JSON=$(echo "$ALLOWED_ORIGINS" | sed 's/,/","/g' | sed 's/^/["/' | sed 's/$/"]/')
  for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
    if [ -f "$cfg" ]; then
      node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('$cfg', 'utf8'));
        cfg.gateway = cfg.gateway || {};
        cfg.gateway.controlUi = cfg.gateway.controlUi || {};
        cfg.gateway.controlUi.allowedOrigins = $ORIGINS_JSON;
        fs.writeFileSync('$cfg', JSON.stringify(cfg, null, 2) + '\n');
      "
    fi
  done
  echo "Patched allowedOrigins: $ALLOWED_ORIGINS"
fi

# Patch gateway auth token if GATEWAY_TOKEN is set
if [ -n "$GATEWAY_TOKEN" ]; then
  for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
    if [ -f "$cfg" ]; then
      node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('$cfg', 'utf8'));
        cfg.gateway = cfg.gateway || {};
        cfg.gateway.auth = cfg.gateway.auth || {};
        cfg.gateway.auth.token = '$GATEWAY_TOKEN';
        fs.writeFileSync('$cfg', JSON.stringify(cfg, null, 2) + '\n');
      "
    fi
  done
  echo "Patched gateway auth token"
fi

# Patch outline_tools plugin config if OUTLINE_URL and OUTLINE_TOKEN are set
if [ -n "$OUTLINE_URL" ] && [ -n "$OUTLINE_TOKEN" ]; then
  for cfg in /data/openclaw/.openclaw/openclaw.json /root/.openclaw/openclaw.json; do
    if [ -f "$cfg" ]; then
      node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync('$cfg', 'utf8'));
        cfg.plugins = cfg.plugins || {};
        cfg.plugins.entries = cfg.plugins.entries || {};
        cfg.plugins.entries.outline_tools = cfg.plugins.entries.outline_tools || {};
        cfg.plugins.entries.outline_tools.enabled = true;
        cfg.plugins.entries.outline_tools.config = cfg.plugins.entries.outline_tools.config || {};
        cfg.plugins.entries.outline_tools.config.baseUrl = '$OUTLINE_URL';
        cfg.plugins.entries.outline_tools.config.apiToken = '$OUTLINE_TOKEN';
        cfg.plugins.entries.outline_tools.config.rootDoc = '${OUTLINE_ROOT_DOC:-}';
        fs.writeFileSync('$cfg', JSON.stringify(cfg, null, 2) + '\n');
      "
    fi
  done
  echo "Patched outline_tools plugin config (baseUrl, apiToken, rootDoc)"
fi

# ── Launch ───────────────────────────────────────────────────────────
chmod 700 /data/openclaw/.openclaw

exec openclaw gateway run --bind lan --port 3000
