#!/usr/bin/env bash
# =============================================================================
# Willow WBT — centralized installer
#
# ~/.willow_deps/miniconda3/
#   envs/willow_wbt/                ← adapter layer + scripts
#   envs/gmr/                       ← GMR retargeter
#   envs/interact/                  ← InterAct preprocessing
#   envs/unitree_control_interface/ ← deployment (ROS2 + unitree SDK)
#
# ~/.holosoma_deps/miniconda3/      ← holosoma_custom envs
#   envs/hsretargeting/
#   envs/hsmujoco/  envs/hsgym/  envs/hssim/
#   envs/hsinference/
#
# Usage:
#   ./install.sh all
#   ./install.sh willow | gmr | interact
#   ./install.sh holosoma_retargeting
#   ./install.sh holosoma_training [mujoco|isaacgym|isaacsim] [--no-warp]
#   ./install.sh holosoma_inference
#   ./install.sh unitree_control_interface
# =============================================================================
set -euo pipefail

REPO_ROOT="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
GMR_DIR="$REPO_ROOT/modules/01_retargeting/GMR"
HOLOSOMA_SCRIPTS="$REPO_ROOT/modules/third_party/holosoma_custom/scripts"

WILLOW_CONDA_ROOT="$HOME/.willow_deps/miniconda3"
HOLOSOMA_CONDA_ROOT="$HOME/.holosoma_deps/miniconda3"

TARGET="${1:-all}"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
_header() { echo ""; echo "══════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════"; }
_ok()     { echo "  ✓ $1"; }

# Bootstraps miniforge at $root and ensures mamba is installed
_ensure_conda() {
  local root="$1" deps_dir="$2"
  if [[ ! -d "$root" ]]; then
    _header "Bootstrapping miniforge → $root"
    mkdir -p "$deps_dir"
    local os arch installer
    os="$(uname -s)"; arch="$(uname -m)"
    if   [[ "$os" == "Linux"  && "$arch" == "aarch64" ]]; then installer="Miniforge3-Linux-aarch64.sh"
    elif [[ "$os" == "Linux"  ]];                          then installer="Miniforge3-Linux-x86_64.sh"
    elif [[ "$os" == "Darwin" && "$arch" == "arm64"   ]]; then installer="Miniforge3-MacOSX-arm64.sh"
    elif [[ "$os" == "Darwin" ]];                          then installer="Miniforge3-MacOSX-x86_64.sh"
    else echo "ERROR: unsupported OS: $os" >&2; exit 1; fi
    local tmp="$deps_dir/miniforge_install.sh"
    curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/$installer" -o "$tmp"
    bash "$tmp" -b -u -p "$root" && rm "$tmp"
  fi
  
  # We use --system so it only applies to the miniconda environments inside $root
  "$root/bin/conda" config --system --add channels conda-forge
  "$root/bin/conda" config --system --set channel_priority strict
  # Remove 'defaults'. The "|| true" prevents the script from crashing if it's already removed.
  "$root/bin/conda" config --system --remove channels defaults 2>/dev/null || true

  [[ -f "$root/bin/mamba" ]] || \
    "$root/bin/conda" install -y mamba -c conda-forge -n base --override-channels 
}

# Creates a conda env with mamba (skips if already exists)
_create_env() {
  local root="$1" name="$2" python="${3:-3.11}"
  local env_root="$root/envs/$name"
  [[ -d "$env_root" ]] && { _ok "env '$name' already exists"; return; }
  "$root/bin/mamba" create -y --prefix "$env_root" python="$python" \
    -c conda-forge --override-channels 
}

# Installs packages with uv into a conda env (bootstraps uv on first call)
_uv_pip() {
  local env_root="$1"; shift
  [[ -f "$env_root/bin/uv" ]] || "$env_root/bin/python" -m pip install uv 
  UV_HTTP_TIMEOUT=300 "$env_root/bin/uv" pip install --python "$env_root/bin/python" --system "$@"
}

