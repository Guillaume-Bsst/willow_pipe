#!/usr/bin/env bash
# =============================================================================
# Willow WBT — centralized installer
#
# Everything is installed into ~/.willow_deps/miniconda3 — a fully isolated
# conda, separate from your system conda and from ~/.holosoma_deps.
#
# Usage:
#   ./install.sh              # install everything
#   ./install.sh willow       # willow_wbt env only
#   ./install.sh gmr          # GMR retargeter env only
#   ./install.sh retargeting  # holosoma hsretargeting env
#   ./install.sh mujoco       # holosoma hsmujoco env
#   ./install.sh isaacgym     # holosoma hsgym env
#   ./install.sh isaacsim     # holosoma hssim env
#   ./install.sh inference    # holosoma hsinference env
#
# Options:
#   --no-warp   skip MuJoCo Warp GPU backend (CPU-only mujoco)
#   --alias X   suffix appended to holosoma env names (e.g. hsretargeting_X)
#               allows multiple holosoma versions to coexist
#
# Examples:
#   ./install.sh --no-warp
#   ./install.sh mujoco --no-warp
#   ./install.sh retargeting --alias v2
# =============================================================================
set -euo pipefail

REPO_ROOT="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
HOLOSOMA_SCRIPTS="$REPO_ROOT/modules/third_party/holosoma/scripts"
GMR_DIR="$REPO_ROOT/modules/01_retargeting/GMR"

# Willow isolated ecosystem
export WORKSPACE_DIR="$HOME/.willow_deps"
export CONDA_ROOT="$WORKSPACE_DIR/miniconda3"
CONDA_BIN="$CONDA_ROOT/bin/conda"

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
TARGET="all"
NO_WARP=""
ALIAS=""

for arg in "$@"; do
  case "$arg" in
    --no-warp) NO_WARP="--no-warp" ;;
    --alias)   ;;  # handled below with shift-like logic
    *)         [[ "$TARGET" == "all" ]] && TARGET="$arg" || true ;;
  esac
done

# Extract --alias value
for i in "$@"; do
  if [[ "$i" == "--alias" ]]; then
    shift_next=true
  elif [[ "${shift_next:-false}" == "true" ]]; then
    ALIAS="_$i"
    shift_next=false
  fi
done

# If TARGET is still "all" but first arg was --no-warp, keep "all"
[[ "$TARGET" == "--no-warp" ]] && TARGET="all"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
_header() { echo ""; echo "══════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════"; }
_ok()     { echo "  ✓ $1"; }

# --------------------------------------------------------------------------
# Bootstrap: install willow miniconda if missing
# --------------------------------------------------------------------------
_bootstrap_miniconda() {
  if [[ -d "$CONDA_ROOT" ]]; then
    return
  fi

  _header "Bootstrapping willow miniconda → $CONDA_ROOT"
  mkdir -p "$WORKSPACE_DIR"

  OS_NAME="$(uname -s)"
  ARCH_NAME="$(uname -m)"

  if [[ "$OS_NAME" == "Linux" ]]; then
    INSTALLER="Miniconda3-latest-Linux-x86_64.sh"
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    [[ "$ARCH_NAME" == "arm64" ]] \
      && INSTALLER="Miniconda3-latest-MacOSX-arm64.sh" \
      || INSTALLER="Miniconda3-latest-MacOSX-x86_64.sh"
  else
    echo "ERROR: unsupported OS: $OS_NAME" >&2; exit 1
  fi

  TMP_INSTALLER="$WORKSPACE_DIR/miniconda_install.sh"
  curl -fsSL "https://repo.anaconda.com/miniconda/${INSTALLER}" -o "$TMP_INSTALLER"
  bash "$TMP_INSTALLER" -b -u -p "$CONDA_ROOT"
  rm "$TMP_INSTALLER"

  # Accept conda TOS (non-interactive)
  "$CONDA_BIN" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
  "$CONDA_BIN" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    || true

  _ok "miniconda installed at $CONDA_ROOT"
}

