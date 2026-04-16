# motion_convertor — Implementation TODO

This document is a complete implementation guide for `src/motion_convertor/`. It is self-contained: an implementer should be able to build the full tool from this file alone, using the referenced specs for format details.

---

## Context

`motion_convertor` is a **passive adapter library**. It is never run standalone — it is imported and called by `scripts/retarget.py` and `scripts/train.py`. It does not invoke retargeters or trainers.

The tool exposes **3 functions with distinct responsibilities**, called at different points by different scripts:

| Function | Called by | When | Reads | Writes |
|----------|-----------|------|-------|--------|
| `to_retargeter_input()` | `scripts/retarget.py` | before retargeter | raw dataset | `{seq}_input_raw.{ext}` |
| `to_unified_input()` | `scripts/retarget.py` | before retargeter | raw dataset | `{seq}_input_unified.npz` |
| `to_unified_output()` | `scripts/retarget.py` | after retargeter | `output_raw` | `{seq}_output_unified.npz` |
| `to_trainer_input()` | `scripts/train.py` | on demand | `output_raw` | `{seq}_trainer_input.npz` |

`to_retargeter_input` and `to_unified_input` are independent — both read raw data, neither depends on the other.  
`to_unified_output` and `to_trainer_input` both read `output_raw`, independently.  
`to_trainer_input` is never called automatically during retargeting — only when training is explicitly requested.  
This keeps the retargeting backlog clean and complete on its own.

### Execution model per bridge

| Bridge | Execution | Env |
|--------|-----------|-----|
| `to_unified_input/lafan.py` | Python direct | `willow_wbt` |
| `to_unified_input/sfu.py` | Python direct | `willow_wbt` |
| `to_unified_input/omomo.py` | Python direct | `willow_wbt` |
| `to_retargeter_input/lafan_gmr.py` | no-op | — |
| `to_retargeter_input/sfu_gmr.py` | no-op | — |
| `to_retargeter_input/omomo_gmr.py` | Python direct (reformat keys) | `willow_wbt` |
| `to_retargeter_input/lafan_holosoma.py` | Python direct (bvhio) | `willow_wbt` |
| `to_retargeter_input/sfu_holosoma.py` | reuse `to_unified_input/sfu.py` | `willow_wbt` |
| `to_retargeter_input/omomo_holosoma.py` | **subprocess ×2** | `interact` |
| `to_unified_output/gmr.py` | **subprocess** (gmr_fk.py) | `gmr` |
| `to_unified_output/holosoma.py` | Python direct | `willow_wbt` |
| `to_trainer_input/holosoma_holosoma.py` | no-op | — |
| `to_trainer_input/gmr_holosoma.py` | **subprocess** (gmr_fk.py) | `gmr` |

**Reference specs** (read these before implementing):
- `specs/raw_datasets/LAFAN.md`, `SFU.md`, `OMOMO.md`
- `specs/retargeting/GMR.md`, `holosoma_retargeting.md`
- `specs/training/holosoma.md`
- `specs/robots/G1.md`
- `src/motion_convertor/README.md`

---

## File architecture

