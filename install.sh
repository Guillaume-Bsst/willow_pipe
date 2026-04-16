#!/usr/bin/env bash
# =============================================================================
# Willow WBT — centralized installer
#
# Two miniconda ecosystems, fully isolated:
#
#   ~/.willow_deps/miniconda3/
#     envs/willow_wbt/     ← adapter layer + scripts
#     envs/gmr/            ← GMR retargeter
#
#   ~/.holosoma_deps/miniconda3/       ← holosoma upstream
#     envs/hsretargeting/
#     envs/hsmujoco/
#     envs/hsgym/
#     envs/hssim/
#     envs/hsinference/
#
#   ~/.holosoma_custom_deps/miniconda3/ ← holosoma_custom (your fork)
#     envs/hsretargeting/
#     envs/hsmujoco/
#     ...
#
# Usage:
#   ./install.sh                        # install everything (all variants)
#   ./install.sh willow                 # willow_wbt env only
#   ./install.sh gmr                    # GMR env only
#   ./install.sh retargeting            # both holosoma variants
#   ./install.sh retargeting upstream   # holosoma upstream only
#   ./install.sh retargeting custom     # holosoma_custom only
#   ./install.sh mujoco [upstream|custom] [--no-warp]
#   ./install.sh isaacgym [upstream|custom]
#   ./install.sh isaacsim [upstream|custom]
#   ./install.sh inference [upstream|custom]
#   ./install.sh deployment                 # unitree_ros2 + unitree_control_interface
# =============================================================================
set -euo pipefail

REPO_ROOT="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
GMR_DIR="$REPO_ROOT/modules/01_retargeting/GMR"

HOLOSOMA_UPSTREAM_SCRIPTS="$REPO_ROOT/modules/third_party/holosoma/scripts"
HOLOSOMA_CUSTOM_SCRIPTS="$REPO_ROOT/modules/third_party/holosoma_custom/scripts"

# willow's own miniconda (willow_wbt + gmr)
WILLOW_CONDA_ROOT="$HOME/.willow_deps/miniconda3"
WILLOW_CONDA_BIN="$WILLOW_CONDA_ROOT/bin/conda"

# --------------------------------------------------------------------------
# Parse arguments
# --------------------------------------------------------------------------
TARGET="${1:-all}"
VARIANT="${2:-both}"   # upstream | custom | both
NO_WARP=""

for arg in "$@"; do
  [[ "$arg" == "--no-warp" ]] && NO_WARP="--no-warp"
done
[[ "$VARIANT" == "--no-warp" ]] && VARIANT="both"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
_header() { echo ""; echo "══════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════"; }
_ok()     { echo "  ✓ $1"; }

# --------------------------------------------------------------------------
# Bootstrap willow miniconda (for willow_wbt + gmr)
# --------------------------------------------------------------------------
_bootstrap_willow_miniconda() {
  if [[ -d "$WILLOW_CONDA_ROOT" ]]; then return; fi

  _header "Bootstrapping willow miniconda → $WILLOW_CONDA_ROOT"
  mkdir -p "$HOME/.willow_deps"

  OS_NAME="$(uname -s)"; ARCH_NAME="$(uname -m)"
  if [[ "$OS_NAME" == "Linux" ]]; then
    INSTALLER="Miniconda3-latest-Linux-x86_64.sh"
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    [[ "$ARCH_NAME" == "arm64" ]] \
      && INSTALLER="Miniconda3-latest-MacOSX-arm64.sh" \
      || INSTALLER="Miniconda3-latest-MacOSX-x86_64.sh"
  else
    echo "ERROR: unsupported OS: $OS_NAME" >&2; exit 1
  fi

  TMP="$HOME/.willow_deps/miniconda_install.sh"
  curl -fsSL "https://repo.anaconda.com/miniconda/${INSTALLER}" -o "$TMP"
  bash "$TMP" -b -u -p "$WILLOW_CONDA_ROOT"
  rm "$TMP"
  "$WILLOW_CONDA_BIN" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
  "$WILLOW_CONDA_BIN" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    || true
  _ok "willow miniconda installed at $WILLOW_CONDA_ROOT"
}