# Strips active conda state so holosoma scripts resolve envs in the right root
_clean_bash_pinned() {
  local envs_dir="$1"; shift
  env -u CONDA_PREFIX -u CONDA_DEFAULT_ENV -u CONDA_SHLVL \
      -u CONDA_EXE -u _CONDA_EXE -u CONDA_PYTHON_EXE \
      -u CONDA_PROMPT_MODIFIER -u _CONDA_ROOT -u _CE_M -u _CE_CONDA \
      -u CONDARC -u CONDA_ENVS_PATH \
      CONDA_ENVS_PATH="$envs_dir" "$@"
}

# Pre-creates a holosoma env and writes a uv-backed pip shim into the env's bin/.
# Problem: setup scripts run 'source conda activate', which prepends the env's bin/
# to PATH — shadowing any fake pip we put in a temp dir. By writing our shim directly
# into the env's bin/ BEFORE the script runs, conda activation exposes our shim first.
# The shim filters 'pip install pip' to a no-op so uv doesn't overwrite itself.
# Usage: _holosoma_prep_env <env_name> <python_ver> [extra_conda_pkgs...]
_holosoma_prep_env() {
  local env_name="$1" python_ver="$2"; shift 2
  local env_root="$HOLOSOMA_CONDA_ROOT/envs/$env_name"

  if [[ ! -d "$env_root" ]]; then
    _ensure_conda "$HOLOSOMA_CONDA_ROOT" "$HOME/.holosoma_deps"
    "$HOLOSOMA_CONDA_ROOT/bin/mamba" create -y --prefix "$env_root" \
      python="$python_ver" "$@" -c conda-forge --override-channels 
  fi

  [[ -f "$env_root/bin/uv" ]] || "$env_root/bin/python" -m pip install uv 

  local uv_bin="$env_root/bin/uv"
  local py_bin="$env_root/bin/python"
  cat > "$env_root/bin/pip" <<PIPSHIM
#!/usr/bin/env bash
# Delegates to uv pip. 
# Check if the command is install, to filter "pip install pip"
if [[ "\$1" == "install" ]]; then
  only_pip=1
  for a in "\${@:2}"; do
    if [[ -n "\$a" ]]; then
        [[ "\$a" =~ ^- ]] && continue
        [[ "\$a" =~ ^pip([>=<!@].*)?$ ]] && continue
        only_pip=0; break
    fi
  done
  [[ \$only_pip -eq 1 ]] && exit 0
  
  # Filter out empty arguments that might cause PEP508 errors
  args=()
  for arg in "\$@"; do
    [[ -n "\$arg" ]] && args+=("\$arg")
  done
  exec "$uv_bin" pip install "\${args[@]:1}"
else
  # For other commands (uninstall, list, etc), pass them through
  exec "$uv_bin" pip "\$@"
fi
PIPSHIM
  chmod +x "$env_root/bin/pip"
  ln -sf pip "$env_root/bin/pip3"
}

# Runs a holosoma_custom setup script with isolated conda state.
# Call _holosoma_prep_env first so the env's bin/pip is already the uv shim
# before the setup script activates the env.
# Usage: _holosoma_run [--sudo] [ENV=val ...] <env_name> <script> [script_args...]
#   --sudo    also inject a fake sudo that silently skips apt calls
#   ENV=val   extra environment variables forwarded to the script
_holosoma_run() {
  local with_sudo=0 extra_env=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sudo) with_sudo=1; shift ;;
      *=*)    extra_env+=("$1"); shift ;;
      *)      break ;;
    esac
  done
  local env_name="$1" script="$2"; shift 2

  local fake_dir; fake_dir="$(mktemp -d)"

  if [[ $with_sudo -eq 1 ]]; then
    cat > "$fake_dir/sudo" <<'FAKESUDO'
