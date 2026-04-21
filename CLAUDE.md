# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Always respond, reason, and write in **English** — even if the user writes in French.

## Project Overview

**Willow WBT** is a modular benchmarking framework for Whole-Body Tracking (WBT) on humanoid robots. It provides adapter infrastructure to plug in, compare, and combine research solutions at each pipeline stage: motion retargeting, RL training, and inference/deployment.

External solutions run unchanged in isolated conda environments; Willow provides thin conversion layers between them.

## Environment Setup

```bash
# Install all ecosystems (creates 3 separate miniconda installations)
./install.sh

# Selective installation
./install.sh willow              # willow_wbt + gmr envs only
./install.sh retargeting         # both holosoma retargeting variants
./install.sh mujoco [variant] [--no-warp]
./install.sh isaacgym [variant]
./install.sh isaacsim [variant]
./install.sh inference [variant]
./install.sh deployment          # unitree ROS2

# Activate the main environment before running scripts
source scripts/activate_willow.sh
```

The three conda ecosystems live at:
- `~/.willow_deps/miniconda3` — Willow adapter + GMR + unitree control
- `~/.holosoma_deps/miniconda3` — upstream holosoma (amazon-far/holosoma)
- `~/.holosoma_custom_deps/miniconda3` — custom holosoma fork (Guillaume-Bsst/holosoma_custom)

## Pipeline Commands

```bash
# Retarget motion sequences
python scripts/retarget.py --dataset LAFAN --robot G1 --retargeter GMR [--sequences seq1 seq2]

# Prepare trainer input and launch training
python scripts/train.py --dataset LAFAN --robot G1 --retargeter GMR --trainer holosoma --simulator mjwarp

# Deploy policy in simulation or on real robot
python scripts/infer.py --dataset LAFAN --robot G1 --retargeter GMR --trainer holosoma --mode sim
```

Supported combinations: datasets (LAFAN, SFU, OMOMO), retargeters (GMR, holosoma, holosoma_custom), trainers (holosoma, holosoma_custom), simulators (mjwarp, isaacgym, isaacsim).

## Architecture

### Data Flow

```
Raw dataset → to_retargeter_input() → [retargeter subprocess] → to_unified_output()
                                                                        ↓
                                                              to_trainer_input() → [trainer subprocess]
                                                                                          ↓
                                                                                  [inference subprocess]
```

Every run gets a timestamped directory, stores a full `config.yaml` snapshot, and provides a `latest/` symlink.

### Adapter Layer (`src/motion_convertor/`)

The four public functions in `__init__.py` are the only integration points between Willow and external modules:

| Function | Converts |
|---|---|
| `to_retargeter_input(dataset, retargeter, raw_path, out_path)` | Raw dataset → retargeter native format |
| `to_unified_input(dataset, raw_path, out_path)` | Raw dataset → unified `(T,22,3)` Z-up |
| `to_unified_output(retargeter, output_raw_path, out_path, height)` | Retargeter output → unified |
| `to_trainer_input(retargeter, trainer, output_raw_path, out_path)` | Retargeter output → trainer format |

**Unified format** (defined in `unified.py`):
- `global_joint_positions`: `(T, 22, 3)` float32, Z-up world frame, metres
- `height`: float (subject height)
- `object_poses`: `(T, 7)` float32 optional — `[qw, qx, qy, qz, x, y, z]`
- 22 joints follow SMPL-X convention; quaternions use wxyz (MuJoCo convention) throughout

### Subprocess Isolation (`_subprocess.py`)

External modules run via `subprocess.run(conda run -n {env} ...)`. The `_subprocess.py` module provides:
- `load_module_cfg(stage, module)` — loads YAML from `cfg/{stage}/{module}.yaml`
- `conda_run(env, cmd)` — executes in a specific conda environment
- `run_entry_point(stage, module, entry, args)` — looks up a named entry point from YAML and maps Willow args to CLI flags

### Configuration (`cfg/`)

Each YAML in `cfg/` is the single point of contact between Willow and one external module — it defines the conda env name, command structure, and argument mapping. **Willow args are never hardcoded in scripts.**

| Directory | Purpose |
|---|---|
| `cfg/data.yaml` | Centralized dataset paths and body model paths |
| `cfg/retargeting/` | One YAML per retargeter variant |
| `cfg/training/` | One YAML per trainer/simulator combination |
| `cfg/inference/` | One YAML per inference variant |
| `cfg/processing/` | Dataset preprocessing wrappers (FK, SMPL-H) |

### Module Organization (`modules/`)

External solutions are git submodules under `modules/third_party/`; stage-specific entries (`01_retargeting/`, `02_training/`, etc.) are symlinks into those submodules. **Never modify files in `modules/` directly** — they are upstream code.

Git submodules (see `.gitmodules`):
- `modules/01_retargeting/GMR` — YanjieZe/GMR
- `modules/third_party/holosoma` — amazon-far/holosoma
- `modules/third_party/holosoma_custom` — Guillaume-Bsst/holosoma_custom
- `modules/04_deployment/unitree_ros2` — unitreerobotics/unitree_ros2
- `src/motion_convertor/third_party/InterAct` — wzyabcas/InterAct (OMOMO → holosoma object_interaction preprocessing)
- `src/motion_convertor/third_party/lafan1` — ubisoft/ubisoft-laforge-animation-dataset (LAFAN BVH tools)
- `src/motion_convertor/third_party/human_body_prior` — nghorbani/human_body_prior (SMPL-H FK)

### Adapter internals (`src/motion_convertor/`)

The subpackages use underscore-prefixed names to mark them as internal:

```
src/motion_convertor/
├── __init__.py               # 4 public dispatch functions
├── unified.py                # save_unified / load_unified
├── _config.py                # loads cfg/data.yaml, exposes repo_root(), dataset_path(), body_model_path()
├── _subprocess.py            # conda_run(), run_entry_point()
├── _to_unified_input/        # raw dataset → unified (T,22,3) Z-up
├── _to_retargeter_input/     # raw dataset → retargeter native format
├── _to_unified_output/       # retargeter output → unified
└── _to_trainer_input/        # retargeter output → trainer-native format
```

Most converters in `_to_unified_input/` and `_to_retargeter_input/` delegate via subprocess to `scripts/wrappers/` running in the `hsretargeting` env (using `cfg/processing/holosoma_prep.yaml`). GMR-specific FK runs in the `gmr` env via `scripts/wrappers/gmr_fk.py`. OMOMO object_interaction uses the `interact` env via `scripts/wrappers/omomo_to_intermimic.py`.

### Scripts (`scripts/`)

- `retarget.py` — orchestrates a full retargeting job (per-sequence: convert input → run retargeter → convert output)
- `train.py` — converts retargeter output to trainer input, then launches training
- `infer.py` — runs a trained policy in sim or on real robot
- `activate_willow.sh` — activates the `willow_wbt` conda env from `~/.willow_deps/`
- `wrappers/` — thin scripts that run inside specific conda envs (called via subprocess, not standalone)

## Data Directories

```
data/
├── 00_raw_datasets/    # LAFAN (.bvh), SFU (.npz AMASS), OMOMO (.p)
├── 01_retargeted_motions/   # {dataset}_{robot}/{retargeter}/run_{timestamp}/
└── 02_policies/             # {dataset}_{robot}/{retargeter}_{trainer}/run_{timestamp}/
```

Body model files (SMPL-X v1.1, SMPL-H) are referenced via `cfg/data.yaml` and stored outside the repo.