_ensure_willow_env() {
  local name="$1" python="${2:-3.10}"
  local env_root="$WILLOW_CONDA_ROOT/envs/$name"
  if [[ ! -d "$env_root" ]]; then
    echo "  Creating env '$name' (python $python)..."
    if [[ ! -f "$WILLOW_CONDA_ROOT/bin/mamba" ]]; then
      "$WILLOW_CONDA_BIN" install -y mamba -c conda-forge -n base --quiet
    fi
    MAMBA_ROOT_PREFIX="$WILLOW_CONDA_ROOT" "$WILLOW_CONDA_ROOT/bin/mamba" create -y \
      --prefix "$env_root" python="$python" -c conda-forge --override-channels
  else
    _ok "env '$name' already exists in ~/.willow_deps"
  fi
}

# --------------------------------------------------------------------------
# willow_wbt
# --------------------------------------------------------------------------
install_willow() {
  _header "willow_wbt env"
  _bootstrap_willow_miniconda
  _ensure_willow_env "willow_wbt"
  "$WILLOW_CONDA_ROOT/envs/willow_wbt/bin/pip" install -e "$REPO_ROOT" --quiet
  _ok "willow_wbt installed (editable)"
}

# --------------------------------------------------------------------------
# GMR
# --------------------------------------------------------------------------
install_gmr() {
  _header "GMR env"
  _bootstrap_willow_miniconda
  _ensure_willow_env "gmr"
  if [[ "$(uname -s)" == "Linux" ]]; then
    MAMBA_ROOT_PREFIX="$WILLOW_CONDA_ROOT" "$WILLOW_CONDA_ROOT/bin/mamba" install -y \
      --prefix "$WILLOW_CONDA_ROOT/envs/gmr" -c conda-forge libstdcxx-ng --quiet
  fi
  "$WILLOW_CONDA_ROOT/envs/gmr/bin/pip" install -e "$GMR_DIR" --quiet
  _ok "GMR installed (editable)"
}

# --------------------------------------------------------------------------
# holosoma upstream  →  ~/.holosoma_deps/
# (source_common.sh hardcodes this path — upstream is untouched)
# --------------------------------------------------------------------------
_install_holosoma_upstream() {
  local cmd="$1"; shift
  bash "$HOLOSOMA_UPSTREAM_SCRIPTS/${cmd}" "$@"
}

install_retargeting_upstream() {
  _header "holosoma upstream — hsretargeting"
  _install_holosoma_upstream setup_retargeting.sh
}
install_mujoco_upstream() {
  _header "holosoma upstream — hsmujoco"
  _install_holosoma_upstream setup_mujoco.sh $NO_WARP
}
install_isaacgym_upstream() {
  _header "holosoma upstream — hsgym"
  _install_holosoma_upstream setup_isaacgym.sh
}
install_isaacsim_upstream() {
  _header "holosoma upstream — hssim"
  OMNI_KIT_ACCEPT_EULA=1 _install_holosoma_upstream setup_isaacsim.sh
}
install_inference_upstream() {
  _header "holosoma upstream — hsinference"
  _install_holosoma_upstream setup_inference.sh
}

# --------------------------------------------------------------------------
# holosoma_custom  →  ~/.holosoma_custom_deps/
# (source_common.sh in the fork respects WORKSPACE_DIR env var)
# --------------------------------------------------------------------------
_install_holosoma_custom() {
  local cmd="$1"; shift
  WORKSPACE_DIR="$HOME/.holosoma_custom_deps" bash "$HOLOSOMA_CUSTOM_SCRIPTS/${cmd}" "$@"
}

install_retargeting_custom() {
  _header "holosoma_custom — hsretargeting"
  _install_holosoma_custom setup_retargeting.sh
}
install_mujoco_custom() {
  _header "holosoma_custom — hsmujoco"
  _install_holosoma_custom setup_mujoco.sh $NO_WARP
}
install_isaacgym_custom() {
  _header "holosoma_custom — hsgym"
  _install_holosoma_custom setup_isaacgym.sh
}
install_isaacsim_custom() {
  _header "holosoma_custom — hssim"
  OMNI_KIT_ACCEPT_EULA=1 _install_holosoma_custom setup_isaacsim.sh
}
install_inference_custom() {
  _header "holosoma_custom — hsinference"
  _install_holosoma_custom setup_inference.sh
}

