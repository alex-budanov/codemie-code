#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="@codemieai/code"
MINIMUM_NODE_MAJOR="20"

# Return 0 if the given binary exists, runs, and reports Node.js >= min_major.
node_meets_min() {
  local binary="$1" min="$2"
  [ -x "$binary" ] || return 1
  local ver major
  ver=$("$binary" --version 2>/dev/null | sed 's/v//')
  major=$(printf '%s' "$ver" | cut -d. -f1)
  [ -n "$major" ] && [ "$major" -ge "$min" ] 2>/dev/null
}

# Search version-manager directories for a Node.js binary meeting MINIMUM_NODE_MAJOR.
# Prints the absolute path on success; prints nothing on failure.
# Phase 1: active/default version (per manager). Phase 2: highest installed >= minimum.
find_versioned_node() {
  local min="$MINIMUM_NODE_MAJOR"

  # ── nvm ──────────────────────────────────────────────────────────────────
  # Phase 1: active version from ~/.nvm/alias/default
  local nvm_default="$HOME/.nvm/alias/default"
  if [ -f "$nvm_default" ]; then
    local ver
    ver=$(cat "$nvm_default")
    # Skip alias strings like "lts/*" — require version-like prefix
    case "$ver" in
      v[0-9]*|[0-9]*)
        ver=$(printf '%s' "$ver" | sed 's/^v//')
        local p="$HOME/.nvm/versions/node/v$ver/bin/node"
        if node_meets_min "$p" "$min"; then printf '%s' "$p"; return; fi
        ;;
    esac
  fi
  # Phase 2: all nvm versions — ls -rd gives reverse-lexicographic (newest major first for v2x)
  for p in $(ls -rd "$HOME"/.nvm/versions/node/v*/bin/node 2>/dev/null); do
    if node_meets_min "$p" "$min"; then printf '%s' "$p"; return; fi
  done

  # ── fnm ──────────────────────────────────────────────────────────────────
  # Phase 1: active version via symlink
  local fnm_alias="$HOME/.fnm/aliases/default"
  if [ -L "$fnm_alias" ]; then
    local ver
    ver=$(readlink "$fnm_alias" | xargs basename)
    local p="$HOME/.fnm/node-versions/$ver/installation/bin/node"
    if node_meets_min "$p" "$min"; then printf '%s' "$p"; return; fi
  fi
  # Phase 2: all fnm versions
  for p in $(ls -rd "$HOME"/.fnm/node-versions/v*/installation/bin/node 2>/dev/null); do
    if node_meets_min "$p" "$min"; then printf '%s' "$p"; return; fi
  done

  # ── asdf ─────────────────────────────────────────────────────────────────
  for p in $(ls -rd "$HOME"/.asdf/installs/nodejs/*/bin/node 2>/dev/null); do
    if node_meets_min "$p" "$min"; then printf '%s' "$p"; return; fi
  done

  # ── volta ─────────────────────────────────────────────────────────────────
  for p in $(ls -rd "$HOME"/.volta/tools/image/node/*/bin/node 2>/dev/null); do
    if node_meets_min "$p" "$min"; then printf '%s' "$p"; return; fi
  done
}

REGISTRY_URL="${CODEMIE_REGISTRY_URL:-https://registry.npmjs.org/}"
SCOPE_REGISTRY_URL="${CODEMIE_SCOPE_REGISTRY_URL:-}"
INSTALL_MODE="${CODEMIE_INSTALL_MODE:-auto}"
USER_PREFIX="${CODEMIE_NPM_PREFIX:-$HOME/.codemie/npm-prefix}"
PACKAGE_VERSION="${CODEMIE_PACKAGE_VERSION:-}"

status() {
  printf '%-18s %s\n' "$1:" "$2"
}