#!/usr/bin/env bash
if [[ "$*" == *"apt"* ]]; then echo "[install.sh] skipping sudo apt"; exit 0; fi
exec /usr/bin/sudo "$@"
FAKESUDO
    chmod +x "$fake_dir/sudo"
  fi

  _clean_bash_pinned "$HOLOSOMA_CONDA_ROOT/envs" \
    WORKSPACE_DIR="$HOME/.holosoma_deps" \
    ${extra_env[@]+"${extra_env[@]}"} \
    PATH="$fake_dir:$PATH" \
    bash "$script" "$@"
  rm -rf "$fake_dir"
}

# --------------------------------------------------------------------------
# Installers
# --------------------------------------------------------------------------

install_willow() {
  _header "willow_wbt env"
  _ensure_conda "$WILLOW_CONDA_ROOT" "$HOME/.willow_deps"
  _create_env   "$WILLOW_CONDA_ROOT" "willow_wbt"
  _uv_pip "$WILLOW_CONDA_ROOT/envs/willow_wbt" -e "$REPO_ROOT"
  _ok "willow_wbt installed"
}

install_gmr() {
  _header "GMR env"
  _ensure_conda "$WILLOW_CONDA_ROOT" "$HOME/.willow_deps"
  _create_env   "$WILLOW_CONDA_ROOT" "gmr"
  local ENV_ROOT="$WILLOW_CONDA_ROOT/envs/gmr"
  [[ "$(uname -s)" == "Linux" ]] && \
    "$WILLOW_CONDA_ROOT/bin/mamba" install -y --prefix "$ENV_ROOT" \
      -c conda-forge libstdcxx-ng --override-channels 
  _uv_pip "$ENV_ROOT" -e "$GMR_DIR"
  _ok "GMR installed"
}

install_interact() {
  _header "interact env"
  _ensure_conda "$WILLOW_CONDA_ROOT" "$HOME/.willow_deps"
  _create_env   "$WILLOW_CONDA_ROOT" "interact"
  local ENV_ROOT="$WILLOW_CONDA_ROOT/envs/interact"

  _uv_pip "$ENV_ROOT" torch==2.0.0 --index-url https://download.pytorch.org/whl/cpu
  _uv_pip "$ENV_ROOT" scipy trimesh joblib smplx tqdm numpy==1.23.1 poselib PyYAML \
    mujoco lxml numpy-stl opencv-python-headless
  # --ignore-requires-python: human_body_prior pins an old Python version; uv doesn't support
  # this flag, so fall back to pip for this one package.
  "$ENV_ROOT/bin/python" -m pip install --no-deps --ignore-requires-python \
    "$REPO_ROOT/src/motion_convertor/third_party/human_body_prior"
  # CPU-only pytorch3d prebuilt wheel; optional — no matching wheel for py311 but kept for future
  _uv_pip "$ENV_ROOT" \
    --find-links "https://dl.fbaipublicfiles.com/pytorch3d/packaging/wheels/py310_cu117_pyt200/download.html" \
    pytorch3d || true
  # poselib from bundled InterAct submodule (InterMimic dependency)
  local POSELIB="$REPO_ROOT/src/motion_convertor/third_party/InterAct/simulation/poselib"
  [[ -f "$POSELIB/setup.py" ]] && _uv_pip "$ENV_ROOT" --no-deps -e "$POSELIB"

  _ok "interact env installed"
}

install_holosoma_retargeting() {
  _header "holosoma_custom — hsretargeting"
  _holosoma_prep_env hsretargeting 3.11
  _holosoma_run hsretargeting "$HOLOSOMA_SCRIPTS/setup_retargeting.sh"
  _ok "hsretargeting installed"
}

