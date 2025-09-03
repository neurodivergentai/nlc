#!/usr/bin/env bash
# nlc.sh — Natural Language Compiler (conversation → seed repo for Claude Code), single script.
# v0.1 - 20250903
# Authors: neurodivergentai, ChatGPT, Claude
# MIT License
# 
# Copyright (c) 2025 neurodivergentai
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -euo pipefail

# ----------------------- Paths & settings -----------------------
NLC_HOME="${HOME}/.nlc"
NLC_CFG="${HOME}/.nlc_config"
NLC_WORK="${NLC_HOME}/work"
NLC_WHITEPAPER_FILE="${NLC_HOME}/WHITEPAPER.md"
mkdir -p "$NLC_HOME" "$NLC_WORK"
chmod 700 "$NLC_HOME" || true

# Defaults
NLC_PROVIDER_DEFAULT="anthropic"      # Default to Claude for conversation
NLC_MODEL_DEFAULT="claude-sonnet-4-20250514"
OPENAI_BASE_DEFAULT="https://api.openai.com/v1"
OPENAI_MODEL_DEFAULT="gpt-4o-mini"
AZURE_OPENAI_ENDPOINT_DEFAULT="https://YOUR-RESOURCE.openai.azure.com"
AZURE_MODEL_DEFAULT="gpt-4o-mini"
AZURE_OPENAI_API_VERSION_DEFAULT="2024-07-18-preview"
ANTHROPIC_BASE_DEFAULT="https://api.anthropic.com/v1"
ANTHROPIC_MODEL_DEFAULT="claude-sonnet-4-20250514"
GEMINI_BASE_DEFAULT="https://generativelanguage.googleapis.com/v1beta"
GEMINI_MODEL_DEFAULT="gemini-2.5-flash"
MISTRAL_BASE_DEFAULT="https://api.mistral.ai/v1"
MISTRAL_MODEL_DEFAULT="mistral-large-latest"
COHERE_BASE_DEFAULT="https://api.cohere.ai/v1/chat"
COHERE_MODEL_DEFAULT="command-r-plus"
OLLAMA_URL_DEFAULT="http://localhost:11434/api/chat"
OLLAMA_MODEL_DEFAULT="llama3.2"

# Sampling defaults (bytes)
NLC_SAMPLE_HEAD_BYTES=${NLC_SAMPLE_HEAD_BYTES:-16384}
NLC_SAMPLE_MID_BYTES=${NLC_SAMPLE_MID_BYTES:-16384}
NLC_SAMPLE_TAIL_BYTES=${NLC_SAMPLE_TAIL_BYTES:-16384}
NLC_SAMPLE_OVERLAP_BYTES=${NLC_SAMPLE_OVERLAP_BYTES:-2048}

# Token budgeting & pacing (rough; chars/4 ≈ tokens)
NLC_MAX_TOKENS=${NLC_MAX_TOKENS:-0}         # 0 = disabled
NLC_TOKENS_PER_MIN=${NLC_TOKENS_PER_MIN:-0} # 0 = disabled (no pacing)
NLC_RESPONSE_MAX_TOKENS=${NLC_RESPONSE_MAX_TOKENS:-16384} # max tokens for model responses

# Millisecond delay floor between calls (in addition to token pacing)
NLC_RATE_LIMIT_MS=${NLC_RATE_LIMIT_MS:-0}

# Token estimation (rough): chars/4 ≈ tokens (approximate)
estimate_tokens() {
    python3 - <<'PY' 2>/dev/null || awk '{c+=length($0)+1} END {printf "%d", (c/4)}'
import sys
text = sys.stdin.read()
try:
    import tiktoken
    enc = tiktoken.get_encoding("cl100k_base")
    print(len(enc.encode(text)))
except Exception:
    # Fallback if tiktoken missing or fails
    print(int(len(text) / 4))
PY
}

pause(){ read -rp "Press Enter to continue... " _; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "[NLC] Missing $1. $2" >&2; exit 1; }; }
has(){ command -v "$1" >/dev/null 2>&1; }
log(){ printf "[NLC] %s\n" "$*"; }
err(){ printf "[NLC][ERROR] %s\n" "$*" >&2; }

sleep_ms(){
  if has python3; then
    python3 - <<'PY' "$NLC_RATE_LIMIT_MS"
import sys, time
ms = int(sys.argv[1]) if len(sys.argv)>1 else 0
time.sleep(ms/1000.0)
PY
  elif has perl; then
    perl -e "select(undef, undef, undef, ${NLC_RATE_LIMIT_MS}/1000)"
  else
    sleep "$(( NLC_RATE_LIMIT_MS / 1000 ))"
  fi
}

# Pacing based on tokens/minute (rough)
sleep_for_tokens(){ # sleep_for_tokens <est_tokens>
  local toks="${1:-0}"
  if (( NLC_TOKENS_PER_MIN > 0 && toks > 0 )); then
    local secs=$(( toks * 60 / NLC_TOKENS_PER_MIN ))
    (( secs > 0 )) && sleep "$secs"
  fi
}

retry(){ # retry <max> <cmd...>
  local max="$1"; shift
  local n=1 d=1
  while true; do
    if "$@"; then return 0; fi
    if (( n >= max )); then return 1; fi
    sleep "$d"; n=$((n+1)); d=$((d*2)); (( d>16 )) && d=16
  done
}

json_get(){ jq -r "$1" 2>/dev/null; }

