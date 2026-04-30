#!/usr/bin/env bash
# =============================================================================
# Willow WBT — centralized installer
#
# Three miniconda ecosystems, fully isolated:
#
#   ~/.willow_deps/miniconda3/
#     envs/willow_wbt/               ← adapter layer + scripts
#     envs/gmr/                      ← GMR retargeter
#     envs/unitree_control_interface/ ← deployment (ROS2 + unitree SDK)
#
#   ~/.holosoma_deps/miniconda3/     ← holosoma upstream
#     envs/hsretargeting/
#     envs/hsmujoco/
#     envs/hsgym/
#     envs/hssim/
#     envs/hsinference/
#
#   ~/.holosoma_custom_deps/miniconda3/ ← holosoma_custom (your fork)
#     envs/hscretargeting/
#     envs/hscmujoco/
#     envs/hscgym/
#     envs/hscsim/
#     envs/hscinference/
#
# Usage:
#   ./install.sh                        # install everything (all variants)
#   ./install.sh willow                 # willow_wbt env only
#   ./install.sh gmr                    # GMR env only
#   ./install.sh interact               # InterAct env (OMOMO object_interaction)
#   ./install.sh retargeting            # both holosoma variants
#   ./install.sh retargeting upstream   # holosoma upstream only
#   ./install.sh retargeting custom     # holosoma_custom only
#   ./install.sh mujoco [upstream|custom] [--no-warp]
#   ./install.sh isaacgym [upstream|custom]
#   ./install.sh isaacsim [upstream|custom]
#   ./install.sh inference [upstream|custom]
#   ./install.sh deployment             # unitree_ros2 + unitree_control_interface
# =============================================================================
set -euo pipefail

REPO_ROOT="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
GMR_DIR="$REPO_ROOT/modules/01_retargeting/GMR"

HOLOSOMA_UPSTREAM_SCRIPTS="$REPO_ROOT/modules/third_party/holosoma/scripts"
HOLOSOMA_CUSTOM_SCRIPTS="$REPO_ROOT/modules/third_party/holosoma_custom/scripts"

# willow's own miniconda (willow_wbt + gmr + unitree_control_interface)
WILLOW_CONDA_ROOT="$HOME/.willow_deps/miniconda3"
WILLOW_CONDA_BIN="$WILLOW_CONDA_ROOT/bin/conda"
WILLOW_MAMBA_BIN="$WILLOW_CONDA_ROOT/bin/mamba"

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

# Run a script in a shell with all conda state stripped, so the active
# willow_wbt env does not bleed into holosoma's mamba env resolution.
_clean_bash() {
  env -u CONDA_PREFIX -u CONDA_DEFAULT_ENV -u CONDA_SHLVL \
      -u CONDA_EXE -u _CONDA_EXE -u CONDA_PYTHON_EXE \
      -u CONDA_PROMPT_MODIFIER -u _CONDA_ROOT -u _CE_M -u _CE_CONDA \
      "$@"
}

_ensure_mamba() {
  local root="$1"
  local conda="$root/bin/conda"
  local mamba="$root/bin/mamba"
  if [[ -d "$root" ]] && [[ ! -f "$mamba" ]]; then
    echo "  Installing mamba in $root..."
    "$conda" install -y mamba -c conda-forge -n base --quiet
  fi
}

# Build a fake pip wrapper that calls python -m pip on a given env.
# Uses a dynamic lookup so it works even before the env is created
# (the env is created by the setup script itself before any pip call).
_make_fake_pip() {
  local fake_dir="$1"
  local env_python="$2"   # absolute path to the env's python once created
  cat > "$fake_dir/pip" <<FAKEPIP
#!/usr/bin/env bash
exec "$env_python" -m pip "\$@"
FAKEPIP
  chmod +x "$fake_dir/pip"
}

