# Scripts

Pipeline entry points. Each script orchestrates one stage:
- imports `src/motion_convertor/` directly (same `willow_wbt` conda env)
- calls external modules via **subprocess** in their own conda env, described in `cfg/`
- never modifies submodule code

---

## Execution model

```
scripts/retarget.py        (runs in: willow_wbt env)
        │
        ├── import motion_convertor     (same process, same env)
        │
        └── subprocess.run(             (child process, module's own env)
                conda run -n {env}
                python {cmd} {args}     (read from cfg/retargeting/{retargeter}.yaml)
            )
```

The conda env name, command, and argument mapping for each module are declared in `cfg/`. Scripts read the relevant yaml at runtime — adding or swapping a module requires no script changes.

---

## retarget.py

Runs a full retargeting job for one (dataset, robot, retargeter) combination.

**CLI:**
```bash
python scripts/retarget.py \
    --dataset LAFAN \
    --robot G1 \
    --retargeter GMR \
    [--sequences seq1 seq2 ...]   # optional, defaults to all sequences
    [--run-id run_20240301_120000] # optional, resumes an existing run
```

**What it does, in order:**
1. Reads `cfg/data.yaml` → resolves raw dataset path
2. Reads `cfg/retargeting/{retargeter}.yaml` → resolves env, cmd, args
3. For each sequence:
   a. `motion_convertor.to_retargeter_input()` → `{seq}_input_raw.{ext}`
   b. `motion_convertor.to_unified_input()` → `{seq}_input_unified.npz`
   c. `subprocess` (module env) → runs retargeter → `{seq}_output_raw.{ext}`
   d. `motion_convertor.to_unified_output()` → `{seq}_output_unified.npz`
4. Writes `config.yaml` (full CLI args + yaml snapshot)
5. Updates `latest →` symlink

**Output** — `data/01_retargeted_motions/{dataset}_{robot}/{retargeter}/run_{timestamp}/`:
```
{seq}_input_raw.{ext}
{seq}_input_unified.npz
{seq}_output_raw.{ext}
{seq}_output_unified.npz
config.yaml
```

**Supported combinations:**

| Dataset | GMR | holosoma_retargeting |
|---------|-----|---------------------|
| LAFAN | ✅ | ✅ |
| SFU | ✅ | ✅ |
| OMOMO robot_only | ✅ | ✅ |
| OMOMO object_interaction | ❌ | ✅ |

---

## train.py

Prepares trainer input and launches training from an existing retargeting run.

**CLI:**
```bash
python scripts/train.py \
    --dataset LAFAN \
    --robot G1 \
    --retargeter GMR \
    --trainer holosoma \
    --simulator mjwarp \            # isaacgym | isaacsim | mjwarp
    [--retarget-run latest]         # which retargeting run to use (default: latest)
    [--num-envs 4096]
```

**What it does, in order:**
1. Reads `cfg/data.yaml` and `cfg/training/{trainer}.yaml`
2. Locates retargeting run: `data/01_retargeted_motions/{dataset}_{robot}/{retargeter}/{retarget-run}/`
3. For each sequence:
   - `motion_convertor.to_trainer_input()` → `{seq}_trainer_input.npz` (written into existing retarget run folder)
4. `subprocess` (trainer env, selected by `--simulator`) → runs training
5. Saves to `data/02_policies/{dataset}_{robot}/{retargeter}_{trainer}/run_{timestamp}/`:
   - `checkpoint.pt`
   - `policy.onnx`
   - `config.yaml`
6. Updates `latest →` symlink

---

## infer.py

Runs a trained policy in simulation or on a real robot.

**CLI:**
```bash
# sim
python scripts/infer.py \
    --dataset LAFAN \
    --robot G1 \
    --retargeter GMR \
    --trainer holosoma \
    --mode sim \
    [--policy-run latest]

# real robot
python scripts/infer.py \
    --dataset LAFAN \
    --robot G1 \
    --retargeter GMR \
    --trainer holosoma \
    --mode real \
    [--policy-run latest]
```

**What it does:**
1. Reads `cfg/inference/{engine}.yaml`
2. Locates policy: `data/02_policies/{dataset}_{robot}/{retargeter}_{trainer}/{policy-run}/policy.onnx`
3. `subprocess` (inference env) → runs inference engine