safe_write(){
  local root="$1" rel="$2" content="$3" execb="${4:-false}"
  local norm="${rel#./}"
  while [[ "$norm" == */./* ]]; do norm="${norm/\/.\//\/}"; done
  while [[ "$norm" == ../* ]]; do norm="${norm#../}"; done
  local candidate="${root}/${norm}"
  
  # Resolve absolute path robustly
  local root_abs cand_abs
  if command -v python3 >/dev/null 2>&1; then
    root_abs="$(python3 - "$root" 2>/dev/null <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
    cand_abs="$(python3 - "$candidate" 2>/dev/null <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  elif command -v realpath >/dev/null 2>&1; then
    root_abs="$(realpath "$root" 2>/dev/null || echo "")"
    cand_abs="$(realpath "$candidate" 2>/dev/null || echo "")"
  elif command -v readlink >/dev/null 2>&1; then
    root_abs="$(readlink -f "$root" 2>/dev/null || echo "")"
    cand_abs="$(readlink -f "$candidate" 2>/dev/null || echo "")"
  else
    root_abs="$root"; cand_abs="$candidate"
  fi
  
  if [[ -z "$cand_abs" || "${cand_abs}" != "$root_abs"* ]]; then
    err "Blocked unsafe path: $rel"; return 1
  fi
  
  mkdir -p "$(dirname "$cand_abs")"
  printf "%s" "$content" > "$cand_abs"
  [[ "$execb" == "true" ]] && chmod +x "$cand_abs"
  log "Wrote $cand_abs"
}

strip_md_fences(){
  sed -e '1s/^```json[[:space:]]*$//; 1s/^```[[:space:]]*$//' -e '$s/^[[:space:]]*```$//; $s/[[:space:]]*```$//'
}

fix_json_escaping(){
  # Fix common JSON escaping issues in shell script content
  sed -e 's/\$\([0-9]\)/\\\\$\1/g' \
      -e 's/\$\([A-Z_][A-Z0-9_]*\)/\\\\$\1/g' \
      -e 's/\$@/\\\\$@/g' \
      -e 's/\$\*/\\\\$*/g' \
      -e 's/\$#/\\\\$#/g' \
      -e 's/'"'"'/\\"/g' \
      -e 's/\\\\t/\\t/g'
}

# Safer truncation: trim to byte count then backtrack to last newline/space
truncate_to_boundary() {
    local in="$1" n="$2" out="$3"
    # Prefer Python for UTF-8 safe truncation
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$in" "$n" "$out" <<'PY' 2>/dev/null && return 0
import sys
path, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, 'rb') as f:
    data = f.read(n)
# Cut on valid UTF-8 boundary by decoding with ignore
text = data.decode('utf-8', 'ignore')
with open(out, 'wb') as w:
    w.write(text.encode('utf-8'))
PY
    fi
    
    # Fallback: bytes cut then backtrack to last newline or space
    head -c "$n" "$in" > "$out.tmp" 2>/dev/null || \
        dd if="$in" bs=1 count="$n" status=none of="$out.tmp" 2>/dev/null || \
        cp "$in" "$out.tmp"
    
    # Try to backtrack to last newline within the last 1024 bytes
    local pos
    pos="$(tail -c 1024 "$out.tmp" 2>/dev/null | awk 'BEGIN{off=-1}{for(i=1;i<=length($0);i++){if(substr($0,i,1)=="\n") off=i}} END{if(off>0) print off; else print ""}')" || true
    
    if [[ -n "$pos" ]]; then
        # compute absolute position: n - 1024 + pos (ensure non-negative)
        local abs=$(( n>1024 ? n-1024 : 0 ))
        abs=$(( abs + pos ))
        head -c "$abs" "$in" > "$out" 2>/dev/null || cp "$out.tmp" "$out"
    else
        sed -E 's/[[:space:]][^[:space:]]*$/ /' "$out.tmp" > "$out" || cp "$out.tmp" "$out"
    fi
    rm -f "$out.tmp"
}

# ----------------------- Config -----------------------
load_cfg(){
  [[ -f "$NLC_CFG" ]] && . "$NLC_CFG"
  : "${NLC_PROVIDER:=${NLC_PROVIDER_DEFAULT}}"
  
  # Set provider-specific model defaults
  case "${NLC_PROVIDER}" in
    openai) : "${NLC_MODEL:=${OPENAI_MODEL_DEFAULT}}" ;;
    azure) : "${NLC_MODEL:=${AZURE_MODEL_DEFAULT}}" ;;
    anthropic) : "${NLC_MODEL:=${ANTHROPIC_MODEL_DEFAULT}}" ;;
    gemini) : "${NLC_MODEL:=${GEMINI_MODEL_DEFAULT}}" ;;
    mistral) : "${NLC_MODEL:=${MISTRAL_MODEL_DEFAULT}}" ;;
    cohere) : "${NLC_MODEL:=${COHERE_MODEL_DEFAULT}}" ;;
    ollama) : "${NLC_MODEL:=${OLLAMA_MODEL_DEFAULT}}" ;;
    *) : "${NLC_MODEL:=${NLC_MODEL_DEFAULT}}" ;;
  esac
  : "${OPENAI_API_KEY:=}"
  : "${AZURE_OPENAI_API_KEY:=}"
  : "${AZURE_OPENAI_ENDPOINT:=${AZURE_OPENAI_ENDPOINT_DEFAULT}}"
  : "${AZURE_OPENAI_DEPLOYMENT:=}"
  : "${AZURE_OPENAI_API_VERSION:=${AZURE_OPENAI_API_VERSION_DEFAULT}}"
  : "${ANTHROPIC_API_KEY:=}"
  : "${GEMINI_API_KEY:=}"
  : "${MISTRAL_API_KEY:=}"
  : "${COHERE_API_KEY:=}"
  : "${OPENAI_BASE:=${OPENAI_BASE_DEFAULT}}"
  : "${ANTHROPIC_BASE:=${ANTHROPIC_BASE_DEFAULT}}"
  : "${GEMINI_BASE:=${GEMINI_BASE_DEFAULT}}"
  : "${MISTRAL_BASE:=${MISTRAL_BASE_DEFAULT}}"
  : "${COHERE_BASE:=${COHERE_BASE_DEFAULT}}"
  : "${OLLAMA_URL:=${OLLAMA_URL_DEFAULT}}"
  : "${NLC_SEND_FULL_DOCS:=false}"
  : "${NLC_TASK_COMMAND:=}"   # optional external task command (security: you control it)
  : "${NLC_MAX_TOKENS:=${NLC_MAX_TOKENS}}"
  : "${NLC_TOKENS_PER_MIN:=${NLC_TOKENS_PER_MIN}}"
  : "${NLC_RATE_LIMIT_MS:=${NLC_RATE_LIMIT_MS}}"
}

save_cfg(){
  umask 177
  cat > "$NLC_CFG" <<CFG
# NLC settings
NLC_PROVIDER="${NLC_PROVIDER}"
NLC_MODEL="${NLC_MODEL}"
OPENAI_API_KEY="${OPENAI_API_KEY}"
AZURE_OPENAI_API_KEY="${AZURE_OPENAI_API_KEY}"
AZURE_OPENAI_ENDPOINT="${AZURE_OPENAI_ENDPOINT}"
AZURE_OPENAI_DEPLOYMENT="${AZURE_OPENAI_DEPLOYMENT}"
AZURE_OPENAI_API_VERSION="${AZURE_OPENAI_API_VERSION}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
GEMINI_API_KEY="${GEMINI_API_KEY}"
MISTRAL_API_KEY="${MISTRAL_API_KEY}"
COHERE_API_KEY="${COHERE_API_KEY}"
OPENAI_BASE="${OPENAI_BASE}"
ANTHROPIC_BASE="${ANTHROPIC_BASE}"
GEMINI_BASE="${GEMINI_BASE}"
MISTRAL_BASE="${MISTRAL_BASE}"
COHERE_BASE="${COHERE_BASE}"
OLLAMA_URL="${OLLAMA_URL}"
NLC_SEND_FULL_DOCS="${NLC_SEND_FULL_DOCS}"
NLC_TASK_COMMAND="${NLC_TASK_COMMAND}"
NLC_MAX_TOKENS="${NLC_MAX_TOKENS}"
NLC_TOKENS_PER_MIN="${NLC_TOKENS_PER_MIN}"
NLC_RATE_LIMIT_MS="${NLC_RATE_LIMIT_MS}"
NLC_RESPONSE_MAX_TOKENS="${NLC_RESPONSE_MAX_TOKENS}"
CFG
  chmod 600 "$NLC_CFG" || true
  log "Saved settings -> $NLC_CFG"
}

validate_cfg(){
  case "${NLC_PROVIDER}" in
    openai)    [[ -n "${OPENAI_API_KEY}" ]] || { err "Set OPENAI_API_KEY in Settings"; return 1; } ;;
    azure)     [[ -n "${AZURE_OPENAI_API_KEY}" ]] || { err "Set AZURE_OPENAI_API_KEY"; return 1; }
               [[ -n "${AZURE_OPENAI_ENDPOINT}" ]] || { err "Set AZURE_OPENAI_ENDPOINT"; return 1; }
               [[ -n "${AZURE_OPENAI_DEPLOYMENT}" ]] || { err "Set AZURE_OPENAI_DEPLOYMENT"; return 1; }
               [[ -n "${AZURE_OPENAI_API_VERSION}" ]] || { err "Set AZURE_OPENAI_API_VERSION"; return 1; } ;;
    anthropic) [[ -n "${ANTHROPIC_API_KEY}" ]] || { err "Set ANTHROPIC_API_KEY"; return 1; } ;;
    gemini)    [[ -n "${GEMINI_API_KEY}" ]] || { err "Set GEMINI_API_KEY"; return 1; } ;;
    mistral)   [[ -n "${MISTRAL_API_KEY}" ]] || { err "Set MISTRAL_API_KEY"; return 1; } ;;
    cohere)    [[ -n "${COHERE_API_KEY}" ]] || { err "Set COHERE_API_KEY"; return 1; } ;;
    ollama)    : ;;
    *) err "Unsupported provider: ${NLC_PROVIDER}"; return 1;;
  esac
}

# ----------------------- Providers (HTTP) -----------------------
call_openai(){
  local sys="$1" usr="$2"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "${OPENAI_BASE}/chat/completions" \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{"model":"${NLC_MODEL}","max_tokens":${NLC_RESPONSE_MAX_TOKENS},"messages":[
{"role":"system","content": $(jq -Rs . < "$sys")},
{"role":"user","content": $(jq -Rs . < "$usr")}
]}
JSON
}

call_azure_openai(){
  local sys="$1" usr="$2"
  local url="${AZURE_OPENAI_ENDPOINT}/openai/deployments/${AZURE_OPENAI_DEPLOYMENT}/chat/completions?api-version=${AZURE_OPENAI_API_VERSION}"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "$url" \
    -H "api-key: ${AZURE_OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{"max_tokens":${NLC_RESPONSE_MAX_TOKENS},"temperature":0.2,"messages":[
{"role":"system","content": $(jq -Rs . < "$sys")},
{"role":"user","content": $(jq -Rs . < "$usr")}
]}
JSON
}

call_anthropic(){
  local sys="$1" usr="$2"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "${ANTHROPIC_BASE}/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{"model":"${NLC_MODEL}","max_tokens":${NLC_RESPONSE_MAX_TOKENS},"temperature":0.2,
 "system": $(jq -Rs . < "$sys"),
 "messages":[{"role":"user","content": $(jq -Rs . < "$usr")}]
}
JSON
}