install_holosoma_training() {
  _header "holosoma_custom — training envs"
  local modules=() no_warp=""
  for arg in "$@"; do
    [[ "$arg" == "--no-warp" ]] && no_warp="--no-warp" || modules+=("$arg")
  done
  [[ ${#modules[@]} -eq 0 ]] && modules=(mujoco isaacgym isaacsim)

  for mod in "${modules[@]}"; do
    local script="$HOLOSOMA_SCRIPTS/setup_${mod}.sh"
    [[ -f "$script" ]] || { echo "Warning: setup_${mod}.sh not found — skipping"; continue; }
    _header "holosoma_custom — $mod"
    case "$mod" in
      mujoco)   _holosoma_prep_env hsmujoco 3.10
                _holosoma_run           hsmujoco "$script" ${no_warp:+$no_warp} ;;
      isaacgym) _holosoma_prep_env hsgym 3.8
                _holosoma_run           hsgym    "$script" ;;
      isaacsim) _holosoma_prep_env hssim 3.11
                _holosoma_run --sudo OMNI_KIT_ACCEPT_EULA=1 hssim "$script" ;;
      *)        _holosoma_run           hsmujoco "$script" ;;
    esac
  done
}

install_holosoma_inference() {
  _header "holosoma_custom — hsinference"
  _holosoma_prep_env hsinference 3.11 swig
  _holosoma_run --sudo hsinference "$HOLOSOMA_SCRIPTS/setup_inference_py311.sh"
  local ENV_ROOT="$HOLOSOMA_CONDA_ROOT/envs/hsinference"
  # Install without [unitree]: unitree_sdk2 wheel is cp310-only; we use the ros2 interface.
  _uv_pip "$ENV_ROOT" \
    -e "$REPO_ROOT/modules/third_party/holosoma_custom/src/holosoma_inference"
  [[ "$(uname -m)" == "aarch64" ]] && _uv_pip "$ENV_ROOT" "pin>=3.8.0"
  _ok "hsinference installed"
}

