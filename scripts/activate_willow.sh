#!/usr/bin/env bash
# =============================================================================
# Willow WBT — ecosystem activation
#
# Source this file (do NOT run it) to activate the willow ecosystem:
#
#   source scripts/activate_willow.sh
#
# What it does:
#   - Points WORKSPACE_DIR to ~/.willow_deps  (isolated from ~/.holosoma_deps)
#   - Adds ~/.willow_deps/miniconda3 to PATH
#   - Activates the willow_wbt conda env
#
# After sourcing, use conda normally:
#   conda activate gmr
#   conda activate hsretargeting
#   etc.
# =============================================================================

# Guard: must be sourced, not executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: activate_willow.sh must be sourced, not executed."
  echo "  Use:  source scripts/activate_willow.sh"
  exit 1
fi

export WORKSPACE_DIR="$HOME/.willow_deps"
export CONDA_ROOT="$WORKSPACE_DIR/miniconda3"

# Add willow miniconda to PATH (prepend so it takes priority)
if [[ -d "$CONDA_ROOT/bin" ]]; then
  export PATH="$CONDA_ROOT/bin:$PATH"
fi

# Initialize conda for this shell session
if [[ -f "$CONDA_ROOT/etc/profile.d/conda.sh" ]]; then
  source "$CONDA_ROOT/etc/profile.d/conda.sh"
else
  echo "WARNING: willow miniconda not found at $CONDA_ROOT"
  echo "  Run ./install.sh first."
  return 1
fi

conda activate willow_wbt
echo "Willow WBT ecosystem active — all envs in $CONDA_ROOT/envs/"
