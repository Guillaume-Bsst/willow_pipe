# Willow WBT

A modular benchmarking and integration framework for humanoid robot Whole-Body Tracking (WBT). The goal is not to implement a single pipeline, but to provide the infrastructure to **plug in, compare, and combine** existing solutions at each stage of the WBT pipeline — from motion retargeting to RL training to real-robot deployment.

Each stage is interchangeable. Every run is versioned and traceable. Any two solutions can be compared on the same data under the same conditions.

---

## Philosophy

Most WBT research produces isolated solutions: a retargeter here, a trainer there, an inference stack somewhere else. Getting them to work together requires ad-hoc glue code that makes fair comparison impossible.

Willow WBT solves this by defining:

1. **A unified data format** — a common interface between all stages so any retargeter can feed any trainer
2. **Adapters** (`src/motion_convertor/`) — thin translation layers that convert each solution's native I/O to/from the unified format, without modifying the solutions themselves
3. **Versioned runs** — every run stores its config, inputs, and outputs so results are reproducible and comparable
4. **A modular module registry** (`modules/`) — existing solutions are plugged in as submodules or symlinks, untouched

---

## Pipeline Overview

```
Raw MoCap datasets (LAFAN1, OMOMO, SFU, ...)
        │
        ▼
  00_raw_datasets/
        │
        │  scripts/retarget.py       ← run any retargeter on any dataset
        │  src/motion_convertor/     ← adapter: dataset/retargeter formats ↔ unified format
        ▼
  01_retargeted_motions/             ← {dataset}_{robot}/{retargeter}/run_{timestamp}/
        │                                 native input, unified input
        │                                 native output, unified output
        │                                 config.yaml
        │  scripts/train.py          ← run any trainer on any retargeted motion
        │  src/motion_convertor/     ← adapter: retargeter output → trainer input format
        ▼
  02_policies/                       ← {dataset}_{robot}/{retargeter}_{trainer}/run_{timestamp}/
        │
        │  scripts/infer.py          ← deploy any policy in sim or on real robot
        │                               sdk_type: mujoco | ros2
        ▼
  04_deployment/
        │  unitree_ros2 + unitree_control_interface
        ▼
     Unitree G1 (or other humanoid) — sim or real
```

→ Format details: [data/01_retargeted_motions/README.md](data/01_retargeted_motions/README.md)

---

## Currently Integrated Solutions

### Retargeters

