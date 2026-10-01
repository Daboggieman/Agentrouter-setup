#!/usr/bin/env bash
# =============================================================================
# setup-claude-code-dahl.sh
#
# Interactive installer that lets the Claude Code VS Code extension talk to
# Dahl Inference (https://inference.dahl.global).
#
# Why this is needed
#   Claude Code speaks the Anthropic Messages API (POST /v1/messages).
#   Dahl only offers OpenAI-style endpoints (/v1/chat/completions, /v1/responses).
#   So this script sets up a small LiteLLM proxy on your own machine that
#   translates between the two, then points the extension at that proxy.
#
# What it does (each step checks what is already done before changing anything)
#    1. Preflight: OS, curl, Python 3.9+, connectivity to Dahl
#    2. Install location, port, and model alias
#    3. Fetch Dahl's live model list and let you pick a model
#    4. Validate your Dahl API key with a real request
#    5. Create a Python virtual environment and install LiteLLM
#    6. Write config, secrets file (chmod 600), and a control script
#    7. Start the proxy and wait until it answers
#    8. Test the proxy: normal request, streaming, and tool calling
#    9. Update VS Code user settings.json (with automatic backup)
#   10. Optionally start the proxy automatically at login
#
# Usage
#   ./setup-claude-code-dahl.sh              interactive install (default)
#   ./setup-claude-code-dahl.sh uninstall    remove settings, services, files
#   ./setup-claude-code-dahl.sh status       show proxy status
#   ./setup-claude-code-dahl.sh help
#
# Works on: Linux, macOS (bash 3.2+), WSL, and Git Bash on Windows (best effort).
# =============================================================================

set -o pipefail

VERSION="1.0.0"
DAHL_BASE="${DAHL_BASE:-https://inference.dahl.global/v1}"
DEFAULT_DIR="$HOME/.claude-dahl-proxy"
DEFAULT_PORT="4000"
DEFAULT_ALIAS="dahl-deepseek"
MODEL_HINT="DeepSeek-V4-Flash"
PROXY_HOST="127.0.0.1"
PROXY_TOKEN="local-proxy"
SERVICE_NAME="dahl-proxy"
LAUNCHD_LABEL="com.user.dahl-proxy"

# ---------- colors (only when writing to a terminal) -------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""
fi

# ---------- output helpers ---------------------------------------------------
info() { printf '%s•%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { printf '\n%s%s━━ Step %s ━━%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }
chk()  { printf '%s…%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

# ---------- input helpers (bash 3.2 compatible) ------------------------------
ask() {
  # ask "Prompt" [default]  -> prints the answer on stdout
  local prompt="$1" default="${2-}" reply=""
  if [[ -n "$default" ]]; then
    read -r -p "${C_BOLD}?${C_RESET} ${prompt} [${default}]: " reply || die "Input closed."
  else
    read -r -p "${C_BOLD}?${C_RESET} ${prompt}: " reply || die "Input closed."
  fi
  printf '%s' "${reply:-$default}"
}

ask_yn() {
  # ask_yn "Question" [y|n]  -> returns 0 for yes, 1 for no
  local prompt="$1" default="${2:-y}" hint reply
  if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    read -r -p "${C_BOLD}?${C_RESET} ${prompt} [${hint}]: " reply || die "Input closed."
    reply="${reply:-$default}"
    case "$reply" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

ask_secret() {
  local prompt="$1" reply=""
  read -r -s -p "${C_BOLD}?${C_RESET} ${prompt}: " reply || die "Input closed."
  printf '\n' >&2
  printf '%s' "$reply"
}

expand_tilde() {
  local p="$1"
  # shellcheck disable=SC2088
  case "$p" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "$HOME/${p#\~/}" ;;
    *)     printf '%s' "$p" ;;
  esac
}

# ---------- temp dir + traps -------------------------------------------------
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t dahlsetup)"
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT
trap 'printf "\n"; warn "Interrupted. Nothing further was changed."; exit 130' INT TERM

# ---------- environment detection --------------------------------------------
OS="unknown"
detect_os() {
  case "$(uname -s)" in
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then OS="wsl"; else OS="linux"; fi ;;
    Darwin*) OS="mac" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) OS="unknown" ;;
  esac
}

PY=""
pick_python() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 \
       && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      PY="$c"; return 0
    fi
  done
  return 1
}

port_in_use() {
  # returns 0 if something is listening on 127.0.0.1:$1
  "$PY" - "$1" <<'PYEOF' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PYEOF
}

# run a command quietly with a progress indicator; output goes to a log file
run_quiet() {
  local log="$1"; shift
  "$@" >"$log" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 2; done
  printf '\n'
  wait "$pid"
}

# ---------- Dahl API helpers -------------------------------------------------
# The API key is passed to curl through stdin (-K -) so it never appears in `ps`.
dahl_chat_test() {
  # dahl_chat_test KEY MODEL -> prints HTTP status code
  local key="$1" model="$2" body code
  body="$("$PY" -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "messages": [{"role": "user", "content": "Reply with the single word: ready"}], "max_tokens": 16}))' "$model")"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | curl -sS -K - --max-time 90 -o "$TMP/chat.json" -w '%{http_code}' \
        -H 'Content-Type: application/json' -d "$body" "$DAHL_BASE/chat/completions" 2>"$TMP/curl.err")" || code="000"
  printf '%s' "$code"
}