```
src/motion_convertor/
├── __init__.py                         # public API — 4 dispatch functions
├── _config.py                          # loads cfg/data.yaml, exposes dataset_path() / body_model_path()
├── _subprocess.py                      # helper: conda run subprocess call, reads cfg/ yamls
├── unified.py                          # unified format save/load helpers
│
├── to_unified_input/                   # Role 1a — raw dataset → unified npz (FK only, no retargeter logic)
│   ├── __init__.py
│   ├── lafan.py                        # BVH FK → (T,22,3) Z-up + height=1.75
│   ├── sfu.py                          # SMPL-X FK → (T,22,3) Z-up + height from betas, 120→30 Hz
│   └── omomo.py                        # SMPL-H FK → (T,22,3) Z-up + height + object_poses (T,7)
│
├── to_retargeter_input/                # Role 1b — raw dataset → retargeter native input
│   ├── __init__.py
│   ├── lafan_gmr.py                    # .bvh passthrough (no-op)
│   ├── lafan_holosoma.py               # BVH FK → .npy (T,23,3) Y-up
│   ├── sfu_gmr.py                      # .npz passthrough (no-op)
│   ├── sfu_holosoma.py                 # SMPL-X FK → unified .npz (same as to_unified_input/sfu.py)
│   ├── omomo_gmr.py                    # SMPL-H pickle → SMPL-X .npz  ⚠️ Gap 1
│   └── omomo_holosoma.py               # SMPL-H FK → unified .npz (same as to_unified_input/omomo.py)
│
├── to_unified_output/                  # Role 2 — retargeter native output → unified npz
│   ├── __init__.py
│   ├── gmr.py                          # .pkl xyzw → (T,22,3) via robot FK  ⚠️ Gap 3
│   └── holosoma.py                     # .npz body_pos_w → (T,22,3) body subset mapping
│
├── to_trainer_input/                   # Role 3 — retargeter native output → trainer input
│   ├── __init__.py
│   ├── gmr_holosoma.py                 # .pkl → form B .npz via robot FK + 30→50 Hz  ⚠️ Gap 3
│   └── holosoma_holosoma.py            # no-op (raw output is already form B)
│
└── third_party/                        # git submodules (already present)
    ├── InterAct/
    └── InterMimic/
```

---

## Unified format (contract)

All `*_unified.npz` files must follow this exact schema:

```python
np.savez(path,
    global_joint_positions=arr,   # (T, 22, 3) float32, Z-up, world frame, metres
    height=float,                  # subject height in metres
    object_poses=arr,              # (T, 7) float32 [qw,qx,qy,qz,x,y,z] — OPTIONAL
)
```

22 joints = SMPL-X body convention (see `specs/raw_datasets/SFU.md` for the full joint list).
Quaternions: **wxyz** throughout the unified format.

Implement in `unified.py`:
```python
def save_unified(path, global_joint_positions, height, object_poses=None): ...
def load_unified(path) -> dict: ...
```

---

## Module 1 — `to_unified_input/lafan.py`

**Inputs available**: `.bvh` files in `data/00_raw_datasets/LAFAN/lafan1/`
**Format reference**: `specs/raw_datasets/LAFAN.md`

BVH structure: root has 6 channels (3 translation cm + 3 rotation ZYX degrees), all other joints have 3 rotation channels. Parse with `bvhio` or implement a minimal BVH parser. Library recommendation: `bvhio` (already used by holosoma) or `ezc3d`.

### `convert(bvh_path, out_path)` — unified input only
- **Output**: unified `.npz`, `global_joint_positions (T, 22, 3)` Z-up, `height=1.75`
- Steps:
  1. Parse BVH: read HIERARCHY (joint offsets + channel order) and MOTION sections
  2. For each frame, compute **global** joint positions via FK on the skeleton tree
  3. Convert positions from centimeters → metres (divide by 100)
  4. Apply Y-up → Z-up rotation: `R = [[1,0,0],[0,0,-1],[0,1,0]]`, apply to all positions
  5. Reorder LAFAN 22 joints → SMPL-X 22 joints (permutation only, no joints dropped):
     `_LAFAN_TO_SMPLX = [0,1,5,9,2,6,10,3,7,11,4,8,12,14,18,13,15,19,16,20,17,21]`
     LeftToe→L_Foot, RightToe→R_Foot (kept, not dropped)
  6. `height = 1.75` (hardcoded, LAFAN has no height field)
- Save with `save_unified(out_path, positions, 1.75)`

---

## Module 2 — `to_retargeter_input/lafan_gmr.py`

- **No-op** — GMR reads `.bvh` natively. Copy or symlink source file → `{seq}_input_raw.bvh`

---

## Module 3 — `to_retargeter_input/lafan_holosoma.py`

- **Output**: `.npy (T, 23, 3)`, float32, **Y-up**, metres
- Steps:
  1. Same BVH FK as `to_unified_input/lafan.py` — reuse the parser
  2. Convert cm → metres
  3. Keep **Y-up** — holosoma applies Y→Z internally
  4. Joint order: LAFAN 23-joint order (index 0 = Hips, ..., index 22 = RightHand)
- Save with `np.save(out_path, arr)`

---

## Module 4 — `to_unified_input/sfu.py`