call_gemini(){
  local sys="$1" usr="$2"
  local url="${GEMINI_BASE}/v1beta/models/${NLC_MODEL}:generateContent?key=${GEMINI_API_KEY}"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "$url" -H "Content-Type: application/json" -d @- <<JSON
{"contents":[
  {"role":"user","parts":[{"text": $(jq -Rs . < "$sys")} ]},
  {"role":"user","parts":[{"text": $(jq -Rs . < "$usr")} ]}
]}
JSON
}

call_mistral(){
  local sys="$1" usr="$2"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "${MISTRAL_BASE}/v1/chat/completions" \
    -H "Authorization: Bearer ${MISTRAL_API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{"model":"${NLC_MODEL}","max_tokens":${NLC_RESPONSE_MAX_TOKENS},"temperature":0.2,"messages":[
{"role":"system","content": $(jq -Rs . < "$sys")},
{"role":"user","content": $(jq -Rs . < "$usr")}
]}
JSON
}

call_cohere(){
  local sys="$1" usr="$2"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "${COHERE_BASE}/v1/chat" \
    -H "Authorization: Bearer ${COHERE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<JSON
{"model":"${NLC_MODEL}","max_tokens":${NLC_RESPONSE_MAX_TOKENS},"temperature":0.2,
 "preamble": $(jq -Rs . < "$sys"),
 "messages":[{"role":"user","content": $(jq -Rs . < "$usr")}]
}
JSON
}

call_ollama(){
  local sys="$1" usr="$2"
  curl -sS --max-time 30 -w '\n%{http_code}' -X POST "${OLLAMA_URL}" -H "Content-Type: application/json" -d @- <<JSON
{"model":"${NLC_MODEL}","stream":false,"options":{"num_predict":${NLC_RESPONSE_MAX_TOKENS}},"messages":[
{"role":"system","content": $(jq -Rs . < "$sys")},
{"role":"user","content": $(jq -Rs . < "$usr")}
]}
JSON
}

call_provider(){
  local sys="$1" usr="$2" raw status body est
  validate_cfg || return 1

  est=$( (cat "$sys"; echo; cat "$usr") | estimate_tokens )
  if (( NLC_MAX_TOKENS > 0 && est > NLC_MAX_TOKENS )); then
    echo "[NLC] WARNING: prompt ~${est} tokens exceeds budget (${NLC_MAX_TOKENS})."
    read -r -p "Auto-truncate user request to fit? [y/N]: " yn
    if [[ "${yn:-N}" =~ ^[Yy]$ ]]; then
      local sys_toks keep_toks approx_bytes
      sys_toks=$(cat "$sys" | estimate_tokens)
      keep_toks=$(( NLC_MAX_TOKENS - sys_toks )); (( keep_toks < 128 )) && keep_toks=128
      approx_bytes=$(( keep_toks * 4 ))
      truncate_to_boundary "$usr" "$approx_bytes" "${NLC_WORK}/usr.trunc"
      usr="${NLC_WORK}/usr.trunc"
      est=$( (cat "$sys"; echo; cat "$usr") | estimate_tokens )
      echo "[NLC] New est tokens: ${est}"
    else
      echo "[NLC] Proceeding without truncation."
    fi
  fi

  sleep_for_tokens "$est"
  sleep_ms

  case "$NLC_PROVIDER" in
    openai)   raw="$(retry 3 call_openai       "$sys" "$usr")"   ;;
    azure)    raw="$(retry 3 call_azure_openai "$sys" "$usr")"   ;;
    anthropic)raw="$(retry 3 call_anthropic     "$sys" "$usr")"   ;;
    gemini)   raw="$(retry 3 call_gemini        "$sys" "$usr")"   ;;
    mistral)  raw="$(retry 3 call_mistral       "$sys" "$usr")"   ;;
    cohere)   raw="$(retry 3 call_cohere        "$sys" "$usr")"   ;;
    ollama)   raw="$(retry 3 call_ollama        "$sys" "$usr")"   ;;
    *) err "Unsupported provider: $NLC_PROVIDER"; return 1;;
  esac
  status="$(tail -n1 <<< "$raw")"
  body="$(sed '$ d' <<< "$raw")"
  
  if [[ "$status" != "200" && "$status" != "201" ]]; then
    local msg
    msg="$(echo "$body" | jq -r '.error.message // .error // .message // empty' 2>/dev/null)"
    if [[ -z "$msg" ]]; then msg="$(echo "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"; fi
    err "HTTP $status from $NLC_PROVIDER. Response: ${msg:-See $NLC_WORK/last_error.json}"
    printf "%s
" "$body" > "$NLC_WORK/last_error.json"
    return 1
  fi

  printf "%s" "$body"
}

# ----------------------- Provider-specific parsing -----------------------
extract_text(){
  local provider="$1"
  case "$provider" in
    openai|azure|mistral) jq -r '.choices[0].message.content // empty' ;;
    anthropic)            jq -r '.content[0].text // empty' ;;
    gemini)               jq -r '.candidates[0].content.parts[0].text // empty' ;;
    cohere)               jq -r '.text // .message.content // empty' ;;
    ollama)               jq -r '.message.content // .messages[-1].content // empty' ;;
    *)                    jq -r '.' ;;
  esac
}