# ---------- VS Code settings helper (Python), written to disk on demand ------
write_settings_helper() {
  # write_settings_helper /path/to/vscode_settings.py
  cat > "$1" <<'PYEOF'
#!/usr/bin/env python3
"""Safely add or remove the Dahl proxy entries in a VS Code settings.json.

Exit codes: 0 ok | 2 not valid JSON | 3 has comments/trailing commas (needs --allow-strip)
"""
import argparse
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime

ENV_KEY = "claudeCode.environmentVariables"
MODEL_KEY = "claudeCode.selectedModel"
OURS = [
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
]


def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas, respecting strings."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        out.append(c); i += 1
    s = "".join(out)
    out, i, n, in_str = [], 0, len(s), False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(s[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == ",":
            j = i + 1
            while j < n and s[j] in " \t\r\n":
                j += 1
            if j < n and s[j] in "}]":
                i += 1; continue
        out.append(c); i += 1
    return "".join(out)


def load(path, allow_strip):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        try:
            data = json.loads(strip_jsonc(text))
        except json.JSONDecodeError as e:
            print("ERROR: settings file is not valid JSON/JSONC: %s" % e)
            sys.exit(2)
        if not allow_strip:
            print("COMMENTS: settings file contains comments or trailing commas")
            sys.exit(3)
        print("NOTE: comments and trailing commas were removed from the file")
    if not isinstance(data, dict):
        print("ERROR: settings file top level is not a JSON object")
        sys.exit(2)
    return data


def save(path, data):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    if os.path.exists(path):
        backup = "%s.bak-%s" % (path, datetime.now().strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
        print("BACKUP: %s" % backup)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".settings-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("action", choices=["apply", "remove"])
    ap.add_argument("--base-url")
    ap.add_argument("--token")
    ap.add_argument("--model")
    ap.add_argument("--drop-selected-model", action="store_true")
    ap.add_argument("--allow-strip", action="store_true")
    a = ap.parse_args()

    data = load(a.path, a.allow_strip)
    env = data.get(ENV_KEY)
    if not isinstance(env, list):
        env = []

    if a.action == "apply":
        values = [
            ("ANTHROPIC_BASE_URL", a.base_url),
            ("ANTHROPIC_AUTH_TOKEN", a.token),
            ("ANTHROPIC_MODEL", a.model),
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", a.model),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", a.model),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL", a.model),
        ]
        names = set(n for n, _ in values)
        kept = [e for e in env if not (isinstance(e, dict) and e.get("name") in names)]
        for e in kept:
            if isinstance(e, dict) and str(e.get("name", "")).startswith(("ANTHROPIC_", "CLAUDE_CODE_USE_")):
                print("NOTE: existing entry %s was left in place; check it does not conflict" % e.get("name"))
        kept.extend({"name": n, "value": v} for n, v in values)
        data[ENV_KEY] = kept
        if a.drop_selected_model and MODEL_KEY in data:
            print("REMOVED: %s (was %r)" % (MODEL_KEY, data.pop(MODEL_KEY)))
        save(a.path, data)
        print("OK: wrote %d environment entries to %s" % (len(values), a.path))
    else:
        def is_ours(e):
            if not isinstance(e, dict) or e.get("name") not in OURS:
                return False
            if e.get("name") == "ANTHROPIC_BASE_URL":
                v = str(e.get("value", ""))
                return v.startswith("http://127.0.0.1") or v.startswith("http://localhost")
            return True
        kept = [e for e in env if not is_ours(e)]
        removed = len(env) - len(kept)
        if ENV_KEY in data:
            if kept:
                data[ENV_KEY] = kept
            else:
                del data[ENV_KEY]
        if removed:
            save(a.path, data)
        print("OK: removed %d entries" % removed)


if __name__ == "__main__":
    main()
PYEOF
}

# ---------- control script written into the install dir ----------------------
write_control_script() {
  cat > "$1" <<'CTLEOF'
#!/usr/bin/env bash
# dahl-proxy.sh - control the local Anthropic -> Dahl translation proxy
#   ./dahl-proxy.sh start | stop | restart | status | logs | run
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$DIR/.env" ]] || { echo "Missing $DIR/.env"; exit 1; }
set -a; . "$DIR/.env"; set +a
HOST="127.0.0.1"
PORT="${PROXY_PORT:-4000}"
PIDFILE="$DIR/proxy.pid"
LOG="$DIR/proxy.log"

if [[ -x "$DIR/venv/bin/litellm" ]]; then LITELLM="$DIR/venv/bin/litellm"
elif [[ -x "$DIR/venv/Scripts/litellm.exe" ]]; then LITELLM="$DIR/venv/Scripts/litellm.exe"
else echo "litellm not found in $DIR/venv"; exit 1; fi

http_code() {
  # curl prints 000 itself when the connection fails, so do not echo a second one.
  local c
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOST:$PORT/health/liveliness" 2>/dev/null)"
  printf '%s' "${c:-000}"
}
is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

wait_ready() {
  local i=0 max="${1:-120}"
  while (( i < max )); do
    if ! is_running && [[ "$(http_code)" == "000" ]]; then
      echo; echo "Proxy exited early. Last log lines:"; tail -n 25 "$LOG"; return 1
    fi
    if [[ "$(http_code)" != "000" ]]; then echo; return 0; fi
    printf '.'; sleep 1; i=$((i + 1))
  done
  echo; echo "Timed out waiting for the proxy. Last log lines:"; tail -n 25 "$LOG"; return 1
}

cmd_start() {
  if [[ "$(http_code)" != "000" ]]; then
    echo "Proxy already responding on http://$HOST:$PORT"; return 0
  fi
  : >>"$LOG"
  nohup "$LITELLM" --config "$DIR/config.yaml" --host "$HOST" --port "$PORT" >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  disown 2>/dev/null || true
  printf 'Starting proxy'
  wait_ready 120 && echo "Proxy is up at http://$HOST:$PORT"
}

cmd_stop() {
  if is_running; then
    local pid; pid="$(cat "$PIDFILE")"
    kill "$pid" 2>/dev/null
    local i=0
    while kill -0 "$pid" 2>/dev/null && (( i < 10 )); do sleep 1; i=$((i + 1)); done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    echo "Proxy stopped."
  else
    rm -f "$PIDFILE"
    if [[ "$(http_code)" != "000" ]]; then
      echo "A proxy is responding on port $PORT but was not started by this script (service manager?)."
    else
      echo "Proxy is not running."
    fi
  fi
}

cmd_status() {
  if [[ "$(http_code)" != "000" ]]; then
    echo "Proxy is responding on http://$HOST:$PORT"
    if is_running; then echo "PID $(cat "$PIDFILE")"; fi
    return 0
  else
    echo "Proxy is NOT responding on http://$HOST:$PORT"; return 1
  fi
}

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status)  cmd_status ;;
  logs)    tail -n 50 -f "$LOG" ;;
  run)     exec "$LITELLM" --config "$DIR/config.yaml" --host "$HOST" --port "$PORT" ;;
  *) echo "Usage: $0 {start|stop|restart|status|logs|run}"; exit 2 ;;