**Inputs available**: `.npz` files in `data/00_raw_datasets/SFU/SFU/{subject_id}/`
**Body model**: SMPL-X at `data/00_raw_datasets/SFU/models_smplx_v1_1/`
**Format reference**: `specs/raw_datasets/SFU.md`

Use `smplx` python package for forward kinematics. Install: `pip install smplx`.

```python
import smplx
model = smplx.create(model_path, model_type='smplx', gender=gender, num_betas=16)
output = model(betas=betas, body_pose=pose_body, global_orient=root_orient, transl=trans)
joints = output.joints[:, :22, :]  # (T, 22, 3) — first 22 = body joints
```

### `convert(npz_path, out_path)`
- **Output**: unified `.npz`, `global_joint_positions (T, 22, 3)` Z-up 30 Hz, `height`
- Steps:
  1. Load npz: `pose_body (T,63)`, `root_orient (T,3)`, `trans (T,3)`, `betas (16,)`, `gender`, `mocap_frame_rate`
  2. Downsample 120 Hz → 30 Hz: keep every 4th frame (`arr[::4]`)
  3. Run SMPL-X FK (batched over T frames) → joint positions `(T, 22, 3)`, already Z-up
  4. Compute height: run FK on T-pose (zero pose, `betas` only) → `height = max joint z-coordinate`
- Save with `save_unified(out_path, joints, height)`

---

## Module 5 — `to_retargeter_input/sfu_gmr.py`

- **No-op** — GMR reads SFU `.npz` natively (keys already match). Copy → `{seq}_input_raw.npz`

---

## Module 6 — `to_retargeter_input/sfu_holosoma.py`

- **Same as `to_unified_input/sfu.py`** — unified format is the holosoma retargeter input
- Import and call `to_unified_input.sfu.convert()`

---

## Module 7 — `to_unified_input/omomo.py`

**Inputs available**: `.p` pickle files in `data/00_raw_datasets/OMOMO/data/`
**Body model**: SMPL-H at `data/00_raw_datasets/OMOMO/smplh/`
**Format reference**: `specs/raw_datasets/OMOMO.md`

OMOMO pickle is a dict keyed by sequence index. Each entry:
```python
{
    'seq_name': str,            # e.g. "sub3_largebox_003"
    'root_orient': (T, 3),     # root axis-angle
    'pose_body': (T, 63),      # body pose axis-angle (21 joints × 3)
    'trans': (T, 3),           # root translation, metres
    'betas': (1, 16),          # shape params — use betas[0] to get (16,)
    'gender': str,
    'obj_rot': (T, 3, 3),      # object rotation matrix (NOT axis-angle)
    'obj_trans': (T, 3, 1),    # object translation — use obj_trans[:, :, 0]
    'obj_scale': (T, 1),
    'obj_com_pos': (T, 3),
    'trans2joint': (3,),
    'rest_offsets': (J, 3),
}
```
30 Hz. No `motion` key in raw data — global joint positions require FK via `smplx`/`human_body_prior`.

### `convert(seq_data, out_path)`
- **Output**: unified `.npz` with `global_joint_positions (T, 22, 3)`, `height`, `object_poses (T, 7)`
- Steps:
  1. Run SMPL-H FK using `human_body_prior.BodyModel` with `root_orient`, `pose_body`, `trans`, `betas[0]`
     → `joints (T, 52, 3)` — take first 24 (SMPL-H joints24 subset)
  2. Drop joint 22 (`L_Hand`) and joint 23 (`R_Hand`) → `(T, 22, 3)` global positions, already Z-up
  3. Convert object rotation matrix → quaternion wxyz:
     ```python
     from scipy.spatial.transform import Rotation
     quat_xyzw = Rotation.from_matrix(seq_data['obj_rot']).as_quat()  # (T,4) xyzw
     quat_wxyz = quat_xyzw[:, [3,0,1,2]]                               # (T,4) wxyz
     ```
  4. Get object translation: `obj_trans = seq_data['obj_trans'][:, :, 0]`  # (T,3)
  5. Build `object_poses (T,7)` = `np.hstack([quat_wxyz, obj_trans])`
  6. Compute `height`: run FK on T-pose (zero pose, `betas[0]` only) → max joint z-coordinate