# ----------------------- Prompts -----------------------
write_system_prompt(){ cat > "$1" <<'SYS'
You are an AI acting as a Natural-Language Compiler for the "conversation → seed repo" phase.
Rules:
- Ask clarifying questions in at most two passes; otherwise proceed with safe defaults.
- If underspecified, list NLC-AMBIGUITY:<field> items in "messages".
- Output a single JSON object (no extra prose) with fields:
  project (string), files (array of {path, content, executable?}), messages (array), next_steps (array).
- Generate a minimal, runnable seed repo: nlc.yaml, tests/smoke.sh, Makefile, contracts/* if relevant,
  src/, include/, man/ as needed, README.md with an Intent->Code Map,
  CLAUDE.md with strict handoff instructions (NO test gaming; NO fake-done),
  and tools/nlc_claude.sh that prints structured prompt blocks for Claude Code.
- Prefer portable, dependency-light code and POSIX sh scripts.
- Treat the workspace as untrusted; do not generate auto-executing code.
- The implementer will be **Claude Code in the terminal**. Tailor repo scaffolding and prompts for Claude to continue.
SYS
}

write_file_system_prompt(){ 
  local output_file="$1" lang="$2"
  cat > "$output_file" <<FILESYS
You are an AI code generator creating individual source files for a software project.
Target language: ${lang}
Rules:
- Generate ONLY the raw file content - no JSON, no markdown fences, no explanations
- Follow the file type conventions (.c files = C code, .py files = Python code, .go files = Go code, etc.)
- Use appropriate ${lang} language syntax, imports, and best practices
- Ensure the file serves its intended purpose as described in the requirements
- For executable files, include appropriate shebang lines
- Keep code portable and dependency-light when possible
- Do not include any wrapper formatting - output raw file content only
FILESYS
}

write_summarize_prompt(){ cat > "$1" <<'SUM'
Summarize the corpus for design relevance:
- Extract goals, non-goals, stakeholders, constraints, interfaces (CLI/API), data schemas, acceptance criteria.
- Return a concise Markdown outline (<= 800 words).
SUM
}

write_structure_prompt(){ 
  local output_file="$1" lang="$2"
  local main_file build_file build_desc
  
  # Language-specific file names and build systems
  case "$lang" in
    c)    main_file="src/main.c"; build_file="Makefile"; build_desc="C build system with gcc/clang" ;;
    cpp)  main_file="src/main.cpp"; build_file="Makefile"; build_desc="C++ build system with g++/clang++" ;;
    py)   main_file="src/main.py"; build_file="requirements.txt"; build_desc="Python dependencies" ;;
    go)   main_file="main.go"; build_file="go.mod"; build_desc="Go module definition" ;;
    rust) main_file="src/main.rs"; build_file="Cargo.toml"; build_desc="Rust project configuration" ;;
    ts)   main_file="src/main.ts"; build_file="package.json"; build_desc="Node.js project configuration" ;;
    *)    main_file="src/main.${lang}"; build_file="Makefile"; build_desc="build system for ${lang}" ;;
  esac
  
  cat > "$output_file" <<STRUCT
Use the materials provided (intent, Q&A transcript, optional corpus summary) and produce a project file structure as JSON.

Return ONLY the file list and metadata - DO NOT include file contents. Use this schema:

{
  "project": "project-name",
  "files": [
    {"path": "nlc.yaml", "type": "config", "description": "project goals and constraints"},
    {"path": "${build_file}", "type": "build", "description": "${build_desc}"},
    {"path": "tests/smoke.sh", "type": "test", "executable": true, "description": "basic validation test"},
    {"path": "${main_file}", "type": "source", "description": "main program file"},
    {"path": "README.md", "type": "documentation", "description": "project overview with Intent->Code Map"},
    {"path": "CLAUDE.md", "type": "documentation", "description": "Claude Code instructions and policies"},
    {"path": "tools/task.sh", "type": "tool", "executable": true, "description": "task logging script"},
    {"path": "tools/nlc_claude.sh", "type": "tool", "executable": true, "description": "project context script for Claude Code"}
  ]
}

Required files for every project:
- nlc.yaml (goal, non_goals, interfaces, constraints, tests)
- ${build_file} (${build_desc})
- tests/smoke.sh (executable)
- contracts/* if applicable
- Language-specific source structure as needed
- README.md with Intent->Code Map and "Handoff to Claude Code" section
- CLAUDE.md with anti-cheating policy and work protocol
- tools/task.sh for task capture
- tools/nlc_claude.sh for project context (Claude Code integration)
- tasks/ folder structure

Target language: ${lang}
STRUCT
}

write_generate_prompt(){ cat > "$1" <<'GEN'
Use the materials provided (intent, Q&A transcript, optional corpus summary) and produce a seed repo as JSON (strict):
- nlc.yaml (goal, non_goals, interfaces, constraints, tests)
- Makefile (warnings-as-errors if requested)
- tests/smoke.sh (executable)
- contracts/* if applicable
- src/, include/, man/ as needed
- README.md with an Intent->Code Map and a short section titled "Handoff to Claude Code" explaining next steps.
- CLAUDE.md MUST include:
  - Your role: "Claude Code in the terminal — implementer, not planner"
  - **Anti-cheating policy**: do not game tests, do not mock or bypass, no "pretend pass"; always run tests and report failures truthfully
  - **Work protocol**: small PR-sized changes; run `make test` after each change; update the Intent→Code Map when behavior changes
  - **Task capture**: whenever you create a TODO, stub, FIXME, or defer work, call `tools/task.sh "<short task>" "<details>"` to record a task
  - **Source of truth**: defer to `nlc.yaml`, `contracts/`, and `tests/`; update them when scope changes
- tools/nlc_claude.sh that echoes prompt blocks ([[GOAL]], [[CONSTRAINTS]], [[DELIVERABLES]], [[TESTS]], [[TRACEABILITY]], [[NATURAL_LANGUAGE_SPEC]]).
- tools/task.sh that appends tasks to `tasks/tasks.md` (single source of truth for this repo).
  If env `NLC_TASK_COMMAND` is set, send title & details to it via stdin (one per line) as an integration hook.
- Create `tasks/` folder with a `tasks.md` log, and mention it in README.md.
GEN
}

write_file_prompt(){ 
  local output_file="$1" file_path="$2" file_type="$3" file_desc="$4" lang="$5"
  cat > "$1" <<FILE_PROMPT
CRITICAL: Generate content for the SPECIFIC file: ${file_path}

File type: ${file_type}
File description: ${file_desc}

IMPORTANT FILE TYPE REQUIREMENTS:
- If file ends in .c: Generate C source code
- If file ends in .sh: Generate shell script with #!/bin/sh shebang
- If file ends in .md: Generate markdown documentation
- If file is "Makefile": Generate Makefile build rules with tabs
- If file is "nlc.yaml": Generate YAML configuration
- If file type is "tool": Generate executable script appropriate for the filename
- If file type is "test": Generate test script appropriate for the filename
- If file type is "documentation": Generate appropriate documentation format

SPECIFIC REQUIREMENTS FOR THIS FILE (${file_path}):
${file_desc}

Context from project: The overall project creates a ${lang} program, but THIS SPECIFIC FILE must serve its own purpose as described above.

Return ONLY the raw file content - no JSON, no markdown fences, no explanations, no wrapper text.
FILE_PROMPT
}

generate_single_file(){
  local proj="$1" file_path="$2" file_type="$3" file_desc="$4" executable="$5"
  local intent="$6" trans="$7" summary="${8:-}" lang="$9"
  
  # Create file-specific system prompt
  write_file_system_prompt "${NLC_WORK}/file_sys.txt" "$lang"
  
  # Create file generation prompt
  write_file_prompt "${NLC_WORK}/file.txt" "$file_path" "$file_type" "$file_desc" "$lang"
  
  # Create request with context
  {
    echo "[Intent]"; echo "$intent"
    echo; echo "[Q&A Transcript]"; cat "$trans"
    if [[ -s "$summary" ]]; then echo; echo "[Corpus summary]"; cat "$summary"; fi
    echo; cat "${NLC_WORK}/file.txt"
  } > "${NLC_WORK}/file.req"
  
  log "Generating file: $file_path"
  local r out
  r="$(call_provider "${NLC_WORK}/file_sys.txt" "${NLC_WORK}/file.req")" || {
    err "Provider call failed for $file_path"
    return 1
  }
  
  out="$(echo "$r" | extract_text "$NLC_PROVIDER")"
  
  # Write the file content directly (no JSON parsing needed)
  if safe_write "$proj" "$file_path" "$out" "$executable"; then
    log "Generated: $file_path"
    return 0
  else
    err "Failed to write: $file_path"
    return 1
  fi
}

write_fix_prompt(){ cat > "$1" <<'FIX'
Given: the existing project tree, an error log, and a list of files to consider.
Return a JSON object (same schema) containing only the updated/added files needed to fix the issues.
If ambiguity remains, include NLC-AMBIGUITY items in "messages".
FIX
}

# ----------------------- Docs intake (portable byte sampling) -----------------------
is_binary(){
  if has file; then
    local mime
    mime="$(file -b --mime "$1" 2>/dev/null || true)"
    if echo "$mime" | grep -qE 'charset=binary|application/(octet-stream|pdf)'; then
      return 0
    fi
  fi
  LC_ALL=C grep -qU $'\x00' "$1"
}

bytes_slice_py(){ python3 - "$1" "$2" "$3" <<'PY'
import sys
p, start, length = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(p, 'rb') as f:
    f.seek(start)
    sys.stdout.buffer.write(f.read(length))
PY
}

bytes_slice_dd(){ dd if="$1" bs=1 skip="$2" count="$3" status=none 2>/dev/null || return 1; }
bytes_slice_approx(){ local f="$1" start="$2" length="$3"; tail -c +$(( start + 1 )) "$f" 2>/dev/null | head -c "$length" 2>/dev/null || true; }
read_bytes(){ if has python3; then bytes_slice_py "$1" "$2" "$3" || bytes_slice_dd "$1" "$2" "$3" || bytes_slice_approx "$1" "$2" "$3"; else bytes_slice_dd "$1" "$2" "$3" || bytes_slice_approx "$1" "$2" "$3"; fi }

sample_file(){
  local f="$1" out="$2" size h m t mid_start mid_len tail_len
  echo -e "\n=== FILE: $f ===" >> "$out"
  size=$(wc -c < "$f" 2>/dev/null || echo 0)
  if (( size == 0 )); then echo "(empty)" >> "$out"; return; fi
  h=$NLC_SAMPLE_HEAD_BYTES; m=$NLC_SAMPLE_MID_BYTES; t=$NLC_SAMPLE_TAIL_BYTES
  if (( h + m + t > size )); then h=$(( size/3 )); m=$(( size/3 )); t=$(( size - h - m )); fi
  mid_start=$(( (size/2) - (m/2) )); (( mid_start < 0 )) && mid_start=0
  mid_len=$m; tail_len=$t
  read_bytes "$f" 0 "$h" >> "$out"
  echo -e "\n[...middle...]\n" >> "$out"
  local min_gap=$NLC_SAMPLE_OVERLAP_BYTES
  if (( mid_start < h + min_gap )); then mid_start=$(( h + min_gap )); fi
  read_bytes "$f" "$mid_start" "$mid_len" >> "$out"
  echo -e "\n[...tail...]\n" >> "$out"
  local tail_start=$(( size - tail_len )); local mid_end=$(( mid_start + mid_len ))
  if (( tail_start < mid_end + min_gap )); then tail_start=$(( mid_end + min_gap )); fi
  if (( tail_start < 0 )); then tail_start=0; fi
  read_bytes "$f" "$tail_start" "$tail_len" >> "$out"
}

build_summary(){
  local docs="$1" corpus="$2" summary="$3"
  : > "$corpus"; : > "$summary"
  while IFS= read -r -d '' f; do
    if is_binary "$f"; then
      echo -e "\n=== FILE (binary skipped): $f ===" >> "$corpus"
    else
      sample_file "$f" "$corpus"
    fi
  done < <(find "$docs" -type f -print0 | sort -z)

  local toks; toks=$(estimate_tokens < "$corpus" 2>/dev/null || echo 0)
  if (( toks > 120000 )); then
    echo "[NLC] WARNING: large corpus sample (~$toks tokens). Consider lowering NLC_SAMPLE_*."
    read -r -p "Continue summarization? [y/N]: " yn
    [[ "${yn:-N}" =~ ^[Yy]$ ]] || return 1
  fi

  write_system_prompt "${NLC_WORK}/sys.txt"
  write_summarize_prompt "${NLC_WORK}/sum.txt"
  { cat "${NLC_WORK}/sum.txt"; echo; echo "---"; echo "[CORPUS SAMPLE]"; cat "$corpus"; } > "${NLC_WORK}/sum.req"
  local r; r="$(call_provider "${NLC_WORK}/sys.txt" "${NLC_WORK}/sum.req")" || { err "Summary failed"; return 1; }
  echo "$r" | extract_text "$NLC_PROVIDER" > "$summary" || true
}

# ----------------------- Repo post-processing: tasks + CLAUDE.md -----------------------
install_task_hook(){
  local proj="$1"
  mkdir -p "$proj/tools" "$proj/tasks"
  [[ -f "$proj/tasks/tasks.md" ]] || printf "# Tasks\n\n" > "$proj/tasks/tasks.md"
  if [[ ! -x "$proj/tools/task.sh" ]]; then
    cat > "$proj/tools/task.sh" <<'TASK'
#!/bin/sh

if [ -z "$1" ]; then
  echo "Task title is required"
  exit 1
fi

if [ -z "$2" ]; then
  echo "Task details are required"
  exit 1
fi

echo "- [$1] $2" >> tasks/tasks.md

if [ -n "$NLC_TASK_COMMAND" ]; then
  echo "$1" | $NLC_TASK_COMMAND
fi
TASK
    chmod +x "$proj/tools/task.sh"
  fi

  # Self-test (basic functionality)
  ( cd "$proj" && ./tools/task.sh "NLC self-test" "verifying task hook" ) >/dev/null 2>&1 || {
    err "Repo task hook failed self-test."
  }
}

augment_claude_md(){
  local proj="$1"
  local block="<!-- NLC_POLICY_BLOCK -->
## Claude Code Policy (NLC)

**Your role**: Claude Code in the terminal — implementer, not planner.

**Getting started**:
- Run \`/init\` to analyze this codebase
- Say \"use nlc_claude.sh\ and build project" to get project context
- This will give you full understanding of goals, constraints, and current status

**Do not cheat**:
- Do not game tests or bypass checks.
- Do not mock functionality to fake a pass.
- Always run the test suite honestly and report failures truthfully.

**Work protocol**:
- Make small, PR-sized changes.
- Run \`make test\` after each change.
- Keep the Intent→Code Map in README.md aligned with any behavior change.

**Task capture**:
- Whenever you add a TODO/FIXME or leave a stub, create a task:
  \`tools/task.sh \"<short title>\" \"<details>\"\`.

**Source of truth**:
- Defer to \`nlc.yaml\`, \`contracts/\`, and \`tests/\`.
- Update them when scope or behavior changes.
<!-- /NLC_POLICY_BLOCK -->"
  if [[ -f "$proj/CLAUDE.md" ]]; then
    if ! grep -q "NLC_POLICY_BLOCK" "$proj/CLAUDE.md"; then
      printf "\n%s\n" "$block" >> "$proj/CLAUDE.md"
    fi
  else
    printf "# CLAUDE.md\n\nFollow the repository rules below.\n\n%s\n" "$block" > "$proj/CLAUDE.md"
  fi
}

# ----------------------- New project -----------------------
start_project(){
  need jq "Install jq (brew install jq / apt-get install jq)"
  need curl "Install curl"
  load_cfg

  echo "== New Project for Claude Code =="
  read -r -p "Project name (kebab-case): " PROJ
  if [[ ! "$PROJ" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    err "Project name must be kebab-case (lowercase letters, numbers, hyphens)";
    return 1;
  fi
  read -r -p "Primary language [c|cpp|py|go|rust|ts]: " LANG
  read -r -p "One-sentence goal: " INTENT

  echo "Optional docs directory (empty to skip):"
  read -r -p "Docs path: " DOCS

  local CORPUS="${NLC_WORK}/corpus.txt"
  local SUMMARY="${NLC_WORK}/summary.md"
  if [[ -n "${DOCS:-}" && -d "$DOCS" ]]; then
    log "Building corpus summary (full docs will be preserved in the repo)..."
    build_summary "$DOCS" "$CORPUS" "$SUMMARY" || true
  fi

  write_system_prompt "${NLC_WORK}/sys.txt"

  # Pass 1
  {
    echo "Project: $PROJ"
    echo "Primary language: $LANG"
    echo; echo "[User intent]"; echo "$INTENT"
    if [[ -s "$SUMMARY" ]]; then echo; echo "[Corpus summary]"; cat "$SUMMARY"; fi
    echo; echo "Ask at most 6 short, high-signal questions. Number them."
  } > "${NLC_WORK}/p1.req"
  log "Asking clarifying questions (pass 1)..."
  local r q1 a1
  r="$(call_provider "${NLC_WORK}/sys.txt" "${NLC_WORK}/p1.req")" || { err "Provider call failed"; return 1; }
  q1="$(echo "$r" | extract_text "$NLC_PROVIDER")"
  if [[ -z "$q1" || "$q1" == "null" ]]; then
    err "No text content returned by $NLC_PROVIDER. Raw saved to $NLC_WORK/model_p1.json"
    printf "%s\n" "$r" > "$NLC_WORK/model_p1.json"
    return 1
  fi
  echo "$q1"
  echo "Answer below (Ctrl-D to finish):"
  a1="$(cat)"
  local TRANS="${NLC_WORK}/qa.txt"; printf "Q:\n%s\n\nA:\n%s\n" "$q1" "$a1" > "$TRANS"

  # Pass 2
  {
    echo "Context so far:"; echo "$INTENT"
    echo; echo "[Transcript]"; cat "$TRANS"
    echo
    echo "TASK: Review the above context and transcript. If anything remains ambiguous for implementing the project, ask up to 4 final clarifying questions as plain text. Do NOT generate code or JSON - only ask questions."
    echo "If no questions are needed, respond with exactly: NO FURTHER QUESTIONS"
  } > "${NLC_WORK}/p2.req"
  log "Asking clarifying questions (pass 2)..."
  r="$(call_provider "${NLC_WORK}/sys.txt" "${NLC_WORK}/p2.req")" || { err "Provider call failed"; return 1; }
  local q2 a2; q2="$(echo "$r" | extract_text "$NLC_PROVIDER")"
  if grep -qi "NO FURTHER QUESTIONS" <<< "$q2"; then log "No further questions."; a2="";
  else
    echo "$q2"
    echo "Final concise answers (Ctrl-D to finish):"
    a2="$(cat)"
    printf "\nQ:\n%s\n\nA:\n%s\n" "$q2" "$a2" >> "$TRANS"
  fi

  # Phase 1: Generate project structure (file list only)
  log "Phase 1: Generating project structure..."
  write_structure_prompt "${NLC_WORK}/struct.txt" "$LANG"
  {
    echo "[Intent]"; echo "$INTENT"
    echo; echo "[Q&A Transcript]"; cat "$TRANS"
    if [[ -s "$SUMMARY" ]]; then echo; echo "[Corpus summary]"; cat "$SUMMARY"; fi
    echo; cat "${NLC_WORK}/struct.txt"
    echo; echo "Important:"
    echo "- Project directory name must be: $PROJ"
    echo "- Primary language: $LANG"
    echo "- Return ONLY valid JSON per the schema (no prose)."
  } > "${NLC_WORK}/struct.req"

  r="$(call_provider "${NLC_WORK}/sys.txt" "${NLC_WORK}/struct.req")" || { err "Provider call failed"; return 1; }
  local out json; out="$(echo "$r" | extract_text "$NLC_PROVIDER")"
  json="$(printf "%s" "$out" | strip_md_fences | fix_json_escaping)"
  
  if ! echo "$json" | jq . >/dev/null 2>&1; then
    err "Invalid JSON from model for structure; attempting to repair..."
    printf "%s\n" "$out" > "$NLC_WORK/model_struct.json"
    echo "$out" | head -c 1000
    return 1
  fi

  # Validate structure schema
  if ! echo "$json" | jq -e '.project and (.files | type=="array") and (all(.files[]; has("path") and has("type")))' >/dev/null 2>&1; then
    err "Invalid structure schema from model"
    printf "%s\n" "$out" > "${NLC_WORK}/model_struct_invalid.json"
    return 1
  fi

  # Create project directory
  mkdir -p "$PROJ" || { err "Failed to create project directory $PROJ"; return 1; }
  chmod 755 "$PROJ" || true  # Ensure readable/executable for user and group
  
  # Phase 2: Generate individual files
  log "Phase 2: Generating individual files..."
  rm -f "${NLC_WORK}/file_errors.log"
  local file_list="${NLC_WORK}/files.list"
  echo "$json" | jq -r '.files[] | @base64' > "$file_list"
  
  while IFS= read -r encoded_file; do
    local file_json path type desc executable
    file_json="$(echo "$encoded_file" | base64 -d)"
    path="$(echo "$file_json" | jq -r '.path')"
    type="$(echo "$file_json" | jq -r '.type')"
    desc="$(echo "$file_json" | jq -r '.description // ""')"
    executable="$(echo "$file_json" | jq -r '.executable // false')"
    
    if ! generate_single_file "$PROJ" "$path" "$type" "$desc" "$executable" "$INTENT" "$TRANS" "$SUMMARY" "$LANG"; then
      echo "[NLC][FILE-ERROR] $path" >> "${NLC_WORK}/file_errors.log"
      err "Failed to generate: $path"
    fi
  done < "$file_list"

  install_task_hook "$PROJ"
  augment_claude_md "$PROJ"

  if [[ -f "${NLC_WORK}/file_errors.log" ]]; then
    err "Some files failed to generate (see ${NLC_WORK}/file_errors.log)"
    cat "${NLC_WORK}/file_errors.log"
    rm -f "${NLC_WORK}/file_errors.log"
    echo "Partial project created at ./${PROJ} (some files missing)"
    return 1
  fi

  log "Done. Project at ./${PROJ}"
}

# ----------------------- Iterate / Fix -----------------------
iterate_fix(){
  need jq "Install jq"; need curl "Install curl"
  load_cfg
  echo "== Iterate / Fix =="
  read -r -p "Project directory: " PROJ
  [[ -d "$PROJ" ]] || { err "No such directory"; return 1; }
  read -r -p "Files to update (comma-separated paths): " FILES
  echo "Paste build/test error log (Ctrl-D to finish):"
  ERRLOG="$(cat)"

  write_system_prompt "${NLC_WORK}/sys.txt"
  write_fix_prompt "${NLC_WORK}/fix.txt"
  {
    echo "Project tree (truncated):"; (cd "$PROJ" && find . -maxdepth 2 -type f | sort | sed 's|^\./||')
    echo; echo "[Files requested for update]"; echo "$FILES"
    echo; echo "[Error log]"; echo "$ERRLOG"
    echo; cat "${NLC_WORK}/fix.txt"
  } > "${NLC_WORK}/fix.req"

  log "Requesting targeted fixes..."
  local r out json
  r="$(call_provider "${NLC_WORK}/sys.txt" "${NLC_WORK}/fix.req")" || { err "Provider call failed"; return 1; }
  out="$(echo "$r" | extract_text "$NLC_PROVIDER")"
  json="$(printf "%s" "$out" | strip_md_fences)"
  echo "$json" | jq . >/dev/null 2>&1 || { err "Invalid JSON from model"; printf "%s\n" "$out" > "$NLC_WORK/model_fix.json"; return 1; }

  local write_errors=0
  echo "$json" | jq -c '.files[]' | while read -r f; do
    p="$(echo "$f" | json_get '.path')"; c="$(echo "$f" | json_get '.content')"; x="$(echo "$f" | json_get '.executable // false')"
    if ! safe_write "$PROJ" "$p" "$c" "$x"; then
      echo "[NLC][WRITE-ERROR] $p" >> "${NLC_WORK}/write_errors.log"
      write_errors=1
    fi
  done

  install_task_hook "$PROJ"
  augment_claude_md "$PROJ"

  if [[ -f "${NLC_WORK}/write_errors.log" ]]; then
    err "Some files failed to write (see ${NLC_WORK}/write_errors.log). Patch manifest saved to ${NLC_WORK}/manifest_fix.json"
    printf "%s\n" "$json" > "${NLC_WORK}/manifest_fix.json"
  fi

  if has git; then
    read -r -p "Commit changes? [y/N]: " yn
    if [[ "${yn:-N}" =~ ^[Yy]$ ]]; then ( cd "$PROJ" && git add . && git commit -m "nlc: iterate/fix" >/dev/null 2>&1 && log "Committed iteration." ) || err "Git commit failed."; fi
  fi

  if [[ -f "$PROJ/Makefile" ]]; then
    read -r -p "Run 'make test' now? [y/N]: " yn2
    if [[ "${yn2:-N}" =~ ^[Yy]$ ]]; then ( cd "$PROJ" && make test ) || err "Tests failed (see output)."; fi
  fi
}

# ----------------------- Settings -----------------------
settings(){
  load_cfg
  echo "== Settings (conversation provider) =="
  printf "Provider [openai|azure|anthropic|gemini|mistral|cohere|ollama] (%s): " "$NLC_PROVIDER"; read -r ans; NLC_PROVIDER="${ans:-$NLC_PROVIDER}"
  
  # Update model default based on selected provider
  local model_default
  case "${NLC_PROVIDER}" in
    openai) model_default="${OPENAI_MODEL_DEFAULT}" ;;
    azure) model_default="${AZURE_MODEL_DEFAULT}" ;;
    anthropic) model_default="${ANTHROPIC_MODEL_DEFAULT}" ;;
    gemini) model_default="${GEMINI_MODEL_DEFAULT}" ;;
    mistral) model_default="${MISTRAL_MODEL_DEFAULT}" ;;
    cohere) model_default="${COHERE_MODEL_DEFAULT}" ;;
    ollama) model_default="${OLLAMA_MODEL_DEFAULT}" ;;
    *) model_default="${NLC_MODEL_DEFAULT}" ;;
  esac
  
  printf "Model (%s): " "$model_default"; read -r ans; NLC_MODEL="${ans:-$model_default}"
  
  if [[ "$NLC_PROVIDER" == "azure" ]]; then
    printf "AZURE_OPENAI_ENDPOINT (%s): " "$AZURE_OPENAI_ENDPOINT"; read -r x; AZURE_OPENAI_ENDPOINT="${x:-$AZURE_OPENAI_ENDPOINT}"
    printf "AZURE_OPENAI_DEPLOYMENT (%s): " "$AZURE_OPENAI_DEPLOYMENT"; read -r x; AZURE_OPENAI_DEPLOYMENT="${x:-$AZURE_OPENAI_DEPLOYMENT}"
    printf "AZURE_OPENAI_API_VERSION (%s): " "$AZURE_OPENAI_API_VERSION"; read -r x; AZURE_OPENAI_API_VERSION="${x:-$AZURE_OPENAI_API_VERSION}"
    if [[ -z "${AZURE_OPENAI_API_KEY:-}" ]]; then read -r -p "AZURE_OPENAI_API_KEY: " AZURE_OPENAI_API_KEY; else read -r -p "AZURE_OPENAI_API_KEY (blank=keep): " x; [[ -n "${x:-}" ]] && AZURE_OPENAI_API_KEY="$x"; fi
  else
    case "$NLC_PROVIDER" in
      openai)
        printf "OPENAI_BASE (%s): " "$OPENAI_BASE"; read -r x; OPENAI_BASE="${x:-$OPENAI_BASE}"
        if [[ -z "${OPENAI_API_KEY:-}" ]]; then read -r -p "OPENAI_API_KEY: " OPENAI_API_KEY; else read -r -p "OPENAI_API_KEY (blank=keep): " x; [[ -n "${x:-}" ]] && OPENAI_API_KEY="$x"; fi;;
      anthropic)
        printf "ANTHROPIC_BASE (%s): " "$ANTHROPIC_BASE"; read -r x; ANTHROPIC_BASE="${x:-$ANTHROPIC_BASE}"
        if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then read -r -p "ANTHROPIC_API_KEY: " ANTHROPIC_API_KEY; else read -r -p "ANTHROPIC_API_KEY (blank=keep): " x; [[ -n "${x:-}" ]] && ANTHROPIC_API_KEY="$x"; fi;;
      gemini)
        printf "GEMINI_BASE (%s): " "$GEMINI_BASE"; read -r x; GEMINI_BASE="${x:-$GEMINI_BASE}"
        if [[ -z "${GEMINI_API_KEY:-}" ]]; then read -r -p "GEMINI_API_KEY: " GEMINI_API_KEY; else read -r -p "GEMINI_API_KEY (blank=keep): " x; [[ -n "${x:-}" ]] && GEMINI_API_KEY="$x"; fi;;
      mistral)
        printf "MISTRAL_BASE (%s): " "$MISTRAL_BASE"; read -r x; MISTRAL_BASE="${x:-$MISTRAL_BASE}"
        if [[ -z "${MISTRAL_API_KEY:-}" ]]; then read -r -p "MISTRAL_API_KEY: " MISTRAL_API_KEY; else read -r -p "MISTRAL_API_KEY (blank=keep): " x; [[ -n "${x:-}" ]] && MISTRAL_API_KEY="$x"; fi;;
      cohere)
        printf "COHERE_BASE (%s): " "$COHERE_BASE"; read -r x; COHERE_BASE="${x:-$COHERE_BASE}"
        if [[ -z "${COHERE_API_KEY:-}" ]]; then read -r -p "COHERE_API_KEY: " COHERE_API_KEY; else read -r -p "COHERE_API_KEY (blank=keep): " x; [[ -n "${x:-}" ]] && COHERE_API_KEY="$x"; fi;;
      ollama)
        printf "OLLAMA_URL (%s): " "$OLLAMA_URL"; read -r x; OLLAMA_URL="${x:-$OLLAMA_URL}";;
    esac
  fi
  printf "Send full docs to provider instead of summaries? [true/false] (%s): " "$NLC_SEND_FULL_DOCS"; read -r x; NLC_SEND_FULL_DOCS="${x:-$NLC_SEND_FULL_DOCS}"
  printf "External task command for TODOs (blank to disable) (%s): " "$NLC_TASK_COMMAND"; read -r x; NLC_TASK_COMMAND="${x:-$NLC_TASK_COMMAND}"
  printf "Max tokens per request (0=disabled) (%s): " "$NLC_MAX_TOKENS"; read -r x; NLC_MAX_TOKENS="${x:-$NLC_MAX_TOKENS}"
  printf "Tokens per minute pacing (0=disabled) (%s): " "$NLC_TOKENS_PER_MIN"; read -r x; NLC_TOKENS_PER_MIN="${x:-$NLC_TOKENS_PER_MIN}"
  printf "Floor delay between calls in ms (0=none) (%s): " "$NLC_RATE_LIMIT_MS"; read -r x; NLC_RATE_LIMIT_MS="${x:-$NLC_RATE_LIMIT_MS}"
  printf "Max tokens for model responses (%s): " "$NLC_RESPONSE_MAX_TOKENS"; read -r x; NLC_RESPONSE_MAX_TOKENS="${x:-$NLC_RESPONSE_MAX_TOKENS}"
  save_cfg
}

# ----------------------- Menu -----------------------
menu(){
  while true; do
    clear 2>/dev/null || true
    echo "NLC — Natural Language Compiler (v0.1, conversation → seed repo for Claude Code)"
    echo "==============================================================================="
    echo "1) Start new project (for Claude Code)"
    echo "2) Iterate / Fix (apply error log)"
    echo "3) What is this? (embedded whitepaper)"
    echo "4) Settings (provider, tokens, pacing, task hook)"
    echo "5) Exit"
    echo
    read -r -p "Choose an option: " o
    case "$o" in
      1) start_project; pause;;
      2) iterate_fix; pause;;
      3) show_whitepaper;;
      4) settings; pause;;
      5) exit 0;;
      *) echo "Invalid choice"; pause;;
    esac
  done
}

# ----------------------- Embedded whitepaper (EOF) -----------------------
show_whitepaper(){
  local out="$NLC_WHITEPAPER_FILE"
  # Extract whitepaper and strip all markdown formatting, then wrap to 80 columns
  awk '/^__NLC_WHITEPAPER_BEGIN__/{flag=1;next}/^__NLC_WHITEPAPER_END__/{flag=0}flag' "$0" | \
    sed 's/^## *//' | \
    sed 's/^\* *//' | \
    sed 's/\*\*//g' | \
    sed 's/`//g' | \
    sed 's/^---$/===============================================================================/' | \
    fold -s -w 80 > "$out"
  
  clear  # Clear screen before showing whitepaper
  
  # Display whitepaper as plain text with less
  ${PAGER:-less} +1 "$out" || true
}