esac
CTLEOF
  chmod +x "$1"
}

# =============================================================================
# State shared between steps
# =============================================================================
DIR=""; PORT=""; ALIAS=""; MODEL_ID=""; DAHL_API_KEY=""
SAVED_KEY=""; SAVED_PORT=""; SAVED_ALIAS=""; SAVED_MODEL=""
SETTINGS_FILE=""; VPY=""

banner() {
  printf '%s' "$C_BOLD"
  cat <<EOF

  Claude Code  ->  Dahl Inference    (setup v$VERSION)

EOF
  printf '%s' "$C_RESET"
  cat <<'EOF'
  Claude Code speaks the Anthropic API. Dahl speaks the OpenAI API.
  This script installs a local translation proxy (LiteLLM) between them
  and points the VS Code extension at it.

  Every step first checks what is already done, so it is safe to re-run.
  Nothing outside the install folder and your VS Code user settings is
  modified, and settings.json is backed up before any change.

EOF
}

# ---------- Step 1: preflight ------------------------------------------------
step_preflight() {
  step "1/10: Preflight checks"
  detect_os
  chk "Operating system"
  case "$OS" in
    linux)   ok "Linux" ;;
    mac)     ok "macOS" ;;
    windows) ok "Windows (Git Bash/MSYS). Support is best effort." ;;
    wsl)     ok "WSL. Note: VS Code on Windows keeps its settings on the Windows side." ;;
    *)       warn "Unrecognized OS ($(uname -s)). Continuing, but some steps may need manual help." ;;
  esac

  chk "curl"
  command -v curl >/dev/null 2>&1 || die "curl is required. Install it with your package manager and re-run."
  ok "curl found"

  chk "Python 3.9+"
  if ! pick_python; then
    die "Python 3 was not found. Install Python 3.9 or newer from https://www.python.org/downloads/ and re-run."
  fi
  if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    die "Python $("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])') is too old. LiteLLM needs Python 3.9 or newer."
  fi
  local pyv; pyv="$("$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
  if "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    ok "Python $pyv ($PY)"
  else
    ok "Python $pyv ($PY)"; warn "Python 3.10+ is recommended. Continuing anyway."
  fi

  chk "Python venv module"
  if "$PY" -c 'import venv, ensurepip' >/dev/null 2>&1; then
    ok "venv and ensurepip available"
  else
    warn "The venv module looks incomplete."
    warn "On Debian/Ubuntu run: sudo apt install python3-venv python3-pip"
    ask_yn "Continue anyway?" n || exit 1
  fi

  chk "Reaching Dahl ($DAHL_BASE/models)"
  local code
  code="$(curl -sS --max-time 20 -o "$TMP/models.json" -w '%{http_code}' "$DAHL_BASE/models" 2>"$TMP/curl.err")" || code="000"
  if [[ "$code" == "200" ]]; then
    ok "Dahl is reachable"
  else
    warn "Could not reach Dahl (HTTP $code). $(head -c 200 "$TMP/curl.err" 2>/dev/null)"
    ask_yn "Continue anyway? (you can type a model ID by hand later)" n || exit 1
  fi
}

# ---------- Step 2: location, port, alias ------------------------------------
step_location() {
  step "2/10: Install location, port, and model alias"
  DIR="$(expand_tilde "$(ask "Install folder" "$DEFAULT_DIR")")"
  mkdir -p "$DIR" || die "Cannot create $DIR"

  if [[ -f "$DIR/.env" ]]; then
    chk "Existing install found in $DIR"
    SAVED_KEY="$(sed -n "s/^DAHL_API_KEY='\(.*\)'$/\1/p" "$DIR/.env" | head -n 1)"
    SAVED_PORT="$(sed -n "s/^PROXY_PORT='\(.*\)'$/\1/p" "$DIR/.env" | head -n 1)"
    if [[ -f "$DIR/config.yaml" ]]; then
      SAVED_ALIAS="$(sed -n 's/^ *- model_name: *//p' "$DIR/config.yaml" | head -n 1)"
      SAVED_MODEL="$(sed -n 's/^ *model: openai\///p' "$DIR/config.yaml" | head -n 1)"
    fi
    ok "Saved settings: port=${SAVED_PORT:-?}, alias=${SAVED_ALIAS:-?}, model=${SAVED_MODEL:-?}"
  else
    chk "No previous install in $DIR (fresh setup)"
  fi

  local def_port="${SAVED_PORT:-$DEFAULT_PORT}"
  while true; do
    PORT="$(ask "Local proxy port" "$def_port")"
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
      warn "Pick a number between 1024 and 65535."; continue
    fi
    if port_in_use "$PORT"; then
      if [[ -f "$DIR/proxy.pid" ]] && kill -0 "$(cat "$DIR/proxy.pid" 2>/dev/null)" 2>/dev/null; then
        ok "Port $PORT is in use by your existing proxy; it will be restarted later."; break
      fi
      warn "Port $PORT is already in use by another program. Pick another."; continue
    fi
    ok "Port $PORT is free"; break
  done

  ALIAS="$(ask "Model alias Claude Code will use (any name, no spaces)" "${SAVED_ALIAS:-$DEFAULT_ALIAS}")"
  [[ "$ALIAS" =~ ^[A-Za-z0-9._-]+$ ]] || die "Alias may only contain letters, digits, dot, underscore, and dash."
}