- Save with `save_unified(out_path, joints_22, height, object_poses)`

---

## Module 8 — `to_retargeter_input/omomo_gmr.py`

⚠️ **Gap 1** — see Known spec gaps section below.

---

## Module 9 — `to_retargeter_input/omomo_holosoma.py`

- **Same as `to_unified_input/omomo.py`** — unified format is the holosoma retargeter input
- Import and call `to_unified_input.omomo.convert()`

---

### `convert(seq_data, out_path)` — back in `to_unified_input/omomo.py`
- **Output**: unified `.npz` with `global_joint_positions (T, 22, 3)`, `height`, `object_poses (T, 7)`
- Steps:
  1. `motion (T,24,3)` is already global joint positions, Z-up, metres — use directly
  2. Drop joint 22 (`L_Hand`) and joint 23 (`R_Hand`) → `(T, 22, 3)`
  3. Convert `object_orient (T,3)` axis-angle → quaternion wxyz:
     ```python
     from scipy.spatial.transform import Rotation
     quat_xyzw = Rotation.from_rotvec(object_orient).as_quat()  # (T,4) xyzw
     quat_wxyz = quat_xyzw[:, [3,0,1,2]]                         # (T,4) wxyz
     ```
  4. Build `object_poses (T,7)` = `[qw,qx,qy,qz, x,y,z]` = `np.hstack([quat_wxyz, object_trans])`
  5. `height` is directly available in the pickle as `seq_data['height']`
- Save with `save_unified(out_path, joints_22, height, object_poses)`

---

## Module 10 — `to_unified_output/gmr.py`

**Format reference**: `specs/retargeting/GMR.md`

### `convert(pkl_path, robot_urdf_path, out_path, height)`
- **Input**: GMR output `.pkl` with keys `fps`, `root_pos (T,3)`, `root_rot (T,4)` xyzw, `dof_pos (T,N)`
- **Output**: unified `.npz` with `global_joint_positions (T,22,3)`
- Steps:
  1. Load pickle
  2. Convert root quaternion xyzw → wxyz: `q_wxyz = q[[3,0,1,2]]`
  3. ⚠️ **SPEC GAP**: GMR output has no body positions — only `root_pos + dof_pos`. Need to run robot FK:
     - Load robot URDF (path: `modules/01_retargeting/GMR/assets/{robot}/`)
     - Use `mujoco` or `pinocchio` to compute forward kinematics
     - Extract the 22 body positions that correspond to SMPL-X joints
     - The joint subset mapping (robot links → SMPL-X 22 joints) needs to be established
  4. `height`: carry over from `input_unified.npz` (passed as argument or loaded from same run folder)
- Save with `save_unified(out_path, body_positions, height)`

---

## Module 11 — `to_unified_output/holosoma.py`

**Format reference**: `specs/retargeting/holosoma_retargeting.md`

### `convert(npz_path, out_path, height)`
- **Input**: holosoma output `.npz` with `body_pos_w (T,B,3)`, `body_quat_w (T,B,4)` wxyz, `joint_pos (T,N)`, `body_names`
- **Output**: unified `.npz`
- Steps:
  1. Load npz
  2. Map `body_names` list → indices of the 22 SMPL-X joints
     - The 14 tracked bodies (see `specs/training/holosoma.md`) are a subset — for unified format need all 22
     - Use `body_pos_w` indexed by the body names that correspond to SMPL-X joints
  3. Build `global_joint_positions (T,22,3)` from the selected body positions
  4. For object_interaction: read `object_pos_w (T,3)` and `object_quat_w (T,4)` wxyz → build `object_poses (T,7)` = `[qw,qx,qy,qz,x,y,z]`
- Save with `save_unified(out_path, positions, height, object_poses)`

---

## Module 12 — `to_trainer_input/holosoma_holosoma.py`

**Format reference**: `specs/training/holosoma.md`

### `convert(output_raw_path, out_path, robot, input_fps, output_fps)`
- **Input**: holosoma retargeter output `.npz` containing `qpos (T, 36)` at 30 Hz (form A)
- **Output**: form B `.npz` at 50 Hz via holosoma native MuJoCo bridge
- Delegates to `scripts/wrappers/holosoma_convert.py` running in `hsretargeting` env
- The wrapper calls `convert_data_format_mj.py --once` which runs a headless MuJoCo
  simulation to extract `body_pos_w`, `body_quat_w`, velocities, etc.