# Create a conda env in the willow miniconda (idempotent)
_ensure_env() {
  local name="$1" python="${2:-3.10}"
  local env_root="$CONDA_ROOT/envs/$name"
  if [[ ! -d "$env_root" ]]; then
    echo "  Creating env '$name' (python $python)..."
    "$CONDA_BIN" install -y mamba -c conda-forge -n base --quiet
    "$CONDA_ROOT/bin/mamba" create -y -n "$name" python="$python" -c conda-forge --override-channels
  else
    _ok "env '$name' already exists"
  fi
}

# --------------------------------------------------------------------------
# willow_wbt env
# --------------------------------------------------------------------------
install_willow() {
  _header "willow_wbt env"
  _bootstrap_miniconda
  _ensure_env "willow_wbt"
  "$CONDA_ROOT/envs/willow_wbt/bin/pip" install -e "$REPO_ROOT" --quiet
  _ok "willow_wbt installed (editable)"
}

# --------------------------------------------------------------------------
# GMR env
# --------------------------------------------------------------------------
install_gmr() {
  _header "GMR env"
  _bootstrap_miniconda
  _ensure_env "gmr"

  if [[ "$(uname -s)" == "Linux" ]]; then
    "$CONDA_BIN" install -y -n gmr -c conda-forge libstdcxx-ng --quiet
  fi
  "$CONDA_ROOT/envs/gmr/bin/pip" install -e "$GMR_DIR" --quiet
  _ok "GMR installed (editable)"
}

# --------------------------------------------------------------------------
# holosoma envs — delegate to holosoma scripts with WORKSPACE_DIR overridden
# WORKSPACE_DIR is already exported at the top of this script so
# source_common.sh (patched) will pick it up via ${WORKSPACE_DIR:-...}
# --------------------------------------------------------------------------
install_retargeting() {
  local env_name="hsretargeting${ALIAS}"
  _header "holosoma $env_name env"
  CONDA_ENV_NAME="$env_name" bash "$HOLOSOMA_SCRIPTS/setup_retargeting.sh"
}

install_mujoco() {
  local env_name="hsmujoco${ALIAS}"
  _header "holosoma $env_name env"
  CONDA_ENV_NAME="$env_name" bash "$HOLOSOMA_SCRIPTS/setup_mujoco.sh" $NO_WARP
}

install_isaacgym() {
  local env_name="hsgym${ALIAS}"
  _header "holosoma $env_name env"
  CONDA_ENV_NAME="$env_name" bash "$HOLOSOMA_SCRIPTS/setup_isaacgym.sh"
}

install_isaacsim() {
  local env_name="hssim${ALIAS}"
  _header "holosoma $env_name env (requires EULA acceptance)"
  OMNI_KIT_ACCEPT_EULA=1 CONDA_ENV_NAME="$env_name" bash "$HOLOSOMA_SCRIPTS/setup_isaacsim.sh"
}

install_inference() {
  local env_name="hsinference${ALIAS}"
  _header "holosoma $env_name env"
  CONDA_ENV_NAME="$env_name" bash "$HOLOSOMA_SCRIPTS/setup_inference.sh"
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
case "$TARGET" in
  all)
    install_willow
    install_gmr
    install_retargeting
    install_mujoco
    install_isaacgym
    install_isaacsim
    install_inference
    ;;
  willow)      install_willow ;;
  gmr)         install_gmr ;;
  retargeting) install_retargeting ;;
  mujoco)      install_mujoco ;;
  isaacgym)    install_isaacgym ;;
  isaacsim)    install_isaacsim ;;
  inference)   install_inference ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Usage: $0 [all|willow|gmr|retargeting|mujoco|isaacgym|isaacsim|inference] [--no-warp] [--alias X]"
    exit 1
    ;;
esac

echo ""
echo "══════════════════════════════════════════"
echo "  Done."
echo "══════════════════════════════════════════"
echo ""
echo "All envs installed in: $CONDA_ROOT/envs/"
echo ""
echo "To activate the ecosystem:"
echo "  source scripts/activate_willow.sh"
echo ""