# ---------- Step 3: choose model ---------------------------------------------
step_model() {
  step "3/10: Choose the Dahl model"
  chk "Reading Dahl's live model list (model IDs change as models rotate)"
  local ids=() line out
  if [[ -s "$TMP/models.json" ]]; then
    out="$("$PY" - "$TMP/models.json" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
items = d.get("data", d) if isinstance(d, dict) else d
for m in items:
    print(m.get("id") if isinstance(m, dict) else m)
PYEOF
)"
    while IFS= read -r line; do
      [[ -n "$line" ]] && ids+=("$line")
    done <<< "$out"
  fi

  if [[ ${#ids[@]} -eq 0 ]]; then
    warn "Could not read the model list."
    MODEL_ID="$(ask "Type the exact model ID" "${SAVED_MODEL:-deepseek-ai/DeepSeek-V4-Flash-0731}")"
    [[ -n "$MODEL_ID" ]] || die "No model given."
    return 0
  fi

  local i default_idx=1 n=${#ids[@]}
  printf '\n  Models currently offered:\n'
  for ((i = 0; i < n; i++)); do
    printf '   %2d) %s\n' "$((i + 1))" "${ids[$i]}"
    if [[ "${ids[$i]}" == "$SAVED_MODEL" ]]; then
      default_idx=$((i + 1))
    elif [[ -z "$SAVED_MODEL" && "$default_idx" -eq 1 ]] && printf '%s' "${ids[$i]}" | grep -qi "$MODEL_HINT"; then
      default_idx=$((i + 1))
    fi
  done
  printf '\n'

  local choice
  while true; do
    choice="$(ask "Pick a number, or type a model ID" "$default_idx")"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      MODEL_ID="${ids[$((choice - 1))]}"; break
    fi
    local found=""
    for ((i = 0; i < n; i++)); do
      [[ "${ids[$i]}" == "$choice" ]] && found="$choice"
    done
    if [[ -n "$found" ]]; then MODEL_ID="$found"; break; fi
    warn "That is not in Dahl's current list."
  done
  ok "Selected: $MODEL_ID"
  case "$MODEL_ID" in
    *[Ff]lash*|*MiniMax*|*minimax*) : ;;
    *) warn "Dahl's docs say tool calling is only confirmed for MiniMax and DeepSeek Flash. Claude Code depends on tools." ;;
  esac
}

# ---------- Step 4: API key --------------------------------------------------
step_key() {
  step "4/10: Dahl API key"
  chk "Looking for a saved key"
  if [[ -n "$SAVED_KEY" ]]; then
    ok "A key is already saved in $DIR/.env"
    if ask_yn "Reuse the saved key?" y; then DAHL_API_KEY="$SAVED_KEY"; fi
  else
    chk "None saved yet"
  fi

  local key code
  while true; do
    if [[ -z "$DAHL_API_KEY" ]]; then
      key="$(ask_secret "Paste your Dahl API key (input is hidden)")"
      if [[ -z "$key" || "$key" =~ [[:space:]] || "$key" == *\'* || "$key" == *\"* || "$key" == *\\* || "$key" == *\$* || "$key" == *\`* ]]; then
        warn "That does not look like a plain API key (empty, or has spaces/quotes). Try again."; continue
      fi
      DAHL_API_KEY="$key"
    fi

    chk "Validating the key with a real request to Dahl (uses a few tokens)"
    code="$(dahl_chat_test "$DAHL_API_KEY" "$MODEL_ID")"
    case "$code" in
      200) ok "Key works and the model answered."; return 0 ;;
      401) err "Dahl rejected the key (401). Check you copied the whole key." ;;
      402) warn "The key is valid but has no tokens allocated (402)."
           warn "Allocate tokens to this key on your Dahl account page, then continue."
           if ask_yn "Continue setup anyway?" y; then return 0; fi ;;
      400) err "Dahl says the model is not offered (400): $(head -c 300 "$TMP/chat.json")"
           die "Re-run the script and pick a model from the live list." ;;
      000) err "Network error talking to Dahl: $(head -c 200 "$TMP/curl.err")" ;;
      *)   err "Unexpected response $code: $(head -c 300 "$TMP/chat.json")" ;;
    esac
    DAHL_API_KEY=""
    ask_yn "Try a different key?" y || die "Cannot continue without a working key."
  done
}

# ---------- Step 5: venv + LiteLLM -------------------------------------------
resolve_venv_python() {
  if [[ -x "$DIR/venv/bin/python" ]]; then VPY="$DIR/venv/bin/python"
  elif [[ -x "$DIR/venv/Scripts/python.exe" ]]; then VPY="$DIR/venv/Scripts/python.exe"
  else VPY=""; fi
}

