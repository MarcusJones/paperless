#!/usr/bin/env bash
# diagnose.sh — verify every stage of the AI tagging pipeline
#
# Run on the WSL host (not inside the dev container).
# Checks all 10 pipeline prerequisites and reports pass/fail.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=0
FAIL=0
SKIP=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
_skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; ((SKIP++)); }
_info() { echo -e "         $1"; }

echo "=== Paperless-ngx Pipeline Diagnostics ==="
echo ""

# ── Check 1: Ollama reachable from host ──────────────────────────────────────
echo "[1] Ollama reachable from host (localhost:11434)"
if curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
  _pass "Ollama is up at http://localhost:11434"
else
  _fail "Ollama is NOT reachable. Run: nohup env OLLAMA_HOST=0.0.0.0 OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_KEEP_ALIVE=30m ollama serve &>/dev/null &"
fi
echo ""

# ── Check 2: Both models present ─────────────────────────────────────────────
echo "[2] Models present: ${OLLAMA_MODEL} + ${OLLAMA_VISION_MODEL}"
if ollama list 2>/dev/null | grep -q "^${OLLAMA_MODEL}"; then
  _pass "${OLLAMA_MODEL} present"
else
  _fail "${OLLAMA_MODEL} NOT found. Run: ollama pull ${OLLAMA_MODEL}"
fi
if ollama list 2>/dev/null | grep -q "^${OLLAMA_VISION_MODEL}"; then
  _pass "${OLLAMA_VISION_MODEL} present"
else
  _fail "${OLLAMA_VISION_MODEL} NOT found. Run: ollama pull ${OLLAMA_VISION_MODEL}"
fi
echo ""