_make_fake_sudo_skip_apt() {
  local fake_dir="$1"
  cat > "$fake_dir/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
if [[ "$*" == *"apt"* ]]; then
  echo "[install.sh] skipping sudo apt (dependencies pre-installed via mamba)"
  exit 0
fi
exec /usr/bin/sudo "$@"
FAKESUDO
  chmod +x "$fake_dir/sudo"
}

# --------------------------------------------------------------------------
# Bootstrap willow miniforge (for willow_wbt, gmr, unitree_control_interface)
# --------------------------------------------------------------------------
_bootstrap_willow_miniconda() {
  if [[ -d "$WILLOW_CONDA_ROOT" ]]; then 
    _ensure_mamba "$WILLOW_CONDA_ROOT"
    return
  fi

  _header "Bootstrapping willow miniforge → $WILLOW_CONDA_ROOT"
  mkdir -p "$HOME/.willow_deps"

  OS_NAME="$(uname -s)"; ARCH_NAME="$(uname -m)"
  if [[ "$OS_NAME" == "Linux" ]]; then
    if [[ "$ARCH_NAME" == "aarch64" ]]; then
      INSTALLER="Miniforge3-Linux-aarch64.sh"
    else
      INSTALLER="Miniforge3-Linux-x86_64.sh"
    fi
  elif [[ "$OS_NAME" == "Darwin" ]]; then
    if [[ "$ARCH_NAME" == "arm64" ]]; then
      INSTALLER="Miniforge3-MacOSX-arm64.sh"
    else
      INSTALLER="Miniforge3-MacOSX-x86_64.sh"
    fi
  else
    echo "ERROR: unsupported OS: $OS_NAME" >&2; exit 1
  fi

  TMP="$HOME/.willow_deps/miniforge_install.sh"
  curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/${INSTALLER}" -o "$TMP"
  bash "$TMP" -b -u -p "$WILLOW_CONDA_ROOT"
  rm "$TMP"
  
  _ensure_mamba "$WILLOW_CONDA_ROOT"
  _ok "willow miniforge installed at $WILLOW_CONDA_ROOT"
}

_ensure_willow_env() {
  local name="$1" python="${2:-3.10}"
  local env_root="$WILLOW_CONDA_ROOT/envs/$name"
  if [[ ! -d "$env_root" ]]; then
    echo "  Creating env '$name' (python $python)..."
    _ensure_mamba "$WILLOW_CONDA_ROOT"
    MAMBA_ROOT_PREFIX="$WILLOW_CONDA_ROOT" "$WILLOW_MAMBA_BIN" create -y \
      --prefix "$env_root" python="$python" -c conda-forge --override-channels
    # Bootstrap uv into the new env for fast package installs
    "$env_root/bin/python" -m pip install uv --quiet
  else
    _ok "env '$name' already exists in ~/.willow_deps"
  fi
}

# Prefer uv if available in the env, fallback to python -m pip
_uv_install() {
  local env_root="$1"; shift
  local force_pip=0

  for arg in "$@"; do
    if [[ "$arg" == "--ignore-requires-python" ]]; then
      force_pip=1
      break
    fi
  done

  if [[ -f "$env_root/bin/uv" && "$force_pip" -eq 0 ]]; then
    "$env_root/bin/uv" pip install --python "$env_root/bin/python" --system "$@"
  else
    "$env_root/bin/python" -m pip install "$@"
  fi
}


# --------------------------------------------------------------------------
# willow_wbt
# --------------------------------------------------------------------------
install_willow() {
  _header "willow_wbt env"
  _bootstrap_willow_miniconda
  _ensure_willow_env "willow_wbt"
  _uv_install "$WILLOW_CONDA_ROOT/envs/willow_wbt" -e "$REPO_ROOT"
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
  _uv_install "$WILLOW_CONDA_ROOT/envs/gmr" -e "$GMR_DIR"
  _ok "GMR installed (editable)"
}