- Pattern is identical to `gmr_holosoma.py` → `gmr_fk.py` in `gmr` env

## Module 13 — `to_trainer_input/gmr_holosoma.py`

### `convert(output_raw_path, robot_urdf_path, out_path)`
- **Input**: GMR raw output `.pkl` — `root_pos (T,3)`, `root_rot (T,4)` xyzw, `dof_pos (T,N)` at 30 Hz
- **Output**: holosoma form B `.npz` at 50 Hz
- ⚠️ **SPEC GAP**: same FK gap as `to_unified_output_gmr` — need robot FK to get `body_pos_w`
- Steps (once FK gap is resolved):
  1. Load pkl, convert root_rot xyzw → wxyz
  2. Run robot FK in MuJoCo on each frame → get `body_pos_w (T,B,3)`, `body_quat_w (T,B,4)`
  3. Compute `joint_vel` via finite differences on `dof_pos`
  4. Compute `body_lin_vel_w`, `body_ang_vel_w` via finite differences
  5. Interpolate all arrays from 30 Hz → 50 Hz (SLERP for quaternions, LERP for positions/scalars)
  6. Save `.npz` with all form B keys: `fps=50`, `joint_pos`, `joint_vel`, `body_pos_w`, `body_quat_w`, `body_lin_vel_w`, `body_ang_vel_w`, `joint_names`, `body_names`

---

## Public API (`__init__.py`)

Four flat functions — no grouping, no wrappers. Each has a single responsibility.

```python
def to_retargeter_input(dataset: str, retargeter: str, raw_path: Path, out_path: Path, **kwargs):
    """
    Role 1 — raw dataset → retargeter native input.
    Called by scripts/retarget.py before invoking the retargeter.
    kwargs: robot (str)
    """

def to_unified_input(dataset: str, raw_path: Path, out_path: Path, **kwargs):
    """
    Role 1 — raw dataset → unified input npz.
    Called by scripts/retarget.py before invoking the retargeter.
    Independent from to_retargeter_input.
    kwargs: body_model_path (Path)
    """

def to_unified_output(retargeter: str, output_raw_path: Path, out_path: Path, height: float, **kwargs):
    """
    Role 2 — retargeter native output → unified output npz.
    Called by scripts/retarget.py after the retargeter has run.
    kwargs: robot_urdf_path (Path)
    """

def to_trainer_input(retargeter: str, trainer: str, output_raw_path: Path, out_path: Path, **kwargs):
    """
    Role 3 — retargeter native output → trainer-native input npz.
    Called by scripts/train.py, independently of the retargeting step.
    Reads output_raw directly — never reads unified output.
    kwargs: robot_urdf_path (Path)
    """
```

Each function dispatches internally to the correct `datasets/` or `retargeters/` or `trainers/` module based on the `dataset`, `retargeter`, `trainer` string arguments.

---

## Resolved spec gaps

All 3 gaps are now resolved. Implementation details below.

### Gap 1 resolved — OMOMO → GMR ✅ simple reformat

The OMOMO raw pickle contains axis-angle params directly:
- `root_orient (T,3)`, `pose_body (T,63)`, `trans (T,3)`, `betas (1,16)`, `gender`

This is what GMR expects as SMPL-X `.npz` input. Implementation in `to_retargeter_input/omomo_gmr.py`:
1. Load `.p` with `joblib.load()`
2. Iterate over sequence index keys
3. Extract per-sequence: `root_orient`, `pose_body`, `trans`, `betas[0]` (squeeze `(1,16)→(16,)`), `gender`
4. Add `mocap_frame_rate=30.0`, zero-fill `pose_hand`, `pose_jaw`, `pose_eye`
5. Save as `.npz` → `{seq}_input_raw.npz`

---

### Gap 2 resolved — OMOMO → holosoma object_interaction ⚠️ 2-step subprocess chain