step_install() {
  step "5/10: Python environment and LiteLLM"
  chk "Virtual environment in $DIR/venv"
  resolve_venv_python
  if [[ -n "$VPY" ]]; then
    ok "Virtual environment already exists"
  else
    info "Creating it..."
    "$PY" -m venv "$DIR/venv" >"$TMP/venv.log" 2>&1 || { cat "$TMP/venv.log" >&2; die "Could not create the virtual environment."; }
    resolve_venv_python
    [[ -n "$VPY" ]] || die "Virtual environment was created but its Python was not found."
    ok "Created"
  fi

  chk "LiteLLM with proxy extras"
  if "$VPY" -c 'import litellm, fastapi, uvicorn' >/dev/null 2>&1; then
    local ver; ver="$("$VPY" -m pip show litellm 2>/dev/null | sed -n 's/^Version: //p')"
    ok "Already installed (litellm ${ver:-unknown})"
    if ask_yn "Upgrade it to the latest version?" n; then
      info "Upgrading (this can take a few minutes)"
      run_quiet "$DIR/pip-install.log" "$VPY" -m pip install --upgrade 'litellm[proxy]' \
        || { tail -n 20 "$DIR/pip-install.log" >&2; die "Upgrade failed. Full log: $DIR/pip-install.log"; }
      ok "Upgraded"
    fi
  else
    info "Installing litellm[proxy] (first time takes a few minutes)"
    run_quiet "$DIR/pip-install.log" "$VPY" -m pip install --upgrade pip \
      || warn "pip self-upgrade failed; continuing."
    run_quiet "$DIR/pip-install.log" "$VPY" -m pip install --upgrade 'litellm[proxy]' \
      || { tail -n 20 "$DIR/pip-install.log" >&2; die "Install failed. Full log: $DIR/pip-install.log"; }
    "$VPY" -c 'import litellm, fastapi, uvicorn' >/dev/null 2>&1 \
      || die "LiteLLM installed but could not be imported. See $DIR/pip-install.log"
    ok "Installed"
  fi

  if [[ -x "$DIR/venv/bin/litellm" || -x "$DIR/venv/Scripts/litellm.exe" ]]; then
    ok "litellm command is present"
  else
    die "The litellm command was not created. See $DIR/pip-install.log"
  fi
}

# ---------- Step 6: files ----------------------------------------------------
step_files() {
  step "6/10: Writing configuration files"

  chk "Secrets file $DIR/.env"
  ( umask 077
    {
      printf "DAHL_API_KEY='%s'\n" "$DAHL_API_KEY"
      printf "PROXY_PORT='%s'\n" "$PORT"
      # Newer LiteLLM routes Claude Code's requests for openai/ models to the OpenAI
      # Responses API. Dahl's proven endpoint is /v1/chat/completions, so force that route.
      printf "LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES='true'\n"
    } > "$DIR/.env" )
  chmod 600 "$DIR/.env" 2>/dev/null || true
  ok "Saved (permissions restricted to you)"

  chk "Proxy config $DIR/config.yaml"
  if [[ -f "$DIR/config.yaml" ]]; then
    cp "$DIR/config.yaml" "$DIR/config.yaml.bak" 2>/dev/null && info "Previous config saved as config.yaml.bak"
  fi
  cat > "$DIR/config.yaml" <<EOF
# Generated by setup-claude-code-dahl.sh v$VERSION
# Claude Code asks for the alias below; LiteLLM forwards to Dahl's OpenAI-style API.
model_list:
  - model_name: $ALIAS
    litellm_params:
      model: openai/$MODEL_ID
      api_base: $DAHL_BASE
      api_key: os.environ/DAHL_API_KEY

litellm_settings:
  # Claude Code sends some Anthropic-only parameters; drop what the backend does not support.
  drop_params: true
EOF
  ok "Written (alias '$ALIAS' -> $MODEL_ID)"

  chk "Control script $DIR/dahl-proxy.sh"
  write_control_script "$DIR/dahl-proxy.sh"
  write_settings_helper "$DIR/vscode_settings.py"
  ok "Written (start/stop/status/logs)"
}

# ---------- Step 7: start proxy ----------------------------------------------
step_start() {
  step "7/10: Starting the proxy"
  chk "Is the proxy already answering on port $PORT?"
  if "$DIR/dahl-proxy.sh" status >/dev/null 2>&1; then
    ok "Yes, restarting it so it picks up the new config"
    "$DIR/dahl-proxy.sh" stop >/dev/null 2>&1 || true
    sleep 1
  else
    chk "No"
  fi
  if port_in_use "$PORT"; then
    die "Port $PORT is busy and not owned by this proxy. Stop whatever uses it, or re-run and choose another port."
  fi
  "$DIR/dahl-proxy.sh" start || die "The proxy did not start. Log: $DIR/proxy.log"
  ok "Proxy is running at http://$PROXY_HOST:$PORT"
}