install_unitree_control_interface() {
  _header "deployment — unitree_ros2 + unitree_control_interface"

  local WS="$REPO_ROOT/modules/04_deployment/unitree_ros2/cyclonedds_ws"
  local SRC="$WS/src"
  local UCI_DIR="$SRC/unitree_control_interface"
  local UCI_ENV="unitree_control_interface"
  local ENV_ROOT="$WILLOW_CONDA_ROOT/envs/$UCI_ENV"
  local ENV_PYTHON="$ENV_ROOT/bin/python"
  local SENTINEL="$HOME/.willow_deps/.env_setup_finished_$UCI_ENV"

  # Bootstrap willow miniconda if needed
  _ensure_conda "$WILLOW_CONDA_ROOT" "$HOME/.willow_deps"

  # Ensure submodule is checked out
  git -C "$REPO_ROOT" submodule update --init modules/04_deployment/unitree_ros2

  # Clone unitree_control_interface into workspace if missing
  if [[ ! -d "$UCI_DIR" ]]; then
    echo "  Cloning unitree_control_interface..."
    git clone -b watchdog-logging https://github.com/inria-paris-robotics-lab/unitree_control_interface.git \
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
    # (CORRIGÉ: _ensure_conda a déjà installé mamba, on peut l'appeler directement)
    MAMBA_ROOT_PREFIX="$WILLOW_CONDA_ROOT" "$WILLOW_CONDA_ROOT/bin/mamba" env create \
      --prefix "$ENV_ROOT" \
      -f "$UCI_DIR/environment.yaml" -v
  else
    _ok "conda env '$UCI_ENV' already exists"
  fi

  local MAMBA_BIN="$WILLOW_CONDA_ROOT/bin/mamba"

  # Pin python=3.11
  echo "  Pinning python=3.11..."
  "$MAMBA_BIN" install -y python=3.11 -c conda-forge --override-channels --prefix "$ENV_ROOT"

  # cmake 4.x breaks rosidl_generator_py
  echo "  Pinning cmake=3.28 (rosidl_generator_py compatibility)..."
  "$MAMBA_BIN" install -y cmake=3.28 -c conda-forge --override-channels --prefix "$ENV_ROOT"

  # lttng-ust is the tracing backend
  echo "  Installing lttng-ust (rclcpp tracing backend)..."
  "$MAMBA_BIN" install -y lttng-ust -c conda-forge --override-channels --prefix "$ENV_ROOT"

  # Clone remaining deps via vcs (skip if already imported)
  if [[ ! -f "$ENV_ROOT/bin/vcs" ]]; then
    "$ENV_PYTHON" -m pip install vcstool setuptools
  fi
  # Rewrite SSH URLs to HTTPS so vcs import works without a GitHub SSH key.
  # Use ||/explicit re-raise pattern so the --unset always runs even if vcs fails.
  git config --global url."https://github.com/".insteadOf "git@github.com:"
  _vcs_status=0
  (cd "$SRC" && "$ENV_ROOT/bin/vcs" import --recursive --skip-existing < "$UCI_DIR/git-deps.yaml") || _vcs_status=$?
  git config --global --unset url."https://github.com/".insteadOf
  [[ $_vcs_status -eq 0 ]] || exit $_vcs_status

  # Build colcon workspace
  # set +u: ROS/robostack activate scripts reference CONDA_BUILD (unbound outside conda build)
  (
    set +u
    export PATH="$ENV_ROOT/bin:$PATH"
    export Python_ROOT_DIR="$ENV_ROOT"
    export Python3_ROOT_DIR="$ENV_ROOT"
    _PY_VER="$("$ENV_ROOT/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    export PYTHONPATH="$ENV_ROOT/lib/python${_PY_VER}/site-packages${PYTHONPATH:+:$PYTHONPATH}"
    
    if [[ -f "$ENV_ROOT/setup.bash" ]]; then
      source "$ENV_ROOT/setup.bash"
    fi

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

    # Reinstall cyclonedds python package from source to ensure _clayer is built (needed for aarch64)
    (
      export PATH="$ENV_ROOT/bin:$PATH"
      export CYCLONEDDS_HOME="$WS/install/cyclonedds"
      "$ENV_PYTHON" -m pip install "cyclonedds==0.10.5" --no-binary :all: --force-reinstall 
    )

    # B. Build all remaining packages (unitree_sdk2py = package name for src/unitree_sdk2_python)
    colcon build --packages-skip unitree_sdk2py --cmake-args "${CMAKE_ARGS[@]}"
  )

  # Install unitree_sdk2_python (editable, needs CYCLONEDDS_HOME)
  (
    set +u
    export PATH="$ENV_ROOT/bin:$PATH"
    cd "$WS"
    source install/setup.bash
    export CYCLONEDDS_HOME="$WS/install/cyclonedds"
    "$ENV_PYTHON" -m pip install -e "$SRC/unitree_sdk2_python" 
  )

  touch "$SENTINEL"
  _ok "deployment stack installed — env: $UCI_ENV"
  echo ""
  echo "  To use:"
  echo "    conda activate $UCI_ENV"
  echo "    source $WS/install/setup.bash"
}


# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
case "$TARGET" in
  all)
    install_willow; install_gmr; install_interact
    install_holosoma_retargeting; install_holosoma_training; install_holosoma_inference
    install_unitree_control_interface
    ;;
  willow)                    install_willow ;;
  gmr)                       install_gmr ;;
  interact)                  install_interact ;;
  holosoma_retargeting)      install_holosoma_retargeting ;;
  holosoma_training)         shift; install_holosoma_training "$@" ;;
  holosoma_inference)        install_holosoma_inference ;;
  unitree_control_interface) install_unitree_control_interface ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Usage: $0 [all|willow|gmr|interact|holosoma_retargeting|holosoma_training|holosoma_inference|unitree_control_interface]"
    exit 1
    ;;
esac

echo ""
echo "  ~/.willow_deps/     willow_wbt, gmr, interact, unitree_control_interface"
echo "  ~/.holosoma_deps/   holosoma_custom envs (hs*)"
echo "  To activate: source scripts/activate_willow.sh"
