#!/usr/bin/env bash
# skills.sh — Install DocMate MCP server + skills for AI agent CLIs
# Usage: ./skills.sh [--agent claude|gemini|codex] [--target <path>] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Options
AGENTS=()
TARGET="$HOME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
  cat <<EOF
${BOLD}Usage:${NC} skills.sh [OPTIONS]

Install DocMate MCP server and skills for AI agent CLIs.

${BOLD}OPTIONS:${NC}
  --agent <name>     Install for a specific agent: claude, gemini, codex
                     Can be specified multiple times
  --target <path>    Install to a specific directory instead of HOME (~)
  --help             Show this help message

${BOLD}SUPPORTED AGENTS:${NC}
  claude  →  ~/.claude/skills/  +  MCP registered via claude mcp add
  gemini  →  ~/.gemini/skills/
  codex   →  ~/.codex/skills/

${BOLD}EXAMPLES:${NC}
  ./skills.sh                              # All detected agents, global
  ./skills.sh --agent claude               # Claude only, global
  ./skills.sh --agent claude --agent gemini
  ./skills.sh --target ./my-project        # Install into a specific project
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      AGENTS+=("$2")
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ── Agent detection ───────────────────────────────────────────────────────────
detect_agents() {
  local detected=()
  command -v claude &>/dev/null && detected+=("claude")
  command -v gemini &>/dev/null && detected+=("gemini")
  command -v codex  &>/dev/null && detected+=("codex")
  echo "${detected[*]:-}"
}

# ── Path resolution ───────────────────────────────────────────────────────────
get_source_dir() {
  case "$1" in
    claude) echo "$SCRIPT_DIR/.claude/skills" ;;
    gemini) echo "$SCRIPT_DIR/.gemini/skills" ;;
    codex)  echo "$SCRIPT_DIR/.codex/skills"  ;;
  esac
}

get_dest_dir() {
  case "$1" in
    claude) echo "$TARGET/.claude/skills" ;;
    gemini) echo "$TARGET/.gemini/skills" ;;
    codex)  echo "$TARGET/.codex/skills"  ;;
  esac
}

# ── Step 1: Install npm package ───────────────────────────────────────────────
echo -e "${BOLD}[1/3] Installing document-agent-mcp from npm...${NC}"
if npm install -g document-agent-mcp; then
  echo -e "  ${GREEN}✔${NC} document-agent-mcp installed"
else
  echo -e "  ${RED}✗ npm install failed. Is Node.js installed?${NC}"
  exit 1
fi
echo ""

# ── Step 2: Collect credentials ───────────────────────────────────────────────
echo -e "${BOLD}[2/3] DocMate configuration${NC}"

# API Key (required)
while true; do
  read -rp "  DOCMATE_API_KEY (required): " DOCMATE_API_KEY
  if [[ -n "$DOCMATE_API_KEY" ]]; then
    break
  fi
  echo -e "  ${RED}API key cannot be empty.${NC}"
done

# Backend URL (optional, with default)
read -rp "  DOCUMENT_AGENT_API_BASE_URL [http://127.0.0.1:8000]: " BACKEND_URL
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8000}"

echo ""