# --------------------------------------------------------------------------
# InterAct — interact env (OMOMO object_interaction preprocessing)
# --------------------------------------------------------------------------
install_interact() {
  _header "interact env (InterAct + InterMimic)"
  _bootstrap_willow_miniconda
  _ensure_willow_env "interact" "3.10"

  local ENV_ROOT="$WILLOW_CONDA_ROOT/envs/interact"
  local INTERACT_DIR="$REPO_ROOT/src/motion_convertor/third_party/InterAct"
  local INTERMIMIC_DIR="$INTERACT_DIR/simulation"

  # pytorch3d has no official pip wheel for torch 2.0 — install from source via conda-forge
  # or skip CUDA and use the pre-built CPU wheel (sufficient for preprocessing)
  _uv_install "$ENV_ROOT" \
    torch==2.0.0 --index-url https://download.pytorch.org/whl/cpu
  _uv_install "$ENV_ROOT" \
    scipy trimesh joblib smplx tqdm numpy==1.23.1 poselib PyYAML \
    mujoco lxml numpy-stl opencv-python-headless
  # human-body-prior from bundled submodule (same as hsretargeting)
  _uv_install "$ENV_ROOT" \
    --no-deps --ignore-requires-python \
    "$REPO_ROOT/src/motion_convertor/third_party/human_body_prior"
  # pytorch3d — CPU-only prebuilt wheel for torch 2.0 / py3.10 / Linux
  _uv_install "$ENV_ROOT" \
    --find-links https://dl.fbaipublicfiles.com/pytorch3d/packaging/wheels/py310_cu117_pyt200/download.html \
    pytorch3d || true
  # poselib (bundled in InterAct/simulation/poselib)
  if [[ -f "$INTERMIMIC_DIR/poselib/setup.py" ]]; then
    _uv_install "$ENV_ROOT" --no-deps -e "$INTERMIMIC_DIR/poselib"
  fi

  _ok "interact env installed"
}

# --------------------------------------------------------------------------
# holosoma upstream  →  ~/.holosoma_deps/
# (source_common.sh hardcodes ~/.holosoma_deps — upstream scripts untouched)
# All setup_*.sh scripts create the env themselves before calling pip,
# so the fake pip wrapper only needs to exist at call time, not before.
# --------------------------------------------------------------------------
install_retargeting_upstream() {
  _header "holosoma upstream — hsretargeting"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_deps/miniconda3/envs/hsretargeting/bin/python"
  _clean_bash PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_UPSTREAM_SCRIPTS/setup_retargeting.sh"
  rm -rf "$FAKE_DIR"

  # Install human_body_prior from submodule (needed for AMASS/SFU preprocessing)
  _header "human_body_prior → hsretargeting"
  "$HOME/.holosoma_deps/miniconda3/envs/hsretargeting/bin/pip" install \
    --no-deps --ignore-requires-python \
    "$REPO_ROOT/src/motion_convertor/third_party/human_body_prior"
}

install_mujoco_upstream() {
  _header "holosoma upstream — hsmujoco"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_deps/miniconda3/envs/hsmujoco/bin/python"
  _clean_bash PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_UPSTREAM_SCRIPTS/setup_mujoco.sh" $NO_WARP
  rm -rf "$FAKE_DIR"
}

install_isaacgym_upstream() {
  _header "holosoma upstream — hsgym"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_deps/miniconda3/envs/hsgym/bin/python"
  _clean_bash PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_UPSTREAM_SCRIPTS/setup_isaacgym.sh"
  rm -rf "$FAKE_DIR"
}

install_isaacsim_upstream() {
  _header "holosoma upstream — hssim"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_deps/miniconda3/envs/hssim/bin/python"
  _make_fake_sudo_skip_apt "$FAKE_DIR"
  _clean_bash OMNI_KIT_ACCEPT_EULA=1 PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_UPSTREAM_SCRIPTS/setup_isaacsim.sh"
  rm -rf "$FAKE_DIR"
}

