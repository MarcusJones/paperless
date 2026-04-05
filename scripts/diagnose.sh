#!/usr/bin/env bash
# scripts/diagnose.sh — verify every stage of the AI tagging pipeline
#
# Run from the repo root on the WSL host (not inside the dev container):
#   ./scripts/diagnose.sh
#
# Checks:
#  1. Ollama reachable from host
#  2. Both models (qwen3:14b + qwen3-vl:8b) present
#  3. Ollama reachable from paperless-gpt container
#  4. Ollama reachable from paperless-ai-next container
#  5. Paperless-ngx API up and token valid
#  6. paperless-gpt can reach Paperless-ngx API
#  7. paperless-ai-next can reach Paperless-ngx API
#  8. paperless-ai-next health endpoint
#  9. Pipeline tags exist in Paperless-ngx
# 10. LLM generation smoke test
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load root .env for secrets
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run from the repo root."
  exit 1
fi
# shellcheck source=../.env
source "$ENV_FILE"

# Config (mirrors compose.yaml and service .envs)
PAPERLESS_PORT=8000
AI_PORT=3000
CLASSIFICATION_MODEL="qwen3:14b"
VISION_MODEL="qwen3-vl:8b"

PASS=0; FAIL=0; SKIP=0
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
_skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
_info() { echo -e "         $1"; }

echo "=== Paperless-ngx Pipeline Diagnostics ==="
echo ""

# ── Check 1: Ollama on host ──────────────────────────────────────────────────
echo "[1] Ollama reachable from host (localhost:11434)"
if curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
  _pass "Ollama is up at http://localhost:11434"
else
  _fail "Ollama NOT reachable. Run:"
  _info "nohup env OLLAMA_HOST=0.0.0.0 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_KEEP_ALIVE=30m ollama serve &>/dev/null &"
fi
echo ""

# ── Check 2: Models present ──────────────────────────────────────────────────
echo "[2] Models present: ${CLASSIFICATION_MODEL} + ${VISION_MODEL}"
if ollama list 2>/dev/null | grep -q "^${CLASSIFICATION_MODEL}"; then
  _pass "${CLASSIFICATION_MODEL} present"
else
  _fail "${CLASSIFICATION_MODEL} NOT found. Pull via Open WebUI (http://localhost:3001) or: ollama pull ${CLASSIFICATION_MODEL}"
fi
if ollama list 2>/dev/null | grep -q "^${VISION_MODEL}"; then
  _pass "${VISION_MODEL} present"
else
  _fail "${VISION_MODEL} NOT found. Pull via Open WebUI (http://localhost:3001) or: ollama pull ${VISION_MODEL}"
fi
echo ""