# ----------------------- Bootstrap -----------------------
need bash "Install bash"
need curl "Install curl"
need jq   "Install jq"
load_cfg
# Optional: warn if tiktoken is missing (token estimation will be rough)
if ! python3 -c "import tiktoken" >/dev/null 2>&1; then
  log "Note: For accurate token counting, install tiktoken (pip install tiktoken)"
fi
menu

__NLC_WHITEPAPER_BEGIN__
                  NATURAL LANGUAGE COMPILER (NLC) v0.1
          Conversation → Code: Seed Repositories for Claude Code

Authors: neurodivergentai, ChatGPT, Claude — MIT License  
Implementation Target: Claude Code in the terminal (implementer)  

This Script's Role: Single‑file "Natural‑Language Compiler" (NLC) that converts intent + docs into a structured, testable seed repo.

===============================================================================

ABSTRACT

Software teams are increasingly "programming by conversation," using frontier models to sketch, generate, and refine code. While productive, this is often ad‑hoc: instructions are ambiguous, outputs vary, and traceability is poor. We propose a disciplined method that treats natural language as the high‑level source language and the model as a compiler. Our compiler (this script) conducts a short, structured interview; optionally ingests documentation; then emits a repository with contracts, tests, and strict hand‑off instructions optimized for Claude Code in the terminal to implement. Determinism is enforced at the behavioral level via tests and contracts. The repository includes an anti‑cheating policy, a repo‑local task hook for capturing TODOs, and a traceable Intent→Code Map. This document explains the model, lifecycle, architecture, security posture, and how to operate and extend the system.