holosoma expects `.pt` PyTorch tensors of shape `(T, 331)` produced by InterAct.
The chain is **fully implemented in InterAct** — we only need to call it via subprocess (env: `interact`).

**Step 1** — `InterAct/process/process_omomo.py`
- Input: raw OMOMO `.p` files
- Output: `sequences_canonical/{seq}/human.npz` + `object.npz`
- ⚠️ **HARDCODED PATHS** — `process_omomo.py` has NO CLI arguments. All paths are hardcoded relative to the script's cwd:
  - `MOTION_PATH_RAW = './data/omomo/raw/train_diffusion_manip_seq_joints24.p'`
  - `SMPLH_PATH = './models/smplh'`
  - `SMPLX_PATH = './models/smplx'`
  - `MOTION_PATH = './data/omomo/sequences'`
  - `OBJECT_PATH = './data/omomo/objects'`
- **Required directory structure** relative to subprocess cwd:
  ```
  {cwd}/
  ├── data/omomo/raw/
  │   ├── train_diffusion_manip_seq_joints24.p
  │   └── test_diffusion_manip_seq_joints24.p
  ├── data/omomo/objects/  (populated by script from raw)
  ├── models/smplh/        (male/female/neutral model.npz)
  └── models/smplx/        (SMPLX_MALE.npz, SMPLX_FEMALE.npz, SMPLX_NEUTRAL.npz)
  ```
- **Implementation strategy**: create symlinks in a temp staging dir OR run with `cwd=src/motion_convertor/third_party/InterAct` and rely on the user having set up the expected directory structure.
  Recommended: **add a one-time setup helper** that creates the expected dir layout with symlinks pointing to the actual dataset and body model paths from `cfg/data.yaml`.
- `human.npz` keys: `poses (T,156)`, `betas (16,)`, `trans (T,3)`, `gender`
- `object.npz` keys: `angles (T,3)` axis-angle, `trans (T,3)` relative to pelvis, `name`

**Step 2** — `InterAct/simulation/interact2mimic.py --dataset_name omomo`
- Input: `../data/{dataset_name}/sequences_canonical` (relative to script cwd)
- Output: `intermimic/InterAct/{dataset_name}/{seq}.pt` per sequence
- ⚠️ **HARDCODED PATHS** — `interact2mimic.py` only accepts `--dataset_name`. Paths are:
  - `MOTION_PATH = f"../data/{dataset_name}/sequences_canonical"` — one level up from cwd
  - `MODEL_PATH = "../models"` — also relative
  - Output: `intermimic/InterAct/{dataset_name_full}/{name}.pt` relative to cwd
- **Required cwd**: `src/motion_convertor/third_party/InterAct/simulation/`
  (so `../data/omomo/sequences_canonical` resolves to `InterAct/data/omomo/sequences_canonical`)
- `.pt` tensor `(T, 331)` per sequence
- Key indices used by holosoma:
  - `[162:318]` → 52 SMPL-H joint positions `(T, 52, 3)` flattened
  - `[318:325]` → object pose `[tx, ty, tz, qx, qy, qz, qw]`

Both steps run in `env: interact` (see `cfg/processing/interact.yaml`).
Implementation in `to_retargeter_input/omomo_holosoma.py`: orchestrate the 2 subprocess calls with correct `cwd` settings, copy output `.pt` → `{seq}_input_raw.pt`.

---

### Gap 3 resolved — GMR output → unified / trainer input ✅ FK available in GMR

GMR has `general_motion_retargeting/kinematics_model.py` with `KinematicsModel.forward_kinematics(root_pos, root_rot, dof_pos)` → returns `body_pos (T, num_joints, 3)`.

**Approach**: write a thin wrapper script in `cfg/processing/` that runs in `env: gmr`, calls `KinematicsModel.fk()`, and saves the result. `motion_convertor` calls it via subprocess.

**Robot XML**: `modules/01_retargeting/GMR/assets/unitree_g1/g1_mocap_29dof.xml`

