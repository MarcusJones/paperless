#!/usr/bin/env bash
set -e

export COREPACK_ENABLE_STRICT=0
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0

WORKSPACE="${1:?Error: containerWorkspaceFolder not provided as argument}"

echo "=================================="

echo "Copying /agentic-central → .claude/ ..."
mkdir -p .claude ~/.claude
sudo chown -R "$(id -u):$(id -g)" .claude/
rsync -a --exclude='.git' /agentic-central/ .claude/
cp /agentic-central/settings.json ~/.claude/settings.json
cp /agentic-central/claude.json ~/.claude.json

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