# ---------- Step 8: tests through the proxy ----------------------------------
step_test() {
  step "8/10: Testing the proxy the way Claude Code will use it"
  local url="http://$PROXY_HOST:$PORT/v1/messages" body code

  chk "Test A: normal Anthropic-format request"
  body="$("$PY" -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 300, "messages": [{"role": "user", "content": "Reply with exactly: proxy ok"}]}))' "$ALIAS")"
  code="$(curl -sS --max-time 180 -o "$TMP/msg.json" -w '%{http_code}' \
    -H "x-api-key: $PROXY_TOKEN" -H 'anthropic-version: 2023-06-01' -H 'Content-Type: application/json' \
    -d "$body" "$url" 2>"$TMP/curl.err")" || code="000"
  if [[ "$code" == "200" ]]; then
    local reply
    reply="$("$PY" - "$TMP/msg.json" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
t = [b.get("text", "") for b in d.get("content", []) if b.get("type") == "text"]
print((t[0] if t else "(no text block; raw: %s)" % json.dumps(d)[:200]).strip()[:200])
PYEOF
)"
    ok "HTTP 200. Model said: ${reply:-?}"
  else
    err "HTTP $code from the proxy: $(head -c 400 "$TMP/msg.json" 2>/dev/null) $(head -c 200 "$TMP/curl.err" 2>/dev/null)"
    err "Last proxy log lines:"; tail -n 20 "$DIR/proxy.log" >&2
    die "The proxy test failed. Fix this before configuring VS Code. Log: $DIR/proxy.log"
  fi

  chk "Test B: streaming (Claude Code always streams)"
  body="$("$PY" -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "max_tokens": 200, "stream": True, "messages": [{"role": "user", "content": "Count from 1 to 5."}]}))' "$ALIAS")"
  curl -sS -N --max-time 180 -H "x-api-key: $PROXY_TOKEN" -H 'anthropic-version: 2023-06-01' \
    -H 'Content-Type: application/json' -d "$body" "$url" >"$TMP/stream.txt" 2>/dev/null
  if grep -q 'content_block_delta' "$TMP/stream.txt" && grep -q 'message_stop' "$TMP/stream.txt"; then
    ok "Streaming events arrived in Anthropic format"
  else
    warn "Streaming looks off. First lines received:"; head -n 8 "$TMP/stream.txt" >&2
    ask_yn "Continue anyway?" n || exit 1
  fi

  chk "Test C: tool calling (Claude Code needs it to edit files and run commands)"
  body="$("$PY" -c '
import json, sys
print(json.dumps({
  "model": sys.argv[1], "max_tokens": 300,
  "tools": [{"name": "get_time", "description": "Get the current time in an IANA time zone",
             "input_schema": {"type": "object", "properties": {"zone": {"type": "string"}}, "required": ["zone"]}}],
  "messages": [{"role": "user", "content": "Call the get_time tool for the zone Africa/Lagos. Do not answer without calling it."}]}))' "$ALIAS")"
  code="$(curl -sS --max-time 180 -o "$TMP/tool.json" -w '%{http_code}' \
    -H "x-api-key: $PROXY_TOKEN" -H 'anthropic-version: 2023-06-01' -H 'Content-Type: application/json' \
    -d "$body" "$url" 2>/dev/null)" || code="000"
  if [[ "$code" == "200" ]] && grep -q '"tool_use"' "$TMP/tool.json"; then
    ok "The model made a tool call and the proxy translated it correctly"
  else
    warn "Tool calling was inconclusive (HTTP $code). Claude Code may chat but fail to edit files or run commands."
    warn "Try a different model from the list, or re-run this script later. Details: $(head -c 250 "$TMP/tool.json" 2>/dev/null)"
    ask_yn "Continue anyway?" y || exit 1
  fi
}

# ---------- Step 9: VS Code settings -----------------------------------------
vscode_base_dir() {
  case "$OS" in
    linux)   printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}" ;;
    mac)     printf '%s' "$HOME/Library/Application Support" ;;
    windows)
      if command -v cygpath >/dev/null 2>&1 && [[ -n "${APPDATA:-}" ]]; then cygpath -u "$APPDATA"
      else printf '%s' "${APPDATA:-$HOME/AppData/Roaming}"; fi ;;
    wsl)
      local a
      a="$(cmd.exe /c 'echo %APPDATA%' 2>/dev/null | tr -d '\r')"
      if [[ -n "$a" ]] && command -v wslpath >/dev/null 2>&1; then wslpath -u "$a"; fi ;;
    *)       printf '%s' "$HOME/.config" ;;
  esac
}

