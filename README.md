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
        ▼
     Unitree G1 (or other humanoid)
```

→ Format details: [data/01_retargeted_motions/README.md](data/01_retargeted_motions/README.md)

---

## Currently Integrated Solutions

### Retargeters

| Retargeter | Source | Datasets |
|------------|--------|---------|
| **GMR** | [YanjieZe/GMR](https://github.com/YanjieZe/GMR) | LAFAN1, SFU, OMOMO robot_only |
| **holosoma_retargeter** | [amazon-far/holosoma](https://github.com/amazon-far/holosoma) | LAFAN1, SFU, OMOMO robot_only + object_interaction |

### Trainers

| Trainer | Source | Algorithms | Simulators |
|---------|--------|-----------|-----------|
| **holosoma** | [amazon-far/holosoma](https://github.com/amazon-far/holosoma) | PPO, FastSAC | IsaacGym, IsaacSim, MJWarp |

### Inference

| Engine | Source | Modes |
|--------|--------|-------|
| **holosoma_inference** | [amazon-far/holosoma](https://github.com/amazon-far/holosoma) | MuJoCo sim, real Unitree G1 |

---

## Adding a New Solution

The framework is designed to make integration straightforward:

1. **New retargeter** — add as submodule in `modules/01_retargeting/`, write an adapter in `src/motion_convertor/` that converts its I/O to/from unified format
2. **New trainer** — add as submodule in `modules/02_training/`, write an adapter in `src/motion_convertor/to_trainer_input/`
3. **New dataset** — add download instructions in `data/00_raw_datasets/README.md`, write a prep converter in `src/motion_convertor/`
4. **New inference engine** — add as submodule in `modules/03_inference/`, plug into `scripts/infer.py`

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
│   │   └── holosoma_retargeting.yaml
│   ├── training/
│   │   └── holosoma.yaml
│   └── inference/
│       └── holosoma_inference.yaml
│
├── scripts/                   → see scripts/README.md
│   ├── retarget.py
│   ├── train.py
│   ├── infer.py
│   └── wrappers/              # thin scripts that run inside module envs (e.g. gmr_fk.py)
│
├── src/
│   └── motion_convertor/      → see src/motion_convertor/README.md
│
└── modules/
    ├── 01_retargeting/
    │   ├── GMR/                      # submodule — YanjieZe/GMR
    │   └── holosoma_retargeting      # symlink → third_party/holosoma
    ├── 02_training/
    │   └── holosoma                  # symlink → third_party/holosoma
    ├── 03_inference/
    │   └── holosoma_inference        # symlink → third_party/holosoma
    └── third_party/
        └── holosoma/                 # submodule — amazon-far/holosoma
```

---

## Installation

### 1 — Clone with submodules
```bash
git clone --recurse-submodules <repo-url>
# or after cloning:
git submodule update --init --recursive
```

### 2 — Willow WBT env (adapter layer + scripts)
```bash
conda create -n willow_wbt python=3.10
conda activate willow_wbt
pip install -e .
```

### 3 — External module envs (one-time, manual)
Each module has its own conda env. Follow the install instructions linked in the corresponding `cfg/` yaml:

| Module | yaml | Default env |
|--------|------|-------------|
| GMR | `cfg/retargeting/gmr.yaml` | `gmr` |
| holosoma retargeting | `cfg/retargeting/holosoma_retargeting.yaml` | `hsretargeting` |
| holosoma training (IsaacGym) | `cfg/training/holosoma.yaml` | `hsgym` |
| holosoma training (IsaacSim) | `cfg/training/holosoma.yaml` | `hssim` |
| holosoma training (MJWarp) | `cfg/training/holosoma.yaml` | `hsmujoco` |
| holosoma inference | `cfg/inference/holosoma_inference.yaml` | `hsinference` |
| InterAct (OMOMO processing) | `cfg/processing/interact.yaml` | `interact` |

### 4 — Configure data paths
Edit `cfg/data.yaml` to point to your local dataset and body model locations (defaults assume standard layout under `data/00_raw_datasets/`).