# ── Resolve agent list ────────────────────────────────────────────────────────
if [[ ${#AGENTS[@]} -eq 0 ]]; then
  echo -e "${BOLD}Detecting installed agents...${NC}"
  read -ra AGENTS <<< "$(detect_agents)"

  if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No supported agents detected (claude, gemini, codex).${NC}"
    echo "Specify one manually:  ./skills.sh --agent claude"
    exit 0
  fi

  echo -e "Detected: ${BOLD}${AGENTS[*]}${NC}"
fi

echo ""

# ── Step 3: Install skills + MCP config per agent ────────────────────────────
echo -e "${BOLD}[3/3] Installing skills and MCP configuration...${NC}"
echo ""

FAILED=()

# ── Install skills for one agent ──────────────────────────────────────────────
install_skills_for_agent() {
  local agent="$1"
  local src dest count=0

  src="$(get_source_dir "$agent")"
  dest="$(get_dest_dir "$agent")"

  if [[ ! -d "$src" ]]; then
    echo -e "  ${YELLOW}⚠ Source skills not found: $src${NC}"
    return 1
  fi

  mkdir -p "$dest"

  for skill_dir in "$src"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    cp -r "$skill_dir" "$dest/"
    echo -e "  ${GREEN}✔${NC} skill: $skill_name"
    ((count++))
  done

  echo -e "  ${BLUE}→${NC} $count skill(s) installed to ${BOLD}$dest${NC}"
}

# ── Configure MCP for Claude ──────────────────────────────────────────────────
configure_mcp_claude() {
  if command -v claude &>/dev/null; then
    # Remove existing entry if present, then re-add
    claude mcp remove docmate --scope user 2>/dev/null || true
    if claude mcp add --scope user docmate \
        -e DOCMATE_API_KEY="$DOCMATE_API_KEY" \
        -e DOCUMENT_AGENT_API_BASE_URL="$BACKEND_URL" \
        -- document-agent-mcp; then
      echo -e "  ${GREEN}✔${NC} MCP server registered (user scope)"
    else
      echo -e "  ${YELLOW}⚠ claude mcp add failed, falling back to ~/.claude/.mcp.json${NC}"
      configure_mcp_json "$HOME/.claude/.mcp.json"
    fi
  else
    configure_mcp_json "$HOME/.claude/.mcp.json"
  fi
}

# ── Write .mcp.json (fallback or for non-claude agents) ──────────────────────
configure_mcp_json() {
  local path="$1"
  mkdir -p "$(dirname "$path")"

  # Merge into existing file if present, else create fresh
  if [[ -f "$path" ]]; then
    # Use node to safely merge JSON
    node - "$path" "$DOCMATE_API_KEY" "$BACKEND_URL" <<'JSEOF'
const fs = require('fs');
const [,, file, apiKey, backendUrl] = process.argv;
const config = JSON.parse(fs.readFileSync(file, 'utf8'));
config.mcpServers = config.mcpServers || {};
config.mcpServers.docmate = {
  command: 'document-agent-mcp',
  env: { DOCMATE_API_KEY: apiKey, DOCUMENT_AGENT_API_BASE_URL: backendUrl }
};
fs.writeFileSync(file, JSON.stringify(config, null, 2) + '\n');
JSEOF
    echo -e "  ${GREEN}✔${NC} MCP config merged into ${BOLD}$path${NC}"
  else
    cat > "$path" <<EOF
{
  "mcpServers": {
    "docmate": {
      "command": "document-agent-mcp",
      "env": {
        "DOCMATE_API_KEY": "$DOCMATE_API_KEY",
        "DOCUMENT_AGENT_API_BASE_URL": "$BACKEND_URL"
      }
    }
  }
}
EOF
    echo -e "  ${GREEN}✔${NC} MCP config created at ${BOLD}$path${NC}"
  fi
}

for agent in "${AGENTS[@]}"; do
  echo -e "${BLUE}[${agent}]${NC}"

  case "$agent" in
    claude)
      install_skills_for_agent "claude" || FAILED+=("claude-skills")
      configure_mcp_claude
      ;;
    gemini)
      install_skills_for_agent "gemini" || FAILED+=("gemini-skills")
      configure_mcp_json "$TARGET/.gemini/.mcp.json"
      ;;
    codex)
      install_skills_for_agent "codex" || FAILED+=("codex-skills")
      configure_mcp_json "$TARGET/.codex/.mcp.json"
      ;;
  esac

  echo ""
done

# ── Result ────────────────────────────────────────────────────────────────────
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Some steps failed: ${FAILED[*]}${NC}"
fi

echo -e "${GREEN}${BOLD}Done!${NC} DocMate is ready."
echo ""
echo -e "  Start your agent and run ${BOLD}/mcp${NC} to verify the ${BOLD}docmate${NC} server is connected."
