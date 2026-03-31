#!/usr/bin/env bash
set -e

export COREPACK_ENABLE_STRICT=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

WORKSPACE="${1:?Error: containerWorkspaceFolder not provided as argument}"

echo "=================================="

mkdir -p ~/.claude
cp /agentic-central/claude.json ~/.claude.json 2>/dev/null || true
cp /agentic-central/claude.home.settings.json ~/.claude/settings.json 2>/dev/null || true
ln -sfn /agentic-central/commands ~/.claude/commands
ln -sfn /agentic-central/skills ~/.claude/skills

echo "Setting up environment..."
for rc in ~/.bashrc ~/.profile; do
    grep -q "source /agentic-central/.env" "$rc" 2>/dev/null || \
        echo 'set -a; source /agentic-central/.env 2>/dev/null || true; set +a' >> "$rc"
    grep -q "CLAUDE_TRUST_PROMPT" "$rc" 2>/dev/null || \
        echo 'export CLAUDE_TRUST_PROMPT=true' >> "$rc"
done

echo "Mount screenshot folder"
if [ -n "${WORKSPACE}" ]; then
    ln -sfn /screenshots "${WORKSPACE}/.screenshots"
else
    echo "WARNING: WORKSPACE not set, skipping .screenshots symlink"
fi