# ── Check 3: Ollama reachable from paperless-gpt container ───────────────────
echo "[3] Ollama reachable from paperless-gpt container (via host.docker.internal)"
if docker container inspect paperless-gpt &>/dev/null 2>&1; then
  result=$(docker exec paperless-gpt curl -sf --max-time 5 http://host.docker.internal:11434/api/tags 2>/dev/null && echo "ok" || echo "fail")
  if [[ "$result" == "ok" ]]; then
    _pass "paperless-gpt can reach Ollama"
  else
    _fail "paperless-gpt CANNOT reach Ollama at host.docker.internal:11434"
    _info "Check: docker exec paperless-gpt curl -s http://host.docker.internal:11434/api/tags"
  fi
else
  _skip "paperless-gpt container not running"
fi
echo ""

# ── Check 4: Ollama reachable from paperless-ai container ────────────────────
echo "[4] Ollama reachable from paperless-ai container (via 172.17.0.1)"
if docker container inspect paperless-ai &>/dev/null 2>&1; then
  result=$(docker exec paperless-ai curl -sf --max-time 5 http://172.17.0.1:11434/api/tags 2>/dev/null && echo "ok" || echo "fail")
  if [[ "$result" == "ok" ]]; then
    _pass "paperless-ai can reach Ollama"
  else
    _fail "paperless-ai CANNOT reach Ollama at 172.17.0.1:11434"
    _info "Check: docker exec paperless-ai curl -s http://172.17.0.1:11434/api/tags"
  fi
else
  _skip "paperless-ai container not running"
fi
echo ""

# ── Check 5: Paperless-ngx API up and token valid ────────────────────────────
echo "[5] Paperless-ngx API reachable and token valid (localhost:${PAPERLESS_PORT})"
http_code=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
  "http://localhost:${PAPERLESS_PORT}/api/tags/" \
  -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "000")
if [[ "$http_code" == "200" ]]; then
  _pass "API is up and token is valid (HTTP 200)"
elif [[ "$http_code" == "403" ]]; then
  _fail "API reachable but token is INVALID (HTTP 403). Update PAPERLESS_API_TOKEN in .env"
elif [[ "$http_code" == "000" ]]; then
  _fail "API NOT reachable at localhost:${PAPERLESS_PORT}. Is paperless container running?"
else
  _fail "Unexpected HTTP ${http_code} from API"
fi
echo ""

# ── Check 6: paperless-gpt can reach Paperless-ngx ──────────────────────────
echo "[6] paperless-gpt can reach Paperless-ngx API"
if docker container inspect paperless-gpt &>/dev/null 2>&1; then
  result=$(docker exec paperless-gpt curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    http://paperless:8000/api/tags/ \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "000")
  if [[ "$result" == "200" ]]; then
    _pass "paperless-gpt can reach Paperless-ngx API (HTTP 200)"
  else
    _fail "paperless-gpt got HTTP ${result} from Paperless-ngx. Check token and network."
  fi
else
  _skip "paperless-gpt container not running"
fi
echo ""

# ── Check 7: paperless-ai can reach Paperless-ngx ───────────────────────────
echo "[7] paperless-ai can reach Paperless-ngx API"
if docker container inspect paperless-ai &>/dev/null 2>&1; then
  result=$(docker exec paperless-ai curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
    http://paperless:8000/api/tags/ \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "000")
  if [[ "$result" == "200" ]]; then
    _pass "paperless-ai can reach Paperless-ngx API (HTTP 200)"
  else
    _fail "paperless-ai got HTTP ${result} from Paperless-ngx. Check token and network."
  fi
else
  _skip "paperless-ai container not running"
fi
echo ""

# ── Check 8: paperless-ai health endpoint ───────────────────────────────────
echo "[8] paperless-ai health endpoint (localhost:${AI_PORT}/health)"
if docker container inspect paperless-ai &>/dev/null 2>&1; then
  health=$(curl -sf --max-time 5 "http://localhost:${AI_PORT}/health" 2>/dev/null || echo "unreachable")
  if echo "$health" | grep -qi "ok\|healthy\|true"; then
    _pass "paperless-ai health: ${health}"
  else
    _fail "paperless-ai health check failed: ${health}"
    _info "Has the setup wizard been completed? http://localhost:${AI_PORT}/setup"
  fi
else
  _skip "paperless-ai container not running"
fi
echo ""

# ── Check 9: Pipeline tags exist in Paperless-ngx ───────────────────────────
echo "[9] Pipeline tags exist in Paperless-ngx"
PIPELINE_TAGS=("paperless-gpt-ocr-auto" "ocr-complete" "ai-process" "ai-processed")
all_tags_ok=true
if [[ "$http_code" == "200" ]]; then
  tags_response=$(curl -sf --max-time 10 \
    "http://localhost:${PAPERLESS_PORT}/api/tags/?page_size=200" \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" 2>/dev/null || echo "{}")
  for tag in "${PIPELINE_TAGS[@]}"; do
    if echo "$tags_response" | grep -q "\"name\":\"${tag}\""; then
      _pass "Tag exists: ${tag}"
    else
      _fail "Tag MISSING: ${tag} — run ./bootstrap.sh"
      all_tags_ok=false
    fi
  done
else
  _skip "Cannot check tags — Paperless API not reachable (see check 5)"
fi
echo ""

# ── Check 10: LLM generation smoke test ─────────────────────────────────────
echo "[10] LLM generation smoke test (${OLLAMA_MODEL})"
if curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
  response=$(curl -sf --max-time 30 http://localhost:11434/api/generate \
    -d "{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"Reply with one word: hello\",\"stream\":false}" \
    2>/dev/null || echo "")
  if echo "$response" | grep -q '"response"'; then
    _pass "${OLLAMA_MODEL} generated a response"
  else
    _fail "${OLLAMA_MODEL} did not respond. Is the model loaded? Check: curl -s http://localhost:11434/api/ps"
  fi
else
  _skip "Ollama not reachable (see check 1)"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "==========================================="
echo -e "Results: ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}"
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Fix failures above before testing the pipeline end-to-end."
  exit 1
else
  echo ""
  echo -e "${GREEN}All checks passed. Pipeline is ready.${NC}"
fi