install_inference_upstream() {
  _header "holosoma upstream — hsinference"
  local UPSTREAM_CONDA="$HOME/.holosoma_deps/miniconda3"
  if [[ -d "$UPSTREAM_CONDA" ]] && [[ ! -d "$UPSTREAM_CONDA/envs/hsinference" ]]; then
    echo "  Pre-installing swig via conda (no sudo required)..."
    "$UPSTREAM_CONDA/bin/conda" create -y \
      --prefix "$UPSTREAM_CONDA/envs/hsinference" \
      python=3.10 swig pip -c conda-forge --quiet
  elif [[ -d "$UPSTREAM_CONDA" ]]; then
    "$UPSTREAM_CONDA/bin/conda" install -y \
      --prefix "$UPSTREAM_CONDA/envs/hsinference" \
      swig pip -c conda-forge --quiet
  fi
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_deps/miniconda3/envs/hsinference/bin/python"
  _make_fake_sudo_skip_apt "$FAKE_DIR"
  _clean_bash PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_UPSTREAM_SCRIPTS/setup_inference.sh"
  rm -rf "$FAKE_DIR"
}

# --------------------------------------------------------------------------
# holosoma_custom  →  ~/.holosoma_custom_deps/
# Env names hardcoded hsc* in the fork scripts.
# --------------------------------------------------------------------------
install_retargeting_custom() {
  _header "holosoma_custom — hscretargeting"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_custom_deps/miniconda3/envs/hscretargeting/bin/python"
  _clean_bash WORKSPACE_DIR="$HOME/.holosoma_custom_deps" PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_CUSTOM_SCRIPTS/setup_retargeting.sh"
  rm -rf "$FAKE_DIR"
}

install_mujoco_custom() {
  _header "holosoma_custom — hscmujoco"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_custom_deps/miniconda3/envs/hscmujoco/bin/python"
  _clean_bash WORKSPACE_DIR="$HOME/.holosoma_custom_deps" PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_CUSTOM_SCRIPTS/setup_mujoco.sh" $NO_WARP
  rm -rf "$FAKE_DIR"
}

install_isaacgym_custom() {
  _header "holosoma_custom — hscgym"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_custom_deps/miniconda3/envs/hscgym/bin/python"
  _clean_bash WORKSPACE_DIR="$HOME/.holosoma_custom_deps" PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_CUSTOM_SCRIPTS/setup_isaacgym.sh"
  rm -rf "$FAKE_DIR"
}

install_isaacsim_custom() {
  _header "holosoma_custom — hscsim"
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_custom_deps/miniconda3/envs/hscsim/bin/python"
  _make_fake_sudo_skip_apt "$FAKE_DIR"
  _clean_bash OMNI_KIT_ACCEPT_EULA=1 WORKSPACE_DIR="$HOME/.holosoma_custom_deps" PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_CUSTOM_SCRIPTS/setup_isaacsim.sh"
  rm -rf "$FAKE_DIR"
}

install_inference_custom() {
  _header "holosoma_custom — hscinference"
  local CUSTOM_CONDA="$HOME/.holosoma_custom_deps/miniconda3"
  if [[ -d "$CUSTOM_CONDA" ]] && [[ ! -d "$CUSTOM_CONDA/envs/hscinference" ]]; then
    echo "  Pre-installing swig via conda (no sudo required)..."
    "$CUSTOM_CONDA/bin/conda" create -y \
      --prefix "$CUSTOM_CONDA/envs/hscinference" \
      python=3.11 swig pip -c conda-forge --quiet
  elif [[ -d "$CUSTOM_CONDA" ]]; then
    "$CUSTOM_CONDA/bin/conda" install -y \
      --prefix "$CUSTOM_CONDA/envs/hscinference" \
      swig pip -c conda-forge --quiet
  fi
  local FAKE_DIR; FAKE_DIR="$(mktemp -d)"
  _make_fake_pip "$FAKE_DIR" "$HOME/.holosoma_custom_deps/miniconda3/envs/hscinference/bin/python"
  _make_fake_sudo_skip_apt "$FAKE_DIR"
  _clean_bash WORKSPACE_DIR="$HOME/.holosoma_custom_deps" PATH="$FAKE_DIR:$PATH" bash "$HOLOSOMA_CUSTOM_SCRIPTS/setup_inference.sh"
  rm -rf "$FAKE_DIR"
  # tyro is not a dependency of holosoma_inference — install it explicitly.
  "$CUSTOM_CONDA/envs/hscinference/bin/pip" install tyro --quiet
}