===============================================================================

1. INTRODUCTION & MOTIVATION

Modern LLMs can synthesize code from prose but suffer from ambiguity, stochasticity, and incentive mismatch (e.g., "make the tests pass" can be gamed). Traditional compilers solved similar problems for formal languages with well‑defined inputs, reproducible outputs, and robust error signaling. By reframing the LLM as a Natural‑Language Compiler (NLC), we add the missing discipline:

  • Structured input (interview passes; optional doc summarization)
  • A strict JSON manifest describing all files to emit
  • Contracts + tests as the arbiter of correctness
  • Handoff rules that constrain the implementer (Claude Code) to honest, incremental work
  • Traceability (Intent→Code Map)

The result is a predictable, auditable, and teachable methodology—usable by professionals and newcomers alike.

===============================================================================

2. CORE METAPHOR: AI AS COMPILER

  Source language:  Natural language (user intent + clarifying Q&A + doc summary)
  Compiler:         LLM provider you select (OpenAI, Azure OpenAI, Anthropic, 
                    Gemini, Mistral, Cohere, Ollama)
  IR/Artifact:      A JSON manifest with files {path, content, executable} plus 
                    messages and next_steps
  Target:           A runnable seed repository with tests, contracts, and 
                    instructions aimed at Claude Code

Determinism is not byte‑for‑byte; it is behavioral. We lock behavior with tests/contracts and keep the remainder transparent and traceable.