# ── Check 3: Ollama from paperless-gpt ──────────────────────────────────────
echo "[3] Ollama reachable from paperless-gpt container (host.docker.internal)"
if docker compose -f "$REPO_ROOT/compose.yaml" ps paperless-gpt --status running 2>/dev/null | grep -q "paperless-gpt"; then
  result=$(docker compose -f "$REPO_ROOT/compose.yaml" exec -T paperless-gpt \
    curl -sf --max-time 5 http://host.docker.internal:11434/api/tags 2>/dev/null && echo "ok" || echo "fail")
  if [[ "$result" == "ok" ]]; then
    _pass "paperless-gpt can reach Ollama"
  else
    _fail "paperless-gpt CANNOT reach Ollama at host.docker.internal:11434"
    _info "Check extra_hosts in compose.yaml; verify Ollama binds 0.0.0.0 (not 127.0.0.1)"
  fi
else
  _skip "paperless-gpt container not running"
fi
echo ""

# ── Check 4: Ollama from paperless-ai-next ───────────────────────────────────
echo "[4] Ollama reachable from paperless-ai-next container (host.docker.internal)"
if docker compose -f "$REPO_ROOT/compose.yaml" ps paperless-ai-next --status running 2>/dev/null | grep -q "paperless-ai-next"; then
  result=$(docker compose -f "$REPO_ROOT/compose.yaml" exec -T paperless-ai-next \
    curl -sf --max-time 5 http://host.docker.internal:11434/api/tags 2>/dev/null && echo "ok" || echo "fail")
  if [[ "$result" == "ok" ]]; then
    _pass "paperless-ai-next can reach Ollama"
  else
    _fail "paperless-ai-next CANNOT reach Ollama at host.docker.internal:11434"
  fi
else
  _skip "paperless-ai-next container not running"
fi
echo ""

# ── Check 5: Paperless API ────────────────────────────────────────────────────
echo "[5] Paperless-ngx API reachable and token valid (localhost:${PAPERLESS_PORT})"
http_code=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
  "http://localhost:${PAPERLESS_PORT}/api/tags/" \
  -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "000")
if [[ "$http_code" == "200" ]]; then
  _pass "API is up and token is valid (HTTP 200)"
elif [[ "$http_code" == "403" ]]; then
  _fail "API reachable but token INVALID (HTTP 403). Update PAPERLESS_API_TOKEN in .env"
elif [[ "$http_code" == "000" ]]; then
  _fail "API NOT reachable at localhost:${PAPERLESS_PORT}. Is the stack up? Run: docker compose ps"
else
  _fail "Unexpected HTTP ${http_code} from API"
fi
echo ""

# ── Check 6: paperless-gpt → Paperless API ───────────────────────────────────
echo "[6] paperless-gpt can reach Paperless-ngx API"
if docker compose -f "$REPO_ROOT/compose.yaml" ps paperless-gpt --status running 2>/dev/null | grep -q "paperless-gpt"; then
  result=$(docker compose -f "$REPO_ROOT/compose.yaml" exec -T paperless-gpt \
    curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    http://paperless:8000/api/tags/ \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "000")
  if [[ "$result" == "200" ]]; then
    _pass "paperless-gpt → Paperless API (HTTP 200)"
  else
    _fail "paperless-gpt got HTTP ${result} from Paperless. Check token + compose network."
  fi
else
  _skip "paperless-gpt container not running"
fi
echo ""

# ── Check 7: paperless-ai-next → Paperless API ───────────────────────────────
echo "[7] paperless-ai-next can reach Paperless-ngx API"
if docker compose -f "$REPO_ROOT/compose.yaml" ps paperless-ai-next --status running 2>/dev/null | grep -q "paperless-ai-next"; then
  result=$(docker compose -f "$REPO_ROOT/compose.yaml" exec -T paperless-ai-next \
    curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    http://paperless:8000/api/tags/ \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "000")
  if [[ "$result" == "200" ]]; then
    _pass "paperless-ai-next → Paperless API (HTTP 200)"
  else
    _fail "paperless-ai-next got HTTP ${result} from Paperless. Check token + network."
  fi
else
  _skip "paperless-ai-next container not running"
fi
echo ""

# ── Check 8: paperless-ai-next health ────────────────────────────────────────
echo "[8] paperless-ai-next health endpoint (localhost:${AI_PORT}/health)"
if docker compose -f "$REPO_ROOT/compose.yaml" ps paperless-ai-next --status running 2>/dev/null | grep -q "paperless-ai-next"; then
  health=$(curl -sf --max-time 5 "http://localhost:${AI_PORT}/health" 2>/dev/null || echo "unreachable")
  if echo "$health" | grep -qi "ok\|healthy\|true"; then
    _pass "paperless-ai-next health: ${health}"
  else
    _fail "Health check failed: ${health}"
    _info "Setup wizard completed? Visit: http://localhost:${AI_PORT}/setup"
  fi
else
  _skip "paperless-ai-next container not running"
fi
echo ""

# ── Check 9: Pipeline tags ────────────────────────────────────────────────────
echo "[9] Pipeline tags exist in Paperless-ngx"
PIPELINE_TAGS=("paperless-gpt-ocr-auto" "ai-process" "ai-processed")
if [[ "$http_code" == "200" ]]; then
  tags_json=$(curl -sf --max-time 10 \
    "http://localhost:${PAPERLESS_PORT}/api/tags/?page_size=200" \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "{}")
  for tag in "${PIPELINE_TAGS[@]}"; do
    if echo "$tags_json" | grep -q "\"name\":\"${tag}\""; then
      _pass "Tag exists: ${tag}"
    else
      _fail "Tag MISSING: ${tag} — run: ./scripts/bootstrap.sh"
    fi
  done
else
  _skip "Cannot check tags — Paperless API not reachable (see check 5)"
fi
echo ""

# ── Check 10: LLM smoke test ──────────────────────────────────────────────────
echo "[10] LLM generation smoke test (${CLASSIFICATION_MODEL})"
if curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
  response=$(curl -sf --max-time 60 http://localhost:11434/api/generate \
    -d "{\"model\":\"${CLASSIFICATION_MODEL}\",\"prompt\":\"Reply with one word: hello\",\"stream\":false}" \
    2>/dev/null || echo "")
  if echo "$response" | grep -q '"response"'; then
    _pass "${CLASSIFICATION_MODEL} generated a response"
  else
    _fail "${CLASSIFICATION_MODEL} did not respond. Model loaded? curl -s http://localhost:11434/api/ps"
  fi
else
  _skip "Ollama not reachable (see check 1)"
fi
echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
echo "==========================================="
echo -e "Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Fix failures above before testing end-to-end."
  exit 1
else
  echo ""
  echo -e "${GREEN}All checks passed. Pipeline is ready.${NC}"
fi
