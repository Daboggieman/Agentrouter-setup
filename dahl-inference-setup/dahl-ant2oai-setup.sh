```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# ant2oai / a2o + Claude Code Interactive Setup
# ============================================================
#
# Architecture:
#
#   Claude Code
#        │
#        │ Anthropic /v1/messages
#        ▼
#   a2o @ 127.0.0.1:3578
#        │
#        │ OpenAI /v1/chat/completions
#        ▼
#   OpenAI-compatible provider
#        │
#        ▼
#   Selected model
#
# This installer configures a2o and applies the compatibility
# fixes required for the current Claude Code + DeepSeek V4
# workflow.
#
# FEATURES
# --------
# 1. Interactive provider/base URL selection
# 2. Custom OpenAI-compatible endpoint support
# 3. Interactive API key entry
# 4. Interactive model selection
# 5. Custom local host/port
# 6. Creates/uses ~/ant2oia
# 7. Creates Python virtual environment
# 8. Installs/upgrades ant2oai
# 9. Backs up modified Python files
# 10. Patches parser.py
# 11. Patches request.py
# 12. Adds DeepSeek V4 DSML parser
# 13. Patches non-streaming DSML tool calls
# 14. Patches streaming DSML tool calls
# 15. Correctly returns Anthropic tool_use
# 16. Correctly returns stop_reason=tool_use
# 17. Tests the parser
# 18. Tests the response converter
# 19. Checks Python syntax
# 20. Configures VS Code Claude Code environment variables
# 21. Creates a secure local configuration file
# 22. Creates a convenient launcher
#
# NO SUDO / ROOT REQUIRED
#
# IMPORTANT
# ---------
# The API key is stored locally in:
#
#   ~/ant2oia/config.env
#
# with permissions 600.
#
# VS Code's Claude Code environmentVariables setting is also
# configured because Claude Code must send the key to a2o.
#
# ============================================================


# ============================================================
# CONFIGURATION
# ============================================================

INSTALL_DIR="$HOME/ant2oia"
VENV_DIR="$INSTALL_DIR/.venv"

A2O_HOST_DEFAULT="127.0.0.1"
A2O_PORT_DEFAULT="3578"

# Default provider
DEFAULT_BASE_URL="https://inference.dahl.global/v1/chat/completions"
DEFAULT_MODEL="deepseek-ai/DeepSeek-V4-Flash-0731"

# VS Code settings
VSCODE_SETTINGS="$HOME/.config/Code/User/settings.json"

# Persistent local configuration
CONFIG_FILE="$INSTALL_DIR/config.env"

# Launcher
LAUNCHER="$INSTALL_DIR/start-dahl-claude.sh"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"


# ============================================================
# COLORS / OUTPUT
# ============================================================

if [[ -t 1 ]]; then
    BLUE='\033[1;34m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    RED='\033[1;31m'
    CYAN='\033[1;36m'
    RESET='\033[0m'
else
    BLUE=''
    GREEN=''
    YELLOW=''
    RED=''
    CYAN=''
    RESET=''
fi


info() {
    printf '\n%b[INFO]%b %s\n' "$BLUE" "$RESET" "$1"
}

success() {
    printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$1"
}

error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$RESET" "$1" >&2
}

die() {
    error "$1"
    exit 1
}

section() {
    printf '\n'
    printf '%b============================================================%b\n' "$CYAN" "$RESET"
    printf '%b %s%b\n' "$CYAN" "$1" "$RESET"
    printf '%b============================================================%b\n' "$CYAN" "$RESET"
}


# ============================================================
# SAFE INPUT HELPERS
# ============================================================

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value

    printf '%s [%s]: ' "$prompt" "$default"
    read -r value

    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

prompt_required() {
    local prompt="$1"
    local value

    while true; do
        printf '%s: ' "$prompt"
        read -r value

        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return
        fi

        warn "This value cannot be empty."
    done
}

prompt_secret() {
    local prompt="$1"
    local value

    printf '%s: ' "$prompt"
    read -r -s value
    printf '\n'

    printf '%s' "$value"
}


# ============================================================
# BANNER
# ============================================================

clear 2>/dev/null || true

printf '%b\n' "$CYAN"
printf '%s\n' '╔══════════════════════════════════════════════════════════════╗'
printf '%s\n' '║       ant2oai / a2o + Claude Code Setup                   ║'
printf '%s\n' '║       Interactive OpenAI-Compatible Backend Setup          ║'
printf '%s\n' '╚══════════════════════════════════════════════════════════════╝'
printf '%b\n' "$RESET"

printf '\n'
printf '%s\n' 'This script will configure:'
printf '%s\n' '  Claude Code → a2o → OpenAI-compatible API → model'
printf '\n'
printf '%s\n' 'It also applies the compatibility fixes required for:'
printf '%s\n' '  • Claude Code system messages'
printf '%s\n' '  • Dahl endpoints that reject role=system'
printf '%s\n' '  • DeepSeek V4 DSML tool calls'
printf '%s\n' '  • Anthropic tool_use conversion'
printf '%s\n' '  • Streaming DSML tool calls'
printf '\n'


# ============================================================
# REQUIREMENTS
# ============================================================

section "Checking requirements"

command -v python3 >/dev/null 2>&1 \
    || die "python3 is not installed."

command -v curl >/dev/null 2>&1 \
    || die "curl is not installed."

PYTHON="$(command -v python3)"

info "Python: $PYTHON"
"$PYTHON" --version

if command -v code >/dev/null 2>&1; then
    success "VS Code command detected."
else
    warn "'code' command was not found."
    warn "The script can still modify VS Code settings.json directly."
fi

if command -v claude >/dev/null 2>&1; then
    success "Claude Code CLI detected."
else
    warn "'claude' command was not found."
    warn "This script will still configure the VS Code Claude Code extension."
fi


# ============================================================
# INSTALLATION DIRECTORY
# ============================================================

section "Installation directory"

mkdir -p "$INSTALL_DIR"

success "Installation directory: $INSTALL_DIR"


# ============================================================
# INTERACTIVE PROVIDER SELECTION
# ============================================================

section "Choose your OpenAI-compatible backend"

printf '\n'
printf '%s\n' 'Choose how a2o should reach your model:'
printf '\n'
printf '%s\n' '  1) Dahl Inference'
printf '%s\n' '     https://inference.dahl.global/v1/chat/completions'
printf '%s\n' '     Default model: DeepSeek-V4-Flash-0731'
printf '\n'
printf '%s\n' '  2) Custom OpenAI-compatible endpoint'
printf '%s\n' '     Enter your own /v1/chat/completions URL'
printf '\n'
printf '%s\n' '  3) Reuse previous configuration'
printf '%s\n' '     Load ~/ant2oia/config.env if it exists'
printf '\n'

while true; do
    printf 'Selection [1-3]: '
    read -r PROVIDER_CHOICE

    case "$PROVIDER_CHOICE" in
        1)
            BASE_URL="$DEFAULT_BASE_URL"
            MODEL="$DEFAULT_MODEL"
            PROVIDER_NAME="Dahl Inference"
            break
            ;;

        2)
            printf '\n'
            BASE_URL="$(prompt_required 'OpenAI-compatible chat completions URL')"

            printf '\n'
            MODEL="$(prompt_required 'Model name')"

            PROVIDER_NAME="Custom OpenAI-compatible provider"
            break
            ;;

        3)
            if [[ ! -f "$CONFIG_FILE" ]]; then
                warn "No previous configuration exists at:"
                warn "  $CONFIG_FILE"
                continue
            fi

            # shellcheck disable=SC1090
            source "$CONFIG_FILE"

            BASE_URL="${A2O_UPSTREAM:-$DEFAULT_BASE_URL}"
            MODEL="${A2O_MODEL:-$DEFAULT_MODEL}"
            A2O_HOST="${A2O_HOST:-$A2O_HOST_DEFAULT}"
            A2O_PORT="${A2O_PORT:-$A2O_PORT_DEFAULT}"
            API_KEY="${A2O_API_KEY:-}"

            PROVIDER_NAME="${A2O_PROVIDER_NAME:-Saved configuration}"

            success "Previous configuration loaded."
            break
            ;;

        *)
            warn "Please choose 1, 2, or 3."
            ;;
    esac
done


# ============================================================
# API KEY
# ============================================================

section "API key configuration"

printf '\n'
printf '%s\n' "Provider: $PROVIDER_NAME"
printf '%s\n' "Endpoint: $BASE_URL"
printf '%s\n' "Model:    $MODEL"
printf '\n'

printf '%s\n' 'The API key is used as the credential Claude Code sends'
printf '%s\n' 'to the local a2o proxy. a2o passes the authentication'
printf '%s\n' 'credential through to the configured upstream backend.'
printf '\n'

printf '%s\n' 'Choose:'
printf '%s\n' '  1) Enter an API key'
printf '%s\n' '  2) Use no API key / keyless endpoint'
printf '%s\n' '  3) Keep the previously saved API key'
printf '\n'

while true; do
    printf 'Selection [1-3]: '
    read -r KEY_CHOICE

    case "$KEY_CHOICE" in
        1)
            API_KEY="$(prompt_secret 'Enter API key')"

            if [[ -z "$API_KEY" ]]; then
                warn "An empty API key was entered."
                printf 'Continue with an empty key? [y/N]: '
                read -r CONFIRM_EMPTY

                if [[ ! "$CONFIRM_EMPTY" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi

            break
            ;;

        2)
            API_KEY=""
            break
            ;;

        3)
            if [[ -z "${API_KEY:-}" ]]; then
                warn "There is no previously saved API key."
                continue
            fi

            success "Using the previously saved API key."
            break
            ;;

        *)
            warn "Please choose 1, 2, or 3."
            ;;
    esac
done


# ============================================================
# LOCAL A2O SETTINGS
# ============================================================

section "Local a2o settings"

A2O_HOST="$(prompt_default 'Local a2o host' "${A2O_HOST:-$A2O_HOST_DEFAULT}")"
A2O_PORT="$(prompt_default 'Local a2o port' "${A2O_PORT:-$A2O_PORT_DEFAULT}")"

printf '\n'

if [[ ! "$A2O_PORT" =~ ^[0-9]+$ ]] || (( A2O_PORT < 1 || A2O_PORT > 65535 )); then
    die "Invalid port: $A2O_PORT"
fi


# ============================================================
# CONFIRM CONFIGURATION
# ============================================================

section "Configuration summary"

printf '%-22s %s\n' "Provider:" "$PROVIDER_NAME"
printf '%-22s %s\n' "Upstream URL:" "$BASE_URL"
printf '%-22s %s\n' "Model:" "$MODEL"
printf '%-22s %s\n' "Local host:" "$A2O_HOST"
printf '%-22s %s\n' "Local port:" "$A2O_PORT"
printf '%-22s %s\n' "API key:" "$([[ -n "$API_KEY" ]] && printf 'configured' || printf 'none')"
printf '%-22s %s\n' "Install directory:" "$INSTALL_DIR"
printf '%-22s %s\n' "VS Code settings:" "$VSCODE_SETTINGS"

printf '\n'
printf 'Continue with this configuration? [Y/n]: '
read -r CONFIRM

if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    printf 'Setup cancelled.\n'
    exit 0
fi


# ============================================================
# CREATE VENV
# ============================================================

section "Python virtual environment"

if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR"
    success "Virtual environment created."
else
    success "Existing virtual environment found."
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

success "Virtual environment activated."

VENV_PYTHON="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"


# ============================================================
# PIP
# ============================================================

section "Python packages"

info "Upgrading pip..."

"$VENV_PYTHON" -m pip install --upgrade pip

success "pip updated."


# ============================================================
# INSTALL ANT2OAI
# ============================================================

info "Installing/upgrading ant2oai..."

"$VENV_PYTHON" -m pip install --upgrade ant2oai

success "ant2oai installed."


# ============================================================
# LOCATE A2O
# ============================================================

section "Locating a2o"

A2O_PACKAGE="$(
    "$VENV_PYTHON" - <<'PY'
import a2o
from pathlib import Path

print(Path(a2o.__path__[0]))
PY
)"

[[ -d "$A2O_PACKAGE" ]] \
    || die "Could not locate installed a2o package."

PARSER_FILE="$A2O_PACKAGE/converters/parser.py"
REQUEST_FILE="$A2O_PACKAGE/converters/request.py"
RESPONSE_FILE="$A2O_PACKAGE/converters/response.py"
STREAMING_FILE="$A2O_PACKAGE/converters/streaming.py"
DSML_FILE="$A2O_PACKAGE/converters/dsml.py"

[[ -f "$PARSER_FILE" ]] \
    || die "parser.py not found: $PARSER_FILE"

[[ -f "$REQUEST_FILE" ]] \
    || die "request.py not found: $REQUEST_FILE"

[[ -f "$RESPONSE_FILE" ]] \
    || die "response.py not found: $RESPONSE_FILE"

[[ -f "$STREAMING_FILE" ]] \
    || die "streaming.py not found: $STREAMING_FILE"

info "a2o package:"
printf '  %s\n' "$A2O_PACKAGE"


# ============================================================
# BACKUP FUNCTION
# ============================================================

backup_file() {
    local file="$1"

    local backup="${file}.bak.${TIMESTAMP}"

    cp "$file" "$backup"

    printf '%s\n' "$backup"
}


# ============================================================
# BACKUPS
# ============================================================

section "Backing up a2o files"

PARSER_BACKUP="$(backup_file "$PARSER_FILE")"
REQUEST_BACKUP="$(backup_file "$REQUEST_FILE")"
RESPONSE_BACKUP="$(backup_file "$RESPONSE_FILE")"
STREAMING_BACKUP="$(backup_file "$STREAMING_FILE")"

success "parser.py backup:"
printf '  %s\n' "$PARSER_BACKUP"

success "request.py backup:"
printf '  %s\n' "$REQUEST_BACKUP"

success "response.py backup:"
printf '  %s\n' "$RESPONSE_BACKUP"

success "streaming.py backup:"
printf '  %s\n' "$STREAMING_BACKUP"


# ============================================================
# PATCH 1
# parser.py
#
# FIX:
#
# Claude Code can send system messages inside messages[].
#
# a2o expected:
#
#   system = top-level field
#
# We extract system messages from messages[] and merge them
# into the top-level system representation.
# ============================================================

section "Patch 1/4 — parser.py system-message compatibility"

"$VENV_PYTHON" - "$PARSER_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Already patched?
if "extracted_system: list[dict[str, Any]]" in text:
    print("parser.py already contains the system-message compatibility patch.")
    raise SystemExit(0)

old = '''    messages_raw = data.get("messages")
    _validate(
        messages_raw is not None and isinstance(messages_raw, list) and len(messages_raw) > 0,
        "'messages' must contain at least one entry",
    )
    assert isinstance(messages_raw, list)  # guaranteed by validation
    messages = _parse_messages(messages_raw)

    system = _parse_system(data.get("system"))
'''

new = '''    messages_raw = data.get("messages")
    _validate(
        messages_raw is not None and isinstance(messages_raw, list) and len(messages_raw) > 0,
        "'messages' must contain at least one entry",
    )
    assert isinstance(messages_raw, list)  # guaranteed by validation

    # Some Claude Code requests may contain system messages inside
    # the messages array. Anthropic normally represents system
    # instructions as a top-level "system" field, so extract them
    # before parsing the remaining user/assistant messages.
    extracted_system: list[dict[str, Any]] = []
    filtered_messages: list[dict[str, Any]] = []

    for i, raw in enumerate(messages_raw):
        _validate(isinstance(raw, dict), f"messages[{i}] must be a JSON object")

        if raw.get("role") == "system":
            content = raw.get("content")

            if isinstance(content, str):
                extracted_system.append({
                    "type": "text",
                    "text": content,
                })

            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        extracted_system.append(block)

            continue

        filtered_messages.append(raw)

    messages = _parse_messages(filtered_messages)

    system = _parse_system(data.get("system"))

    if extracted_system:
        extracted = _parse_system(extracted_system)

        if system is None:
            system = extracted

        elif isinstance(system, str) and isinstance(extracted, str):
            system = system + "\\n\\n" + extracted

        elif isinstance(system, list) and isinstance(extracted, list):
            system = system + extracted
'''

if old not in text:
    raise SystemExit(
        "Expected parser.py block was not found. "
        "The installed ant2oai version may have changed."
    )

path.write_text(text.replace(old, new, 1))

print("parser.py patched successfully.")
PY

success "parser.py patch complete."


# ============================================================
# PATCH 2
# request.py
#
# FIX:
#
# Dahl rejects:
#
#   {"role": "system"}
#
# System content is prepended to the first user message.
# ============================================================

section "Patch 2/4 — request.py system-role compatibility"

"$VENV_PYTHON" - "$REQUEST_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "Dahl's OpenAI-compatible endpoint does not accept" in text:
    print("request.py already contains the Dahl system-role compatibility patch.")
    raise SystemExit(0)

old_section = '''    # System
    system_text = _build_system(req)

    # Messages
'''

if old_section not in text:
    raise SystemExit(
        "Expected System/Messages section was not found in request.py."
    )

old_insert = '''    if system_text:
        body["messages"].insert(0, {"role": "system", "content": system_text})
'''

new_insert = '''    # Dahl's OpenAI-compatible endpoint does not accept
    # role="system". Preserve the system prompt by prepending
    # it to the first user message.
    if system_text and openai_messages:
        for message in openai_messages:
            if message.get("role") == "user":
                content = message.get("content", "")

                message["content"] = (
                    system_text + "\\n\\n" + content
                    if content
                    else system_text
                )

                break
'''

if old_insert not in text:
    raise SystemExit(
        "Original system-message insertion was not found in request.py. "
        "The installed ant2oai version may have changed."
    )

path.write_text(text.replace(old_insert, new_insert, 1))

print("request.py patched successfully.")
PY

success "request.py patch complete."


# ============================================================
# PATCH 3
# dsml.py
#
# DeepSeek V4 emits native DSML tool calls.
#
# Example:
#
# <｜DSML｜tool_calls>
# <｜DSML｜invoke name="read_file">
# <｜DSML｜parameter name="file_path">/tmp/test.txt</｜DSML｜parameter>
# <｜DSML｜parameter name="offset">3</｜DSML｜parameter>
# </｜DSML｜invoke>
# </｜DSML｜tool_calls>
#
# Claude Code expects Anthropic tool_use.
#
# This parser converts DSML into OpenAI-compatible tool_calls,
# which response.py and streaming.py then convert to Anthropic.
# ============================================================

section "Patch 3/4 — DeepSeek V4 DSML parser"

cat > "$DSML_FILE" <<'PY'
"""Parse DeepSeek V4 DSML tool calls into OpenAI-compatible tool calls."""

from __future__ import annotations

import json
import re
import uuid
from typing import Any


DSML_START = "<｜DSML｜tool_calls>"
DSML_END = "</｜DSML｜tool_calls>"

_INVOKE_RE = re.compile(
    r'<｜DSML｜invoke\s+name="([^"]+)">(.*?)</｜DSML｜invoke>',
    re.DOTALL,
)

_PARAMETER_RE = re.compile(
    r'<｜DSML｜parameter\s+name="([^"]+)"(?:\s+string="(true|false)")?>(.*?)'
    r'</｜DSML｜parameter>',
    re.DOTALL,
)


def parse_dsml_tool_calls(text: str) -> tuple[str, list[dict[str, Any]]]:
    """Extract DeepSeek DSML tool calls from text.

    Returns:
        (remaining_text, OpenAI-compatible tool_calls)
    """
    if not text or DSML_START not in text:
        return text, []

    start = text.find(DSML_START)
    end = text.find(DSML_END, start)

    if end == -1:
        # Incomplete DSML block.
        return text, []

    end += len(DSML_END)

    prefix = text[:start]
    suffix = text[end:]
    remaining = (prefix + suffix).strip()

    block = text[start:end]
    calls: list[dict[str, Any]] = []

    for invoke_match in _INVOKE_RE.finditer(block):
        name = invoke_match.group(1)
        body = invoke_match.group(2)

        arguments: dict[str, Any] = {}

        for parameter_match in _PARAMETER_RE.finditer(body):
            param_name = parameter_match.group(1)
            string_flag = parameter_match.group(2)
            raw_value = parameter_match.group(3)

            # DeepSeek's documented DSML format uses
            # string="true" for string values.
            #
            # If the attribute is absent, attempt JSON parsing so
            # values such as 3, 400, true, false, objects and arrays
            # retain their correct JSON types.
            if string_flag == "true":
                value: Any = raw_value
            else:
                try:
                    value = json.loads(raw_value)
                except json.JSONDecodeError:
                    value = raw_value

            arguments[param_name] = value

        calls.append(
            {
                "id": f"toolu_{uuid.uuid4().hex[:24]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": json.dumps(
                        arguments,
                        ensure_ascii=True,
                        separators=(",", ":"),
                    ),
                },
            }
        )

    return remaining, calls


def contains_dsml_tool_call(text: str) -> bool:
    return DSML_START in text


def has_complete_dsml_tool_call(text: str) -> bool:
    return DSML_START in text and DSML_END in text
PY

success "dsml.py created."


# ============================================================
# PATCH 4
# response.py
#
# Convert DSML-generated tool calls into Anthropic tool_use.
#
# CRITICAL:
# If DSML tool calls exist, stop_reason must become tool_use.
# ============================================================

section "Patch 4/4 — response.py DSML tool conversion"

"$VENV_PYTHON" - "$RESPONSE_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Ensure import exists.
import_line = "from a2o.converters.dsml import parse_dsml_tool_calls\n"

if import_line not in text:
    marker = "from a2o.models import AnthropicUsage\n"

    if marker not in text:
        raise SystemExit(
            "Could not locate the import section in response.py."
        )

    text = text.replace(
        marker,
        marker + import_line,
        1,
    )

start = text.find("def convert_openai_to_anthropic(")

if start == -1:
    raise SystemExit(
        "Could not locate convert_openai_to_anthropic() in response.py."
    )

# Replace the entire function so indentation and previous partial
# edits cannot corrupt the file.
prefix = text[:start]

new_function = '''def convert_openai_to_anthropic(
    openai_resp: dict[str, Any], model: str | None = None
) -> dict[str, Any]:
    choices = openai_resp.get("choices") or []
    msg_id = openai_resp.get("id") or f"msg_{uuid.uuid4().hex[:24]}"

    content: list[dict[str, Any]] = []
    finish_reason: str | None = None
    used_model = model or openai_resp.get("model", "")

    if choices:
        first = choices[0]
        message = first.get("message", {})
        finish_reason = first.get("finish_reason")

        # Text content / DeepSeek DSML tool calls
        text = message.get("content")

        dsml_tool_calls = []

        if isinstance(text, str):
            text, dsml_tool_calls = parse_dsml_tool_calls(text)

        # DSML tool calls must terminate as tool_use.
        if dsml_tool_calls:
            finish_reason = "tool_calls"

        if text:
            content.append({"type": "text", "text": text})

        # Reasoning content (thinking)
        additional = message.get("_additionalProperties") or {}

        reasoning = (
            additional.get("reasoning_content")
            or message.get("reasoning_content")
        )

        signature = (
            additional.get("thinking_signature")
            or message.get("_thinking_signature")
            or ""
        )

        if reasoning:
            if not text and reasoning.strip():
                content.append(
                    {
                        "type": "text",
                        "text": reasoning,
                    }
                )
            else:
                content.append(
                    {
                        "type": "thinking",
                        "thinking": reasoning,
                        "signature": signature,
                    }
                )

        redacted = (
            additional.get("redacted_thinking")
            or message.get("redacted_thinking")
        )

        if redacted:
            content.append(
                redacted
                if isinstance(redacted, dict)
                else {
                    "type": "redacted_thinking",
                    "data": redacted,
                }
            )

        # Existing structured OpenAI tool calls plus
        # DeepSeek DSML-generated tool calls.
        tool_calls = list(message.get("tool_calls") or [])
        tool_calls.extend(dsml_tool_calls)

        for tc in tool_calls:
            func = tc.get("function", {})

            content.append(
                {
                    "type": "tool_use",
                    "id": (
                        tc.get("id")
                        or f"toolu_{uuid.uuid4().hex[:24]}"
                    ),
                    "name": func.get("name", ""),
                    "input": _parse_tool_arguments(
                        func.get("arguments")
                    ),
                }
            )

        # Any structured tool call also means Claude Code must
        # continue by executing the tool.
        if tool_calls:
            finish_reason = "tool_calls"

    result = {
        "id": msg_id,
        "type": "message",
        "role": "assistant",
        "model": used_model,
        "stop_reason": _map_finish_reason(finish_reason),
        "stop_sequence": None,
        "content": content,
        "usage": _serialize_usage(
            _build_usage(openai_resp.get("usage"))
        ),
    }

    return result
'''

path.write_text(prefix + new_function)

print("response.py rewritten with DSML support.")
PY

success "response.py patched."


# ============================================================
# STREAMING PATCH
#
# DeepSeek may return DSML tool calls as streamed text.
#
# We buffer streamed content and inspect the complete response
# at finalization.
#
# This prioritizes correctness first.
# ============================================================

section "Streaming DSML support"

"$VENV_PYTHON" - "$STREAMING_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

import_line = "from a2o.converters.dsml import parse_dsml_tool_calls\n"

if import_line not in text:
    # Locate a stable import section.
    lines = text.splitlines(keepends=True)

    insert_at = 0

    for i, line in enumerate(lines):
        if line.startswith("from ") or line.startswith("import "):
            insert_at = i + 1

    lines.insert(insert_at, import_line)
    text = "".join(lines)

# Add content buffer to _StreamState.
if "_content_buffer: list[str]" not in text:
    marker = "        self._tool_calls: dict[int, dict[str, Any]] = {}\n"

    if marker not in text:
        raise SystemExit(
            "Could not locate _tool_calls state in streaming.py."
        )

    replacement = (
        marker
        + "        self._content_buffer: list[str] = []\n"
    )

    text = text.replace(marker, replacement, 1)


# Replace direct streaming content emission.
old_content = '''        if delta.get("content"):
            self._had_text = True
            idx = self._ensure_active_block(events, CONTENT_TEXT)
            events.append(
                _sse(
                    "content_block_delta",
                    {
                        "index": idx,
                        "delta": {
                            "type": "text_delta",
                            "text": delta["content"],
                        },
                    },
                )
            )
'''

new_content = '''        if delta.get("content"):
            self._had_text = True

            # DeepSeek V4 can emit DSML tool calls as text.
            # Buffer the content so finalize() can distinguish
            # ordinary text from DSML tool calls.
            self._content_buffer.append(delta["content"])
'''

if old_content in text:
    text = text.replace(old_content, new_content, 1)
elif "self._content_buffer.append(delta[\"content\"])" not in text:
    raise SystemExit(
        "Could not locate the streaming text-content handler."
    )


# Replace finalize() by locating it and replacing its complete body
# until the next top-level function/method.
start = text.find("    def finalize(")

if start == -1:
    raise SystemExit(
        "Could not locate _StreamState.finalize() in streaming.py."
    )

# Find the next method at the same indentation level.
after = text.find("\n    def ", start + 5)

if after == -1:
    # finalize is probably near the end of the class.
    after = len(text)

old_finalize = text[start:after]

new_finalize = '''    def finalize(self) -> list[str]:
        events: list[str] = []

        # Process any buffered text after the complete upstream
        # response has arrived. This allows us to detect DeepSeek
        # V4 DSML tool calls.
        full_content = "".join(self._content_buffer)

        text_content, dsml_tool_calls = parse_dsml_tool_calls(
            full_content
        )

        if text_content:
            idx = self._ensure_active_block(
                events,
                CONTENT_TEXT,
            )

            events.append(
                _sse(
                    "content_block_delta",
                    {
                        "index": idx,
                        "delta": {
                            "type": "text_delta",
                            "text": text_content,
                        },
                    },
                )
            )

        # Convert DeepSeek DSML tool calls into the same internal
        # OpenAI tool-call structure already understood by the
        # existing streaming tool-call machinery.
        for index, tool_call in enumerate(dsml_tool_calls):
            tool_call["index"] = index
            self._process_tool_call(events, tool_call)

        if dsml_tool_calls:
            self.final_stop_reason = STOP_TOOL_USE

        self._close_active_block(events)

        self._flush_final_tool_calls(events)

        events.append(
            _sse(
                "message_delta",
                {
                    "delta": {
                        "stop_reason": self.final_stop_reason,
                        "stop_sequence": None,
                    },
                    "usage": self.usage,
                },
            )
        )

        events.append(
            _sse(
                "message_stop",
                {},
            )
        )

        return events
'''

text = text[:start] + new_finalize + text[after:]

path.write_text(text)

print("streaming.py patched with DSML buffering/conversion.")
PY

success "Streaming DSML patch complete."


# ============================================================
# VERIFY IMPORTS
# ============================================================

section "Verifying converter imports"

"$VENV_PYTHON" - <<'PY'
from a2o.converters.dsml import parse_dsml_tool_calls
from a2o.converters.response import convert_openai_to_anthropic

print("DSML parser import: OK")
print("Response converter import: OK")
PY

success "Converter imports are valid."


# ============================================================
# PYTHON SYNTAX
# ============================================================

section "Checking Python syntax"

"$VENV_PYTHON" -m py_compile \
    "$PARSER_FILE" \
    "$REQUEST_FILE" \
    "$RESPONSE_FILE" \
    "$STREAMING_FILE" \
    "$DSML_FILE"

success "All patched Python files compile successfully."


# ============================================================
# TEST 1
# SYSTEM MESSAGE EXTRACTION
# ============================================================

section "Test 1/3 — system-message extraction"

"$VENV_PYTHON" - <<'PY'
from a2o.converters.parser import parse_anthropic_request

data = {
    "model": "test",
    "max_tokens": 100,
    "messages": [
        {
            "role": "system",
            "content": "You are a coding assistant."
        },
        {
            "role": "user",
            "content": "Hello"
        }
    ]
}

req = parse_anthropic_request(data)

assert len(req.messages) == 1
assert req.messages[0].role == "user"
assert req.messages[0].content == "Hello"
assert req.system is not None

print("messages:", [(m.role, m.content) for m in req.messages])
print("system:", req.system)
print()
print("PASS: system message extracted successfully.")
PY


# ============================================================
# TEST 2
# DSML PARSER
# ============================================================

section "Test 2/3 — DeepSeek V4 DSML parser"

"$VENV_PYTHON" - <<'PY'
from a2o.converters.dsml import parse_dsml_tool_calls

sample = """<｜DSML｜tool_calls>
<｜DSML｜invoke name="read_file">
<｜DSML｜parameter name="file_path">/tmp/test.txt</｜DSML｜parameter>
<｜DSML｜parameter name="offset">3</｜DSML｜parameter>
<｜DSML｜parameter name="limit">400</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>"""

text, calls = parse_dsml_tool_calls(sample)

assert text == ""
assert len(calls) == 1

call = calls[0]

assert call["type"] == "function"
assert call["function"]["name"] == "read_file"

arguments = __import__("json").loads(
    call["function"]["arguments"]
)

assert arguments["file_path"] == "/tmp/test.txt"
assert arguments["offset"] == 3
assert arguments["limit"] == 400

print("TEXT:", repr(text))
print("CALLS:", calls)
print()
print("PASS: DeepSeek DSML parsed correctly.")
PY


# ============================================================
# TEST 3
# RESPONSE CONVERTER
# ============================================================

section "Test 3/3 — DSML → Anthropic tool_use"

"$VENV_PYTHON" - <<'PY'
from a2o.converters.response import convert_openai_to_anthropic

data = {
    "id": "test-response",
    "model": "deepseek-ai/DeepSeek-V4-Flash-0731",
    "choices": [
        {
            "index": 0,
            "finish_reason": "stop",
            "message": {
                "role": "assistant",
                "content": """<｜DSML｜tool_calls>
<｜DSML｜invoke name="read_file">
<｜DSML｜parameter name="file_path">/tmp/test.txt</｜DSML｜parameter>
<｜DSML｜parameter name="offset">3</｜DSML｜parameter>
<｜DSML｜parameter name="limit">400</｜DSML｜parameter>
</｜DSML｜invoke>
</｜DSML｜tool_calls>""",
            },
        }
    ],
}

result = convert_openai_to_anthropic(data)

assert result["stop_reason"] == "tool_use"
assert len(result["content"]) == 1

tool = result["content"][0]

assert tool["type"] == "tool_use"
assert tool["name"] == "read_file"
assert tool["input"]["file_path"] == "/tmp/test.txt"
assert tool["input"]["offset"] == 3
assert tool["input"]["limit"] == 400

print("STOP_REASON:", result["stop_reason"])
print("CONTENT:", result["content"])
print()
print("PASS: DSML converted to Anthropic tool_use.")
PY


# ============================================================
# SAVE CONFIGURATION
# ============================================================

section "Saving configuration"

cat > "$CONFIG_FILE" <<EOF
# ============================================================
# ant2oai / a2o configuration
# ============================================================
#
# Generated:
#   $(date)
#
# This file contains the configuration used by the local
# a2o launcher.
#
# Permissions should remain 600 because A2O_API_KEY may contain
# a real provider credential.
# ============================================================

A2O_PROVIDER_NAME=$(printf '%q' "$PROVIDER_NAME")
A2O_UPSTREAM=$(printf '%q' "$BASE_URL")
A2O_MODEL=$(printf '%q' "$MODEL")
A2O_HOST=$(printf '%q' "$A2O_HOST")
A2O_PORT=$(printf '%q' "$A2O_PORT")
A2O_API_KEY=$(printf '%q' "$API_KEY")
EOF

chmod 600 "$CONFIG_FILE"

success "Configuration saved:"
printf '  %s\n' "$CONFIG_FILE"

success "Configuration permissions set to 600."


# ============================================================
# VS CODE SETTINGS
# ============================================================

section "Configuring VS Code Claude Code"

mkdir -p "$(dirname "$VSCODE_SETTINGS")"

if [[ ! -f "$VSCODE_SETTINGS" ]]; then
    printf '{}\n' > "$VSCODE_SETTINGS"
    success "Created VS Code settings.json."
else
    cp "$VSCODE_SETTINGS" "$VSCODE_SETTINGS.bak.$TIMESTAMP"
    success "Backed up existing VS Code settings.json."
fi


"$VENV_PYTHON" - "$VSCODE_SETTINGS" "$A2O_HOST" "$A2O_PORT" "$MODEL" "$API_KEY" <<'PY'
from pathlib import Path
import json
import sys

settings_path = Path(sys.argv[1])
host = sys.argv[2]
port = sys.argv[3]
model = sys.argv[4]
api_key = sys.argv[5]

try:
    settings = json.loads(settings_path.read_text())
except json.JSONDecodeError as exc:
    raise SystemExit(
        f"VS Code settings.json is not valid JSON: {exc}"
    )

if not isinstance(settings, dict):
    raise SystemExit(
        "VS Code settings.json must contain a JSON object."
    )

key = "claudeCode.environmentVariables"

existing = settings.get(key, [])

if not isinstance(existing, list):
    raise SystemExit(
        f"{key} exists but is not an array. "
        "Refusing to overwrite it."
    )

managed_names = {
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_MODEL",
}

filtered = [
    item
    for item in existing
    if not (
        isinstance(item, dict)
        and item.get("name") in managed_names
    )
]

filtered.append(
    {
        "name": "ANTHROPIC_BASE_URL",
        "value": f"http://{host}:{port}",
    }
)

# Claude Code needs an API key value. a2o passes the key
# through to the upstream OpenAI-compatible provider.
if api_key:
    filtered.append(
        {
            "name": "ANTHROPIC_API_KEY",
            "value": api_key,
        }
    )

filtered.append(
    {
        "name": "ANTHROPIC_MODEL",
        "value": model,
    }
)

settings[key] = filtered

settings_path.write_text(
    json.dumps(
        settings,
        indent=2,
        ensure_ascii=False,
    ) + "\n"
)
PY

success "Claude Code environment variables configured."


# ============================================================
# CREATE LAUNCHER
# ============================================================

section "Creating launcher"

cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="$HOME/ant2oia"
VENV_DIR="$INSTALL_DIR/.venv"
CONFIG_FILE="$INSTALL_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file not found:"
    echo "        $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${A2O_UPSTREAM:-}" ]]; then
    echo "[ERROR] A2O_UPSTREAM is not configured."
    exit 1
fi

if [[ -z "${A2O_MODEL:-}" ]]; then
    echo "[ERROR] A2O_MODEL is not configured."
    exit 1
fi

if [[ -z "${A2O_HOST:-}" ]]; then
    A2O_HOST="127.0.0.1"
fi

if [[ -z "${A2O_PORT:-}" ]]; then
    A2O_PORT="3578"
fi

# The local Claude Code endpoint.
export ANTHROPIC_BASE_URL="http://${A2O_HOST}:${A2O_PORT}"

# a2o passes this credential to the configured upstream.
if [[ -n "${A2O_API_KEY:-}" ]]; then
    export ANTHROPIC_API_KEY="$A2O_API_KEY"
fi

export ANTHROPIC_MODEL="$A2O_MODEL"

source "$VENV_DIR/bin/activate"

echo
echo "============================================================"
echo " a2o / ant2oai"
echo "============================================================"
echo
echo "Provider : ${A2O_PROVIDER_NAME:-Custom}"
echo "Upstream : $A2O_UPSTREAM"
echo "Model    : $A2O_MODEL"
echo "Local    : $ANTHROPIC_BASE_URL"
echo
echo "Starting proxy..."
echo

exec a2o \
    --host "$A2O_HOST" \
    --port "$A2O_PORT" \
    --upstream "$A2O_UPSTREAM" \
    --model "$A2O_MODEL" \
    --debug
EOF

chmod +x "$LAUNCHER"

success "Launcher created:"
printf '  %s\n' "$LAUNCHER"


# ============================================================
# CREATE A CLAUDE CODE TEST PROMPT FILE
# ============================================================

TEST_PROMPT="$INSTALL_DIR/claude-tool-test.txt"

cat > "$TEST_PROMPT" <<'EOF'
Read the file /tmp/test.txt and tell me exactly what is inside it.

Use the file-reading tool to access the file.
Do not ask me to paste the contents.
EOF

success "Claude Code tool test prompt created:"
printf '  %s\n' "$TEST_PROMPT"


# ============================================================
# FINAL VALIDATION
# ============================================================

section "Final validation"

"$VENV_PYTHON" - <<'PY'
import a2o
from a2o.converters.dsml import parse_dsml_tool_calls
from a2o.converters.response import convert_openai_to_anthropic

print("a2o import:                         OK")
print("DSML parser import:                 OK")
print("Anthropic response converter:       OK")
print("All final imports passed.")
PY

success "Final validation passed."


# ============================================================
# FINAL OUTPUT
# ============================================================

section "SETUP COMPLETE"

printf '\n'

printf '%bProvider%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$PROVIDER_NAME"

printf '%bUpstream%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$BASE_URL"

printf '%bModel%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$MODEL"

printf '%bLocal Anthropic endpoint%b\n' "$CYAN" "$RESET"
printf '  http://%s:%s\n\n' "$A2O_HOST" "$A2O_PORT"

printf '%bInstallation%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$INSTALL_DIR"

printf '%bConfiguration%b\n' "$CYAN" "$RESET"
printf '  %s\n' "$CONFIG_FILE"
printf '  permissions: 600\n\n'

printf '%bLauncher%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$LAUNCHER"

printf '%bVS Code settings%b\n' "$CYAN" "$RESET"
printf '  %s\n\n' "$VSCODE_SETTINGS"

printf '%bTests%b\n' "$CYAN" "$RESET"
printf '  System-message extraction       PASS\n'
printf '  DeepSeek V4 DSML parsing        PASS\n'
printf '  DSML → Anthropic tool_use       PASS\n'
printf '  Python compilation              PASS\n\n'

printf '%bInstalled fixes%b\n' "$CYAN" "$RESET"
printf '  ✓ Claude Code system messages handled\n'
printf '  ✓ Dahl role=system incompatibility handled\n'
printf '  ✓ DeepSeek V4 DSML tool calls parsed\n'
printf '  ✓ DSML tool calls converted to tool_use\n'
printf '  ✓ tool_use stop reason preserved\n'
printf '  ✓ Streaming DSML handling installed\n\n'

printf '%bNEXT STEPS%b\n' "$CYAN" "$RESET"
printf '\n'

printf '1. Start the proxy:\n'
printf '   %s\n\n' "$LAUNCHER"

printf '2. Leave that terminal running.\n\n'

printf '3. Reload VS Code so the updated Claude Code environment\n'
printf '   variables are loaded.\n\n'

printf '4. Start a NEW Claude Code session.\n\n'

printf '5. Test an actual tool call with:\n'
printf '   Read /tmp/test.txt and tell me exactly what is inside it.\n'
printf '   Use the file-reading tool; do not ask me to paste it.\n\n'

printf '6. If DeepSeek returns a DSML tool call, a2o should now\n'
printf '   convert it into an Anthropic tool_use block.\n\n'

printf '%bImportant%b\n' "$YELLOW" "$RESET"
printf 'If you change provider/model later, rerun this script and\n'
printf 'choose option 2 or option 3 during provider selection.\n\n'

printf '%s\n' '============================================================'
printf '%s\n' ' End of setup'
printf '%s\n' '============================================================'
```