===============================================================================

3. LIFECYCLE OVERVIEW
1. Interview (Two Passes). The script asks compact, high‑signal questions to remove ambiguity. If ambiguity remains, it is recorded as `NLC-AMBIGUITY:<field>` in `messages`.
2. Documentation (Optional). The user may point to a docs directory. The script samples head/middle/tail bytes (binary‑safe) to build a summary while preserving originals under `docs/original/`.
3. Compilation (Multi-Step, Language-Aware). Phase 1: The model returns a lightweight JSON structure with language-appropriate file paths and descriptions. Phase 2: Each file is generated individually with language-specific prompts for robustness. The script validates JSON, sanitizes paths, writes files, and marks executables.
4. Handoff Hardening. The script ensures `CLAUDE.md` exists and injects the anti‑cheating policy and task‑capture protocol. It auto‑installs `tools/task.sh` and `tasks/` if omitted.
5. Implementation Loop. You open the repo with Claude Code, follow `CLAUDE.md`, and iterate. The script’s Iterate / Fix mode can apply minimal patches based on error logs.

---

4. Repository Contract (What We Emit)
A typical seed repo contains:

```
<project>/
  README.md                # Intent→Code Map; run instructions; handoff steps
  CLAUDE.md                # Policy: no test gaming; incremental work; task capture
  nlc.yaml                 # Goal, non_goals, interfaces, constraints, tests
  contracts/               # Optional: OpenAPI, Protobuf, JSON Schema, interface defs
  tests/
    smoke.sh               # Executable minimal test (required); more tests encouraged
  src/, include/, man/     # Language-specific scaffolding for implementation
  tools/
    nlc_claude.sh          # Emits prompt blocks for Claude Code
    task.sh                # Repo-local task logger (portable ID + locking)
  tasks/
    tasks.md               # Human‑readable task log
    tasks.json             # Machine‑readable log (if jq available)
  docs/
    summary.md             # Summarized design signal from your corpus
    original/              # Exact copy of provided docs (no loss)
```