| Retargeter | Source | Datasets |
|------------|--------|---------|
| **GMR** | [YanjieZe/GMR](https://github.com/YanjieZe/GMR) | LAFAN1, SFU, OMOMO robot_only |
| **holosoma_retargeting** | [amazon-far/holosoma](https://github.com/amazon-far/holosoma) | LAFAN1, SFU, OMOMO robot_only + object_interaction |
| **holosoma_retargeting_custom** | [Guillaume-Bsst/holosoma_custom](https://github.com/Guillaume-Bsst/holosoma_custom) | LAFAN1, SFU, OMOMO robot_only + object_interaction |

### Trainers

| Trainer | Source | Algorithms | Simulators |
|---------|--------|-----------|-----------|
| **holosoma** | [amazon-far/holosoma](https://github.com/amazon-far/holosoma) | PPO, FastSAC | IsaacGym, IsaacSim, MJWarp |
| **holosoma_custom** | [Guillaume-Bsst/holosoma_custom](https://github.com/Guillaume-Bsst/holosoma_custom) | PPO, FastSAC | IsaacGym, IsaacSim, MJWarp |

### Inference

| Engine | Source | Modes |
|--------|--------|-------|
| **holosoma_inference** | [amazon-far/holosoma](https://github.com/amazon-far/holosoma) | MuJoCo sim, real Unitree G1 |
| **holosoma_inference_custom** | [Guillaume-Bsst/holosoma_custom](https://github.com/Guillaume-Bsst/holosoma_custom) | MuJoCo sim, real Unitree G1, **ROS2** |

### Deployment

| Bridge | Source | Modes |
|--------|--------|-------|
| **unitree_ros2** | [unitreerobotics/unitree_ros2](https://github.com/unitreerobotics/unitree_ros2) | sim-to-sim, sim-to-real via ROS2 |

---

## Adding a New Solution

The framework is designed to make integration straightforward:

1. **New retargeter** — add as submodule in `modules/01_retargeting/`, write an adapter in `src/motion_convertor/` that converts its I/O to/from unified format
2. **New trainer** — add as submodule in `modules/02_training/`, write an adapter in `src/motion_convertor/to_trainer_input/`
3. **New dataset** — add download instructions in `data/00_raw_datasets/README.md`, write a prep converter in `src/motion_convertor/`
4. **New inference engine** — add as submodule in `modules/03_inference/`, plug into `scripts/infer.py`
5. **New deployment target** — add as submodule in `modules/04_deployment/`

In all cases, the existing solutions and data are untouched.

---

## Repository Structure

```
willow_wbt/
├── data/
│   ├── 00_raw_datasets/       → see data/00_raw_datasets/README.md
│   ├── 01_retargeted_motions/ → see data/01_retargeted_motions/README.md
│   └── 02_policies/
│
├── cfg/                       # module configs — see cfg/README.md
│   ├── data.yaml              # dataset paths + body model locations
│   ├── retargeting/
│   │   ├── gmr.yaml
│   │   ├── holosoma_retargeting.yaml
│   │   └── holosoma_retargeting_custom.yaml
│   ├── training/
│   │   ├── holosoma.yaml
│   │   └── holosoma_custom.yaml
│   └── inference/
│       ├── holosoma_inference.yaml
│       └── holosoma_inference_custom.yaml
│
├── scripts/                   → see scripts/README.md
│   ├── retarget.py
│   ├── train.py
│   ├── infer.py
│   ├── activate_willow.sh     # source this to activate the ecosystem
│   └── wrappers/              # thin scripts that run inside module envs
│
├── src/
│   └── motion_convertor/      → see src/motion_convertor/README.md
│
├── install.sh                 # one-shot installer for all envs
│
└── modules/
    ├── 01_retargeting/
    │   ├── GMR/                            # submodule — YanjieZe/GMR
    │   ├── holosoma_retargeting            # symlink → third_party/holosoma
    │   └── holosoma_retargeting_custom     # symlink → third_party/holosoma_custom
    ├── 02_training/
    │   ├── holosoma                        # symlink → third_party/holosoma
    │   └── holosoma_custom                 # symlink → third_party/holosoma_custom
    ├── 03_inference/
    │   ├── holosoma_inference              # symlink → third_party/holosoma
    │   └── holosoma_inference_custom       # symlink → third_party/holosoma_custom
    ├── 04_deployment/
    │   └── unitree_ros2/                   # submodule — unitreerobotics/unitree_ros2
    └── third_party/
        ├── holosoma/                       # submodule — amazon-far/holosoma
        └── holosoma_custom/                # submodule — Guillaume-Bsst/holosoma_custom
```

---

## Installation

### 1 — Clone with submodules
```bash
git clone --recurse-submodules <repo-url>
# or after cloning:
git submodule update --init --recursive
```

### 2 — Install all envs
```bash
./install.sh
```

Three isolated ecosystems, nothing touches your system conda:

| Ecosystem | Location | Envs |
|-----------|----------|------|
| willow + GMR | `~/.willow_deps/` | `willow_wbt`, `gmr` |
| holosoma upstream | `~/.holosoma_deps/` | `hsretargeting`, `hsmujoco`, `hsgym`, `hssim`, `hsinference` |
| holosoma_custom | `~/.holosoma_custom_deps/` | `hsretargeting`, `hsmujoco`, `hsgym`, `hssim`, `hsinference` |
| deployment | your system conda | `unitree_control_interface` |

Re-running is safe — already-installed envs are skipped via sentinel files.

**Selective install:**
```bash
./install.sh willow
./install.sh gmr
./install.sh retargeting [upstream|custom|both]
./install.sh mujoco      [upstream|custom|both] [--no-warp]
./install.sh isaacgym    [upstream|custom|both]
./install.sh isaacsim    [upstream|custom|both]
./install.sh inference   [upstream|custom|both]
./install.sh deployment
```

### 3 — Activate the ecosystem
```bash
source scripts/activate_willow.sh
```

Points your shell to `~/.willow_deps/miniconda3` and activates `willow_wbt`. Switch to other envs with `conda activate <env>` as usual.

### 4 — Configure data paths
Edit `cfg/data.yaml` to point to your local dataset and body model locations (defaults assume standard layout under `data/00_raw_datasets/`).