status_error() {
  printf '%-18s %s\n' "Error:" "$1" >&2
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

node_major() {
  local version
  version="$(node --version 2>/dev/null || true)"
  case "$version" in
    v[0-9]*)
      echo "$version" | sed -E 's/^v([0-9]+).*/\1/'
      ;;
    *)
      echo "0"
      ;;
  esac
}

NODE_PATH="$(command_path node)"
NPM_PATH="$(command_path npm)"
NODE_MAJOR="$(node_major)"

# Fallback: probe version-manager directories
if [ -z "$NODE_PATH" ]; then
  NODE_PATH=$(find_versioned_node)
  if [ -n "$NODE_PATH" ]; then
    status 'Node' "found via version manager: $NODE_PATH"
    NODE_MAJOR="$("$NODE_PATH" --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
  fi
fi

echo "CodeMie installer diagnostics"
status "OS" "$(uname -s)-$(uname -m)"
status "Shell" "POSIX"
status "Node" "${NODE_PATH:-not found} major $NODE_MAJOR"
status "npm" "${NPM_PATH:-not found}"
status "Registry" "$REGISTRY_URL"

if [ -z "$NODE_PATH" ] || [ "$NODE_MAJOR" -lt "$MINIMUM_NODE_MAJOR" ]; then
  status_error "Node.js ${MINIMUM_NODE_MAJOR}+ not found. Probed: PATH, nvm, fnm, asdf, volta. Install Node.js v${MINIMUM_NODE_MAJOR}+ or source your version manager before running this script."
  exit 1
fi

if [ -z "$NPM_PATH" ]; then
  echo "npm was not found. Reinstall Node.js with npm enabled, then rerun this installer." >&2
  exit 1
fi

if [ -n "$SCOPE_REGISTRY_URL" ]; then
  npm config set '@codemieai:registry' "$SCOPE_REGISTRY_URL" --location user
fi

if [ "$INSTALL_MODE" = "auto" ]; then
  NPM_PREFIX="$(npm config get prefix)"
  if [ -w "$NPM_PREFIX" ]; then
    INSTALL_MODE="npm-global"
  else
    INSTALL_MODE="user-prefix"
  fi
fi

status "Install mode" "$INSTALL_MODE"

if [ "$INSTALL_MODE" = "user-prefix" ]; then
  mkdir -p "$USER_PREFIX/bin"
  npm config set prefix "$USER_PREFIX" --location user
  case ":$PATH:" in
    *":$USER_PREFIX/bin:"*)
      status "PATH update" "already present"
      ;;
    *)
      status "PATH update" "add $USER_PREFIX/bin to PATH in your shell profile"
      ;;
  esac
fi

PACKAGE_SPEC="$PACKAGE_NAME"
if [ -n "$PACKAGE_VERSION" ]; then
  PACKAGE_SPEC="$PACKAGE_NAME@$PACKAGE_VERSION"
fi

if ! RESOLVED_PACKAGE_VERSION="$(npm view "$PACKAGE_SPEC" version --registry "$REGISTRY_URL" 2>&1)"; then
  echo "Package $PACKAGE_SPEC was not found in registry $REGISTRY_URL." >&2
  echo "Ask IT to expose @codemieai/code through the approved virtual npm repository, or rerun with CODEMIE_SCOPE_REGISTRY_URL pointing to the approved registry." >&2
  echo "npm output: $RESOLVED_PACKAGE_VERSION" >&2
  exit 1
fi

RESOLVED_PACKAGE_VERSION="$(printf '%s\n' "$RESOLVED_PACKAGE_VERSION" | head -n 1)"
status "Package" "$PACKAGE_SPEC found ($RESOLVED_PACKAGE_VERSION)"

if ! npm install -g "$PACKAGE_SPEC" --registry "$REGISTRY_URL"; then
  echo "Failed to install $PACKAGE_SPEC from registry $REGISTRY_URL." >&2
  exit 1
fi

status "CodeMie" "installed $RESOLVED_PACKAGE_VERSION"
echo "Run `codemie doctor` in a new terminal to verify the installation."