choose_settings_file() {
  # Sets SETTINGS_FILE. Honors $VSCODE_SETTINGS_FILE for power users.
  if [[ -n "${VSCODE_SETTINGS_FILE:-}" ]]; then
    SETTINGS_FILE="$VSCODE_SETTINGS_FILE"; ok "Using VSCODE_SETTINGS_FILE: $SETTINGS_FILE"; return 0
  fi
  local base v cand=() i n choice
  base="$(vscode_base_dir)"
  if [[ -n "$base" ]]; then
    for v in "Code" "Code - Insiders" "VSCodium"; do
      [[ -d "$base/$v/User" ]] && cand+=("$base/$v/User/settings.json")
    done
  fi
  n=${#cand[@]}
  if [[ $n -eq 0 ]]; then
    warn "Could not find a VS Code user settings folder automatically."
    SETTINGS_FILE="$(expand_tilde "$(ask "Full path to your VS Code user settings.json")")"
    [[ -n "$SETTINGS_FILE" ]] || die "No settings path given."
    return 0
  fi
  if [[ $n -eq 1 ]]; then
    ok "Found: ${cand[0]}"
    if ask_yn "Use this file?" y; then SETTINGS_FILE="${cand[0]}"; return 0; fi
    SETTINGS_FILE="$(expand_tilde "$(ask "Full path to settings.json")")"; return 0
  fi
  printf '\n  VS Code installations found:\n'
  for ((i = 0; i < n; i++)); do printf '   %d) %s\n' "$((i + 1))" "${cand[$i]}"; done
  printf '\n'
  while true; do
    choice="$(ask "Which one?" "1")"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
      SETTINGS_FILE="${cand[$((choice - 1))]}"; return 0
    fi
    warn "Enter a number from the list."
  done
}

print_manual_snippet() {
  local snippet="$DIR/vscode-snippet.json"
  cat > "$snippet" <<EOF
"claudeCode.environmentVariables": [
    { "name": "ANTHROPIC_BASE_URL", "value": "http://$PROXY_HOST:$PORT" },
    { "name": "ANTHROPIC_AUTH_TOKEN", "value": "$PROXY_TOKEN" },
    { "name": "ANTHROPIC_MODEL", "value": "$ALIAS" },
    { "name": "ANTHROPIC_DEFAULT_SONNET_MODEL", "value": "$ALIAS" },
    { "name": "ANTHROPIC_DEFAULT_OPUS_MODEL", "value": "$ALIAS" },
    { "name": "ANTHROPIC_DEFAULT_HAIKU_MODEL", "value": "$ALIAS" }
]
EOF
  printf '\n%sAdd this to your settings.json manually%s (also saved to %s):\n\n' "$C_BOLD" "$C_RESET" "$snippet"
  cat "$snippet"
  printf '\nOpen it with: Ctrl/Cmd+Shift+P -> "Preferences: Open User Settings (JSON)".\n'
  printf 'If a "claudeCode.selectedModel" entry exists, delete it so it does not conflict.\n'
}

step_vscode() {
  step "9/10: VS Code user settings"
  chk "Locating settings.json"
  choose_settings_file

  chk "Current state of $SETTINGS_FILE"
  if [[ -f "$SETTINGS_FILE" ]]; then
    if grep -q '"claudeCode.environmentVariables"' "$SETTINGS_FILE" 2>/dev/null; then
      info "It already has a claudeCode.environmentVariables entry; ours will be merged in, other entries kept."
    else
      info "No claudeCode.environmentVariables entry yet."
    fi
  else
    info "File does not exist yet; it will be created."
  fi

  local drop_args=()
  if [[ -f "$SETTINGS_FILE" ]] && grep -q '"claudeCode.selectedModel"' "$SETTINGS_FILE" 2>/dev/null; then
    info "A claudeCode.selectedModel entry exists. It would override the alias."
    if ask_yn "Remove claudeCode.selectedModel?" y; then drop_args=(--drop-selected-model); fi
  fi

  if ! ask_yn "Apply the changes now? (a timestamped backup is made first)" y; then
    info "Skipped. Here is what to add by hand."
    print_manual_snippet; return 0
  fi

  local out rc strip_args=()
  while true; do
    out="$("$PY" "$DIR/vscode_settings.py" "$SETTINGS_FILE" apply \
      --base-url "http://$PROXY_HOST:$PORT" --token "$PROXY_TOKEN" --model "$ALIAS" \
      ${drop_args[@]+"${drop_args[@]}"} ${strip_args[@]+"${strip_args[@]}"} 2>&1)"; rc=$?
    case "$rc" in
      0) printf '%s\n' "$out" | sed 's/^/  /'; ok "VS Code settings updated"; break ;;
      3) warn "Your settings.json contains comments or trailing commas, which this script cannot preserve."
         if ask_yn "Rewrite it without comments? (backup is kept; formatting becomes standard JSON)" n; then
           strip_args=(--allow-strip); continue
         fi
         print_manual_snippet; break ;;
      *) err "Could not edit settings automatically:"; printf '%s\n' "$out" | sed 's/^/  /' >&2
         print_manual_snippet; break ;;
    esac
  done
  info "Reload VS Code to apply: Ctrl/Cmd+Shift+P -> \"Developer: Reload Window\"."
}