# --------------------------------------------------------------------------
# deployment — unitree_ros2 + unitree_control_interface
# Follows: https://github.com/inria-paris-robotics-lab/unitree_control_interface
# --------------------------------------------------------------------------
install_deployment() {
  _header "deployment — unitree_ros2 + unitree_control_interface"

  local WS="$REPO_ROOT/modules/04_deployment/unitree_ros2/cyclonedds_ws"
  local SRC="$WS/src"
  local UCI_DIR="$SRC/unitree_control_interface"
  local UCI_ENV="unitree_control_interface"

  # Ensure submodule is checked out
  git -C "$REPO_ROOT" submodule update --init modules/04_deployment/unitree_ros2

  # Step 2 — clone unitree_control_interface if missing
  if [[ ! -d "$UCI_DIR" ]]; then
    echo "  Cloning unitree_control_interface..."
    git clone git@github.com:inria-paris-robotics-lab/unitree_control_interface.git \
      --recursive "$UCI_DIR"
  else
    _ok "unitree_control_interface already cloned"
  fi

  # Step 3 — create conda env (idempotent)
  local MAMBA_BIN=""
  if command -v mamba &>/dev/null; then
    MAMBA_BIN="mamba"
  elif command -v conda &>/dev/null; then
    MAMBA_BIN="conda"
  else
    echo "ERROR: conda/mamba not found." >&2; exit 1
  fi

  if ! $MAMBA_BIN env list | grep -q "^${UCI_ENV} "; then
    echo "  Creating conda env '${UCI_ENV}'..."
    $MAMBA_BIN env create -f "$UCI_DIR/environment.yaml"
  else
    _ok "conda env '${UCI_ENV}' already exists"
  fi

  local CONDA_BASE
  CONDA_BASE="$($MAMBA_BIN info --base 2>/dev/null || conda info --base)"
  local ENV_BIN="$CONDA_BASE/envs/$UCI_ENV/bin"

  # Step 4 — clone remaining deps via vcs
  if ! "$ENV_BIN/pip" show vcstools &>/dev/null && ! command -v vcs &>/dev/null; then
    "$ENV_BIN/pip" install vcstool --quiet
  fi
  (cd "$SRC" && vcs import --recursive < "$UCI_DIR/git-deps.yaml")

  # Step 5 — build colcon packages
  (
    cd "$WS"
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate "$UCI_ENV"

    # A. Build cyclonedds first
    colcon build --packages-select cyclonedds
    source install/setup.bash

    # B. Build all remaining
    colcon build --packages-skip unitree_sdk2py
  )

  # Step 7 — install unitree_sdk2_python
  (
    cd "$WS"
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate "$UCI_ENV"
    source install/setup.bash
    export CYCLONEDDS_HOME="$(pwd)/install/cyclonedds"
    "$ENV_BIN/pip" install -e src/unitree_sdk2_python --quiet
  )

  _ok "deployment stack installed — env: $UCI_ENV"
  echo ""
  echo "  To use:"
  echo "    conda activate $UCI_ENV"
  echo "    source $WS/install/setup.bash"
}

# --------------------------------------------------------------------------
# Dispatch helpers for both/upstream/custom
# --------------------------------------------------------------------------
_dispatch_holosoma() {
  local fn="$1"   # e.g. "retargeting"
  case "$VARIANT" in
    upstream) "install_${fn}_upstream" ;;
    custom)   "install_${fn}_custom" ;;
    both)     "install_${fn}_upstream"; "install_${fn}_custom" ;;
  esac
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
case "$TARGET" in
  all)
    install_willow
    install_gmr
    _dispatch_holosoma retargeting
    _dispatch_holosoma mujoco
    _dispatch_holosoma isaacgym
    _dispatch_holosoma isaacsim
    _dispatch_holosoma inference
    install_deployment
    ;;
  willow)      install_willow ;;
  gmr)         install_gmr ;;
  retargeting) _dispatch_holosoma retargeting ;;
  mujoco)      _dispatch_holosoma mujoco ;;
  isaacgym)    _dispatch_holosoma isaacgym ;;
  isaacsim)    _dispatch_holosoma isaacsim ;;
  inference)   _dispatch_holosoma inference ;;
  deployment)  install_deployment ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Usage: $0 [all|willow|gmr|retargeting|mujoco|isaacgym|isaacsim|inference|deployment] [upstream|custom|both] [--no-warp]"
    exit 1
    ;;
esac

echo ""
echo "══════════════════════════════════════════"
echo "  Done."
echo "══════════════════════════════════════════"
echo ""
echo "  ~/.willow_deps/          willow_wbt + gmr"
echo "  ~/.holosoma_deps/        holosoma upstream envs"
echo "  ~/.holosoma_custom_deps/ holosoma_custom envs"
echo ""
echo "To activate: source scripts/activate_willow.sh"
echo ""