**Body link → SMPL-X 22-joint mapping** (from holosoma `config_types/data_type.py`):
```python
{
    "Pelvis":      "pelvis_contour_link",
    "L_Hip":       "left_hip_pitch_link",
    "R_Hip":       "right_hip_pitch_link",
    "L_Knee":      "left_knee_link",
    "R_Knee":      "right_knee_link",
    "L_Ankle":     "left_ankle_intermediate_1_link",
    "R_Ankle":     "right_ankle_intermediate_1_link",
    "L_Foot":      "left_ankle_roll_sphere_5_link",
    "R_Foot":      "right_ankle_roll_sphere_5_link",
    "L_Shoulder":  "left_shoulder_roll_link",
    "R_Shoulder":  "right_shoulder_roll_link",
    "L_Elbow":     "left_elbow_link",
    "R_Elbow":     "right_elbow_link",
    "L_Wrist":     "left_rubber_hand_link",
    "R_Wrist":     "right_rubber_hand_link",
}
```
Note: only 15 of the 22 SMPL-X joints have a robot body counterpart. The 7 spine/neck/head joints (`Spine1`, `Spine2`, `Spine3`, `Neck`, `Head`, `L_Collar`, `R_Collar`) have no direct equivalent — set to the nearest parent link position or interpolate.

Implementation: add `scripts/gmr_fk.py` (runs in `env: gmr`) called via subprocess from `to_unified_output/gmr.py` and `to_trainer_input/gmr_holosoma.py`.

---

## Dependencies

Declared in `pyproject.toml` at the repo root under the `willow_wbt` package.

| Package | Used for |
|---------|---------|
| `numpy` | All array operations |
| `scipy` | `Rotation.from_matrix()` / `from_rotvec()` for object rotation conversions |
| `smplx` | SFU forward kinematics |
| `human_body_prior` | OMOMO forward kinematics (SMPL-H `BodyModel`) — install from InterAct repo |
| `mujoco` | Robot FK for GMR output (G1 XML) |
| `bvhio` | BVH parsing for LAFAN (covers FK + global positions) |
| `pyyaml` | Reading `cfg/data.yaml` for dataset paths |
| `torch` | Loading `.pt` files (InterAct/InterMimic outputs) |
| `joblib` | Loading OMOMO `.p` pickle files |

Body models must be present locally (not in the repo). Paths are resolved via `cfg/data.yaml`:
- SMPL-X: `cfg/data.yaml` → `raw_datasets.SFU.body_model`
- SMPL-H: `cfg/data.yaml` → `raw_datasets.OMOMO.body_model`

## Config loading

`motion_convertor` reads `cfg/data.yaml` to resolve all dataset and body model paths. The yaml is loaded once at import time from the repo root:

```python
# src/motion_convertor/_config.py
import yaml
from pathlib import Path

_REPO_ROOT = Path(__file__).parents[2]
_cfg = yaml.safe_load((_REPO_ROOT / "cfg" / "data.yaml").read_text())

def dataset_path(dataset: str) -> Path:
    return _REPO_ROOT / _cfg["raw_datasets"][dataset]["path"]

def body_model_path(dataset: str) -> Path:
    return _REPO_ROOT / _cfg["raw_datasets"][dataset]["body_model"]
```

---

## Implementation order (suggested)

1. `unified.py` — save/load helpers (no deps, needed by everything)
2. `to_unified_input/sfu.py` — simplest FK case, validates the SMPL-X pipeline
3. `to_retargeter_input/sfu_gmr.py` — trivial passthrough, validates the plumbing
4. `to_retargeter_input/sfu_holosoma.py` — reuses sfu.py, validates the reuse pattern
5. `to_unified_output/holosoma.py` — validates the output side
6. `to_trainer_input/holosoma_holosoma.py` — trivial copy, completes the holosoma↔holosoma chain
7. `to_unified_input/lafan.py` — BVH FK, no body model needed
8. `to_retargeter_input/lafan_gmr.py` — trivial passthrough
9. `to_retargeter_input/lafan_holosoma.py` — reuses lafan.py FK, keep Y-up
10. `to_unified_input/omomo.py` — SMPL-H FK + object pose handling
11. `to_retargeter_input/omomo_holosoma.py` — reuses omomo.py
12. `__init__.py` — wire up the 4 dispatch functions
13. Resolve Gap 1/2/3, then implement `omomo_gmr.py`, `to_unified_output/gmr.py`, `to_trainer_input/gmr_holosoma.py`