# ---------- Step 10: auto-start ----------------------------------------------
write_systemd_unit() {
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Anthropic-to-Dahl translation proxy for Claude Code
After=network-online.target

[Service]
Type=simple
ExecStart="$DIR/dahl-proxy.sh" run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

write_launchd_plist() {
  local plist="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$DIR/dahl-proxy.sh</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/proxy.log</string>
  <key>StandardErrorPath</key><string>$DIR/proxy.log</string>
</dict>
</plist>
EOF
  printf '%s' "$plist"
}

step_autostart() {
  step "10/10: Start the proxy automatically at login (optional)"
  chk "Is auto-start already configured?"
  if [[ "$OS" == "linux" || "$OS" == "wsl" ]] && command -v systemctl >/dev/null 2>&1 \
     && systemctl --user is-enabled "$SERVICE_NAME.service" >/dev/null 2>&1; then
    ok "A systemd user service is already enabled"
    if ! ask_yn "Re-create it with the current settings?" n; then return 0; fi
  elif [[ "$OS" == "mac" && -f "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist" ]]; then
    ok "A launchd agent already exists"
    if ! ask_yn "Re-create it with the current settings?" n; then return 0; fi
  else
    chk "Not configured"
  fi

  if ! ask_yn "Start the proxy automatically when you log in?" y; then
    info "Skipped. After a reboot, start it with: $DIR/dahl-proxy.sh start"; return 0
  fi

  if [[ "$OS" == "linux" || "$OS" == "wsl" ]] && command -v systemctl >/dev/null 2>&1 \
     && systemctl --user show-environment >/dev/null 2>&1; then
    "$DIR/dahl-proxy.sh" stop >/dev/null 2>&1 || true
    write_systemd_unit
    systemctl --user daemon-reload
    if systemctl --user enable --now "$SERVICE_NAME.service" >"$TMP/sd.log" 2>&1; then
      info "Waiting for the service to answer"
      local i=0
      while (( i < 90 )); do
        if "$DIR/dahl-proxy.sh" status >/dev/null 2>&1; then ok "systemd service is running"; return 0; fi
        printf '.'; sleep 1; i=$((i + 1))
      done
      printf '\n'; warn "Service enabled but not answering yet. Check: journalctl --user -u $SERVICE_NAME -n 30"
    else
      cat "$TMP/sd.log" >&2
      warn "Could not enable the service; starting the proxy manually instead."
      "$DIR/dahl-proxy.sh" start
    fi
  elif [[ "$OS" == "mac" ]]; then
    "$DIR/dahl-proxy.sh" stop >/dev/null 2>&1 || true
    local plist; plist="$(write_launchd_plist)"
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$plist" >"$TMP/lc.log" 2>&1 || launchctl load -w "$plist" >>"$TMP/lc.log" 2>&1; then
      local i=0
      while (( i < 90 )); do
        if "$DIR/dahl-proxy.sh" status >/dev/null 2>&1; then ok "launchd agent is running"; return 0; fi
        printf '.'; sleep 1; i=$((i + 1))
      done
      printf '\n'; warn "Agent loaded but the proxy is not answering yet. Check $DIR/proxy.log"
    else
      cat "$TMP/lc.log" >&2
      warn "Could not load the launchd agent; starting the proxy manually instead."
      "$DIR/dahl-proxy.sh" start
    fi
  else
    warn "Automatic start is not supported for this OS by this script."
    info "On Windows, create a Task Scheduler task that runs: bash \"$DIR/dahl-proxy.sh\" start"
  fi
}

# ---------- final summary ----------------------------------------------------
summary() {
  printf '\n%s%s━━ All done ━━%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  cat <<EOF
  Proxy URL        http://$PROXY_HOST:$PORT
  Model alias      $ALIAS  ->  $MODEL_ID
  Install folder   $DIR
  VS Code settings ${SETTINGS_FILE:-(not changed)}

  Next:
    1. In VS Code run "Developer: Reload Window", then open the Claude Code panel.
    2. Send a short message. You should see the request in:  $DIR/proxy.log

  Manage the proxy:
    $DIR/dahl-proxy.sh status | start | stop | restart | logs

  Good to know:
    - The proxy must be running whenever you use Claude Code (unless you enabled auto-start).
    - It listens on $PROXY_HOST only, so other machines cannot reach it.
    - Your Dahl key lives only in $DIR/.env (readable by you only), not in settings.json.
    - Dahl rotates model IDs. If you get a "model not offered" error, re-run this script
      and pick a model from the live list.
    - Dahl's docs say vision is not offered, so pasted images will not work.
    - To undo everything: $0 uninstall
EOF
}

# =============================================================================
# Commands
# =============================================================================
cmd_install() {
  [[ -t 0 ]] || die "This script is interactive. Run it directly in a terminal."
  banner
  ask_yn "Ready to begin?" y || { info "Nothing changed."; exit 0; }
  step_preflight
  step_location
  step_model
  step_key
  step_install
  step_files
  step_start
  step_test
  step_vscode
  step_autostart
  summary
}

cmd_status() {
  DIR="$(expand_tilde "${1:-$DEFAULT_DIR}")"
  [[ -x "$DIR/dahl-proxy.sh" ]] || die "No install found in $DIR"
  "$DIR/dahl-proxy.sh" status
}

cmd_uninstall() {
  [[ -t 0 ]] || die "This script is interactive. Run it directly in a terminal."
  detect_os; pick_python || die "Python 3 is needed to edit VS Code settings."
  printf '\n%sUninstall%s\n' "$C_BOLD" "$C_RESET"
  DIR="$(expand_tilde "$(ask "Install folder to remove" "$DEFAULT_DIR")")"
  [[ -d "$DIR" ]] || warn "$DIR does not exist; will still clean up settings and services."

  chk "Proxy process"
  if [[ -x "$DIR/dahl-proxy.sh" ]]; then "$DIR/dahl-proxy.sh" stop || true; fi

  chk "Auto-start service"
  if command -v systemctl >/dev/null 2>&1 && systemctl --user list-unit-files "$SERVICE_NAME.service" 2>/dev/null | grep -q "$SERVICE_NAME"; then
    if ask_yn "Disable and remove the systemd user service?" y; then
      systemctl --user disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
      rm -f "$HOME/.config/systemd/user/$SERVICE_NAME.service"
      systemctl --user daemon-reload 2>/dev/null || true
      ok "Removed systemd service"
    fi
  fi
  if [[ "$OS" == "mac" && -f "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist" ]]; then
    if ask_yn "Unload and remove the launchd agent?" y; then
      launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || launchctl unload "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist" >/dev/null 2>&1 || true
      rm -f "$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
      ok "Removed launchd agent"
    fi
  fi

  chk "VS Code settings"
  if ask_yn "Remove the Claude Code proxy entries from VS Code settings?" y; then
    choose_settings_file
    local helper="$TMP/vscode_settings.py" out rc strip_args=()
    write_settings_helper "$helper"
    while true; do
      out="$("$PY" "$helper" "$SETTINGS_FILE" remove ${strip_args[@]+"${strip_args[@]}"} 2>&1)"; rc=$?
      if [[ $rc -eq 0 ]]; then printf '%s\n' "$out" | sed 's/^/  /'; ok "Settings cleaned"; break; fi
      if [[ $rc -eq 3 ]] && ask_yn "settings.json has comments. Rewrite without them (backup kept)?" n; then strip_args=(--allow-strip); continue; fi
      warn "Could not edit settings automatically. Remove the ANTHROPIC_* entries from claudeCode.environmentVariables by hand."
      break
    done
  fi

  chk "Install folder (contains your saved Dahl key)"
  if [[ -d "$DIR" ]] && ask_yn "Delete $DIR including the saved API key?" y; then
    rm -rf "$DIR" && ok "Deleted $DIR"
  fi
  ok "Uninstall finished. Reload VS Code to apply."
}

usage() {
  cat <<EOF
Usage: $0 [command]

  install     Interactive setup (default)
  uninstall   Remove proxy, services, VS Code settings entries, and files
  status      Show whether the proxy is running
  help        Show this help

Advanced environment variables:
  VSCODE_SETTINGS_FILE   Use this settings.json instead of auto-detecting
  DAHL_BASE              Override the Dahl base URL (default $DAHL_BASE)
EOF
}

case "${1:-install}" in
  install)          cmd_install ;;
  uninstall)        cmd_uninstall ;;
  status)           cmd_status "${2:-}" ;;
  help|-h|--help)   usage ;;
  *)                usage; exit 2 ;;
esac
