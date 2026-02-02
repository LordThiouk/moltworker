#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/skills/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"
    
    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi
    
    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi
    
    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)
    
    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"
    
    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        # Copy the sync timestamp to local so we know what version we have
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore workspace (USER.md, MEMORY.md, skills, etc.) from R2 if available
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/clawd" ] && [ "$(ls -A $BACKUP_DIR/clawd 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring workspace from $BACKUP_DIR/clawd (USER.md, MEMORY.md, skills, etc.)..."
        mkdir -p "$WORKSPACE_DIR"
        cp -a "$BACKUP_DIR/clawd/." "$WORKSPACE_DIR/"
        echo "Restored workspace from R2 backup"
    fi
elif [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    # Legacy: restore skills only if no full workspace backup
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    config.channels.telegram.dm = config.channels.telegram.dm || {};
    config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Base URL override (e.g., for Cloudflare AI Gateway)
// You can configure OpenRouter AND Anthropic at the same time; both providers will be available in the Control UI.
const gatewayBaseUrl = (process.env.AI_GATEWAY_BASE_URL || '').replace(/\/+$/, '');
const anthropicBaseUrl = (process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenRouter = gatewayBaseUrl.endsWith('/openrouter') || gatewayBaseUrl.includes('openrouter.ai');
const isOpenAI = gatewayBaseUrl.endsWith('/openai');
const isAnthropicGateway = gatewayBaseUrl.endsWith('/anthropic');
config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.agents.defaults.models = config.agents.defaults.models || {};
let hasOpenRouter = false;
let hasOpenAI = false;
let hasAnthropic = false;

// 1) OpenRouter via AI Gateway or direct (optional)
if (isOpenRouter) {
    console.log('Configuring OpenRouter provider:', gatewayBaseUrl.includes('openrouter.ai') ? 'direct' : 'AI Gateway', gatewayBaseUrl);
    const openrouterConfig = {
        baseUrl: gatewayBaseUrl,
        api: 'openai-responses',
        models: [
            { id: 'openrouter/auto', name: 'Auto (OpenRouter)', contextWindow: 200000 },
            { id: 'moonshotai/kimi-k2-0905', name: 'Kimi K2', contextWindow: 131072 },
            { id: 'moonshotai/kimi-k2', name: 'Kimi K2 (alt)', contextWindow: 131072 },
            { id: 'google/gemini-3-pro-preview', name: 'Gemini 3 Pro', contextWindow: 1048576 },
            { id: 'google/gemini-3-flash-preview', name: 'Gemini 3 Flash', contextWindow: 1048576 },
            { id: 'openai/gpt-4o', name: 'GPT-4o', contextWindow: 128000 },
            { id: 'openai/gpt-4o-mini', name: 'GPT-4o mini', contextWindow: 128000 },
            { id: 'anthropic/claude-3.5-sonnet', name: 'Claude 3.5 Sonnet', contextWindow: 200000 },
            { id: 'anthropic/claude-3-haiku', name: 'Claude 3 Haiku', contextWindow: 200000 },
        ]
    };
    if (process.env.AI_GATEWAY_API_KEY || process.env.OPENAI_API_KEY) {
        openrouterConfig.apiKey = process.env.AI_GATEWAY_API_KEY || process.env.OPENAI_API_KEY;
    }
    config.models.providers.openai = openrouterConfig;
    config.agents.defaults.models['openai/openrouter/auto'] = { alias: 'Auto' };
    config.agents.defaults.models['openai/moonshotai/kimi-k2-0905'] = { alias: 'Kimi K2' };
    config.agents.defaults.models['openai/google/gemini-3-pro-preview'] = { alias: 'Gemini 3 Pro' };
    config.agents.defaults.models['openai/google/gemini-3-flash-preview'] = { alias: 'Gemini 3 Flash' };
    config.agents.defaults.models['openai/openai/gpt-4o'] = { alias: 'GPT-4o' };
    config.agents.defaults.models['openai/anthropic/claude-3.5-sonnet'] = { alias: 'Claude 3.5 Sonnet' };
    hasOpenRouter = true;
}

// 2) OpenAI via AI Gateway (optional)
if (isOpenAI) {
    console.log('Configuring OpenAI provider with base URL:', gatewayBaseUrl);
    config.models.providers.openai = {
        baseUrl: gatewayBaseUrl,
        api: 'openai-responses',
        models: [
            { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
            { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
            { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
        ]
    };
    config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
    config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
    config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
    hasOpenAI = true;
}

// 3) Anthropic: direct API key and/or AI Gateway anthropic (can be used together with OpenRouter)
if (process.env.ANTHROPIC_API_KEY || isAnthropicGateway) {
    const anthropicBase = isAnthropicGateway ? gatewayBaseUrl : anthropicBaseUrl;
    console.log('Configuring Anthropic provider:', anthropicBase || 'default');
    const providerConfig = {
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };
    if (anthropicBase) providerConfig.baseUrl = anthropicBase;
    if (process.env.ANTHROPIC_API_KEY) providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    config.models.providers.anthropic = providerConfig;
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
    config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
    hasAnthropic = true;
}

// Primary model: keep existing choice from R2 if present, otherwise set default
const existingPrimary = config.agents.defaults.model?.primary;
if (!existingPrimary || typeof existingPrimary !== 'string') {
    if (hasOpenRouter) {
        config.agents.defaults.model.primary = 'openai/moonshotai/kimi-k2-0905';
    } else if (hasAnthropic) {
        config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
    } else if (hasOpenAI) {
        config.agents.defaults.model.primary = 'openai/gpt-5.2';
    } else {
        config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
    }
} else {
    console.log('Keeping existing model from config/R2:', existingPrimary);
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