4.1 JSON Manifest Schema (Model Output)
Phase 1 (Structure): Language-aware file list with appropriate extensions and build systems.
```json
{
  "project": "kebab-case-name",
  "files": [
    { "path": "README.md", "type": "documentation", "description": "Project overview with intent→code map", "executable": false },
    { "path": "tests/smoke.sh", "type": "test", "description": "Basic functionality test", "executable": true }
  ],
  "messages": ["NLC-AMBIGUITY:... (if any)", "Info, warnings, decisions"],
  "next_steps": ["Run make test", "Open CLAUDE.md", "Start Claude Code"]
}
```
Phase 2 (Individual files): Each file is generated separately with full content for robustness and token efficiency.
The script rejects non‑JSON outputs and saves them for debugging.

4.2 Intent→Code Map
`README.md` links requirements to artifacts (files/functions/tests). This de‑mystifies the generator’s decisions and anchors future changes.

---

5. Policy & Integrity: Preventing “Test Gaming”
`CLAUDE.md` includes a policy block that Claude Code must follow:

- No cheating: Do not mock/bypass to “pretend pass.” Run tests honestly and report failures.
- Small steps: Work in PR‑sized increments; run `make test` after each change.
- Traceability: Keep the Intent→Code Map in `README.md` current.
- Task capture: Whenever creating a TODO/FIXME/stub or deferring work, run
  ```bash
  tools/task.sh "Short title" "Details"
  ```
- Source of truth: Defer to `nlc.yaml`, `contracts/`, and `tests/`. Update them when scope changes.

The script ensures this block exists even if the model forgets to generate it.

---

6. Repo‑Local Task Manager (tools/task.sh)
Design goals: portability, durability, no surprises.

- Portable IDs: `epoch-pid-random` (works on macOS/Linux/WSL).
- Atomicity: Uses `flock` when available; otherwise falls back to a `mkdir` lock.
- Resilient Writes: Always appends Markdown to `tasks/tasks.md`. Updates `tasks/tasks.json` when `jq` exists; backs up malformed JSON; never silently drops tasks.
- Self‑test: The installer runs `NLC_TASK_DRYRUN=1 tools/task.sh ...` to validate installation.
- Optional integration: If `NLC_TASK_COMMAND` is set, the script pipes title + details via stdin to your external tool (safer than argv).

This provides Claude a single, reliable command to turn TODOs into trackable tasks.

---

7. LANGUAGE SUPPORT

NLC automatically adapts to the selected programming language, generating appropriate file structures and build systems:

  C/C++:     main.c/main.cpp + Makefile (gcc/clang/g++)
  Python:    main.py + requirements.txt 
  Go:        main.go + go.mod
  Rust:      main.rs + Cargo.toml
  TypeScript: main.ts + package.json

The system prompts, file extensions, and build configurations are dynamically selected based on the language choice during project setup. This eliminates hardcoded references to specific languages in generated documentation and ensures consistency between specifications and implementation.

---

8. PROVIDERS & CONFIGURATION
NLC supports: OpenAI, Azure OpenAI, Anthropic (Claude), Gemini, Mistral, Cohere, and Ollama (local).  
The Settings menu interactively captures the right fields (including Azure deployment vs. model).

- Provider-specific parsing: The script extracts text using the correct schema for each API family.
- Retries: Exponential backoff (bounded) on transient failures.
- Error capture: Non‑2xx responses are saved to `~/.nlc/work/last_error.json` with hints.

---

9. TOKEN BUDGETING, PACING, AND SAFE TRUNCATION
- Estimation: Roughly `chars/4 ≈ tokens`. Good enough for budgets/pacing.
- Budgets: Optional Max tokens per request; if exceeded, the user can opt to truncate the user block.
- Safe truncation: The script trims to a byte count then backs up to a word boundary to avoid malformed prompts.
- **Pacing:** Optional tokens‑per‑minute throttling plus a millisecond floor between calls.

This helps avoid accidental over‑spend and improves reliability.

---

10. SECURITY POSTURE
- Path sanitization: Prevents writes outside the project root.
- No auto‑execution: Files are written non‑executable unless flagged.
- Docs preservation: Originals are copied under `docs/original/` for auditability.
- External hooks are opt‑in: `NLC_TASK_COMMAND` is under user control and receives only stdin.

---

11. OPERATING THE SYSTEM
1. Run the script: `bash nlc_v0.1.sh`
2. Settings: Choose provider, enter keys, (optional) set token caps/pacing and `NLC_TASK_COMMAND`.
3. Start New Project: Provide project name, language, one‑sentence intent. Optionally point to docs.
4. Answer Q&A: Keep answers concise. The script records the transcript.
5. Review Output: Inspect the generated repo. `README.md` includes the Intent→Code Map; `CLAUDE.md` defines policy.
6. Use with Claude Code:
   - Navigate to the generated project directory
   - Start Claude Code in that directory
   - Run `/init` to analyze the codebase
   - Say "use nlc_claude.sh and build prject" for project context and implementation
   - Claude Code will have full project understanding and can implement features
7. Run Tests: `make test` to validate implementations.
7. Iterate / Fix: If you hit errors, use the script’s Iterate mode: paste logs, select files to touch, apply the patch manifest.

---

12. SCALING & EXTENSIONS
- Contracts: For larger systems, encode APIs and schemas under `contracts/` (OpenAPI, Protobuf, JSON Schema).
- CI/CD: Plug tests into CI to lock behavioral determinism.
- Local models: With `ollama`, you can keep conversations private for sensitive early drafts.
- Provider mix Use Claude here (conversation compiler) and Claude Code as implementer; or swap the conversation provider to suit your needs.

---

13. LIMITATIONS & FUTURE WORK
- Token estimation is coarse; the script warns but cannot guarantee exact budget adherence.
- Some provider responses may still violate the JSON contract; the script saves raw failures for manual correction.
- Locking uses `flock` or a lock‑directory fallback; on unusual filesystems this may need tuning.
- Future: structured multi‑round planning manifests, richer test harness templates per language, and template libraries per domain.

---

14. APPENDIX

14.1 Minimal `CLAUDE.md` Policy Block (ensured by script)
```markdown
Claude Code Policy (NLC)

Your role: Claude Code in the terminal — implementer, not planner.

Do not cheat:
- Do not game tests or bypass checks.
- Do not mock functionality to fake a pass.
- Always run the test suite honestly and report failures truthfully.

Work protocol:
- Make small, PR-sized changes.
- Run `make test` after each change.
- Keep the Intent→Code Map in README.md aligned with any behavior change.

Task capture:
- Whenever you add a TODO/FIXME or leave a stub, create a task:
  `tools/task.sh "<short title>" "<details>"`.

Source of truth:
- Defer to `nlc.yaml`, `contracts/`, and `tests/`.
- Update them when scope or behavior changes.
```

14.2 `tools/task.sh` Behavior (installed if absent)
- Accepts `Title` and `Details`.
- Writes Markdown (always), and JSON if `jq` is present; backs up malformed DBs.
- Uses `flock` or `mkdir` lock. Supports `NLC_TASK_DRYRUN=1` for self‑test.
- If `NLC_TASK_COMMAND` is set, it reads `Title
Details
` from stdin and invokes your handler.

14.3 JSON Manifest Validation
- The script strips markdown fences, parses JSON with `jq`, and aborts on errors.
- Failed bodies are saved to `~/.nlc/work/model_*.json` to aid recovery.

14.4 Example `Makefile` Targets (typical)
```
test:
	sh tests/smoke.sh

tasks:
	@echo "Open tasks/tasks.md for TODOs created by Claude via tools/task.sh"
```

---

License* MIT — © 2025 neurodivergentai.
__NLC_WHITEPAPER_END__