# --------------------------------------------------------------------------
# deployment — unitree_ros2 + unitree_control_interface
#
# Env: unitree_control_interface  →  ~/.willow_deps/miniconda3/envs/
# Workspace (colcon build): modules/04_deployment/unitree_ros2/cyclonedds_ws/
# Sentinel: ~/.willow_deps/.env_setup_finished_unitree_control_interface
# --------------------------------------------------------------------------
install_deployment() {
  _header "deployment — unitree_ros2 + unitree_control_interface"

  local WS="$REPO_ROOT/modules/04_deployment/unitree_ros2/cyclonedds_ws"
  local SRC="$WS/src"
  local UCI_DIR="$SRC/unitree_control_interface"
  local UCI_ENV="unitree_control_interface"
  local ENV_ROOT="$WILLOW_CONDA_ROOT/envs/$UCI_ENV"
  local ENV_PYTHON="$ENV_ROOT/bin/python"
  local SENTINEL="$HOME/.willow_deps/.env_setup_finished_$UCI_ENV"

  # Bootstrap willow miniconda if needed
  _bootstrap_willow_miniconda

  # Ensure submodule is checked out
  git -C "$REPO_ROOT" submodule update --init modules/04_deployment/unitree_ros2

  # Clone unitree_control_interface into workspace if missing
  if [[ ! -d "$UCI_DIR" ]]; then
    echo "  Cloning unitree_control_interface..."
    git clone https://github.com/inria-paris-robotics-lab/unitree_control_interface.git \
      --recursive "$UCI_DIR"
  else
    _ok "unitree_control_interface already cloned"
  fi

  if [[ -f "$SENTINEL" ]]; then
    _ok "unitree_control_interface env already installed (sentinel found)"
    return
  fi

  # Create conda env in ~/.willow_deps/miniconda3/
  if [[ ! -d "$ENV_ROOT" ]]; then
    echo "  Creating conda env '$UCI_ENV' in ~/.willow_deps/..."
    if [[ ! -f "$WILLOW_CONDA_ROOT/bin/mamba" ]]; then
      "$WILLOW_CONDA_BIN" install -y mamba -c conda-forge -n base --quiet
    fi
    MAMBA_ROOT_PREFIX="$WILLOW_CONDA_ROOT" "$WILLOW_CONDA_ROOT/bin/mamba" env create \
      --prefix "$ENV_ROOT" \
      -f "$UCI_DIR/environment.yaml"
  else
    _ok "conda env '$UCI_ENV' already exists"
  fi

  # cmake 4.x breaks rosidl_generator_py (ROS Humble) — pin to 3.28
  echo "  Pinning cmake=3.28 (rosidl_generator_py compatibility)..."
  "$WILLOW_CONDA_BIN" install -y cmake=3.28 -c conda-forge --prefix "$ENV_ROOT" --quiet

  # lttng-ust is the tracing backend required by rclcpp's TRACEPOINT macros.
  # Without it, unitree_control_interface fails to compile on aarch64 with robostack.
  echo "  Installing lttng-ust (rclcpp tracing backend)..."
  "$WILLOW_CONDA_BIN" install -y lttng-ust -c conda-forge --prefix "$ENV_ROOT" --quiet

  # Clone remaining deps via vcs (skip if already imported)
  if [[ ! -f "$ENV_ROOT/bin/vcs" ]]; then
    "$ENV_PYTHON" -m pip install vcstool --quiet
  fi
  # Remove directories that exist but are not valid git repos (broken clone from a
  # previous failed SSH attempt) so vcs --skip-existing doesn't silently skip them.
  for _dir in "$SRC"/*/; do
    if [[ -d "$_dir" ]] && [[ ! -d "$_dir/.git" ]]; then
      echo "  Removing incomplete clone: $_dir"
      rm -rf "$_dir"
    fi
  done
  # Rewrite SSH URLs to HTTPS so vcs import works without a GitHub SSH key
  git config --global url."https://github.com/".insteadOf "git@github.com:"
  (cd "$SRC" && "$ENV_ROOT/bin/vcs" import --recursive --skip-existing < "$UCI_DIR/git-deps.yaml")
  git config --global --unset url."https://github.com/".insteadOf

  # Build colcon workspace
  # set +u: ROS/robostack activate scripts reference CONDA_BUILD (unbound outside conda build)
  (
    set +u
    export PATH="$ENV_ROOT/bin:$PATH"
    export Python_ROOT_DIR="$ENV_ROOT"
    export Python3_ROOT_DIR="$ENV_ROOT"
    export PYTHONPATH="$ENV_ROOT/lib/python3.11/site-packages${PYTHONPATH:+:$PYTHONPATH}"
    source "$ENV_ROOT/setup.bash"

    cd "$WS"
    CMAKE_ARGS=(
      "-DPython_ROOT_DIR=$ENV_ROOT"
      "-DPython3_ROOT_DIR=$ENV_ROOT"
      "-DPython_EXECUTABLE=$ENV_ROOT/bin/python"
      "-DPython3_EXECUTABLE=$ENV_ROOT/bin/python"
      "-DPYTHON_EXECUTABLE=$ENV_ROOT/bin/python"
      "-DCMAKE_CXX_FLAGS=-DTRACETOOLS_DISABLED"
    )

    # A. Build cyclonedds first (others depend on it)
    colcon build --packages-select cyclonedds --cmake-args "${CMAKE_ARGS[@]}"
    source install/setup.bash

    # B. Build all remaining packages
    colcon build --packages-skip unitree_sdk2_python --cmake-args "${CMAKE_ARGS[@]}"
  )

  # Install unitree_sdk2_python (editable, needs CYCLONEDDS_HOME)
  (
    set +u
    export PATH="$ENV_ROOT/bin:$PATH"
    cd "$WS"
    source install/setup.bash
    export CYCLONEDDS_HOME="$WS/install/cyclonedds"
    "$ENV_PYTHON" -m pip install -e "$SRC/unitree_sdk2_python" --quiet
  )

  touch "$SENTINEL"
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
  local fn="$1"
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
    install_interact
    _dispatch_holosoma retargeting
    _dispatch_holosoma mujoco
    _dispatch_holosoma isaacgym
    _dispatch_holosoma isaacsim
    _dispatch_holosoma inference
    install_deployment
    ;;
  willow)      install_willow ;;
  gmr)         install_gmr ;;
  interact)    install_interact ;;
  retargeting) _dispatch_holosoma retargeting ;;
  mujoco)      _dispatch_holosoma mujoco ;;
  isaacgym)    _dispatch_holosoma isaacgym ;;
  isaacsim)    _dispatch_holosoma isaacsim ;;
  inference)   _dispatch_holosoma inference ;;
  deployment)  install_deployment ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Usage: $0 [all|willow|gmr|interact|retargeting|mujoco|isaacgym|isaacsim|inference|deployment] [upstream|custom|both] [--no-warp]"
    exit 1
    ;;
esac

echo ""
echo "══════════════════════════════════════════"
echo "  Done."
echo "══════════════════════════════════════════"
echo ""
echo "  ~/.willow_deps/          willow_wbt, gmr, unitree_control_interface"
echo "  ~/.holosoma_deps/        holosoma upstream envs"
echo "  ~/.holosoma_custom_deps/ holosoma_custom envs"
echo ""
echo "To activate: source scripts/activate_willow.sh"
echo ""
