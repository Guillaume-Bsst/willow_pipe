# OMOMO — Format Specification

## Overview

| Property | Value |
|----------|-------|
| File format | `.p` (Python pickle) |
| Coordinate system | Z-up, right-handed |
| Units | meters |
| Body model | SMPL-H (22 body joints + 15 per hand = 52 total) |
| Body joints used | 24 (SMPL-H body subset, `joints24`) |
| Task types | `robot_only` (no object), `object_interaction` |

---

## Main Pickle Files

| File | Size | Content |
|------|------|---------|
| `train_diffusion_manip_seq_joints24.p` | ~1.9 GB | Full training sequences |
| `train_diffusion_manip_window_120_cano_joints24.p` | ~1.9 GB | Sliding windows of 120 frames, canonicalized |
| `test_diffusion_manip_seq_joints24.p` | ~61 MB | Full test sequences |
| `test_diffusion_manip_window_120_processed_joints24.p` | ~101 MB | Processed test windows |
| `min_max_mean_std_data_window_120_cano_joints24.p` | small | Normalization statistics |

---

## Pickle Data Structure

Each pickle file contains a dict keyed by sequence index. Key structure per sequence entry:

| Key | Shape | Description |
|-----|-------|-------------|
| `seq_name` | string | Sequence ID, e.g. `"sub3_largebox_003"` |
| `root_orient` | `(T, 3)` | Root joint orientation, axis-angle |
| `pose_body` | `(T, 63)` | Body pose parameters, 21 joints × 3 (axis-angle) |
| `trans` | `(T, 3)` | Root joint translation, metres |
| `betas` | `(1, 16)` | SMPL-H shape parameters — **use `betas[0]`** to get `(16,)` |
| `gender` | string | `"male"` / `"female"` / `"neutral"` |
| `obj_rot` | `(T, 3, 3)` | Object rotation as **rotation matrix** (NOT axis-angle) |
| `obj_trans` | `(T, 3, 1)` | Object translation — **use `obj_trans[:, :, 0]`** to get `(T, 3)` |
| `obj_scale` | `(T, 1)` | Object scale |
| `obj_com_pos` | `(T, 3)` | Object centre-of-mass position |
| `trans2joint` | `(3,)` | Translation offset from trans to pelvis joint |
| `rest_offsets` | `(J, 3)` | Rest-pose joint offsets |

> **Note**: There is no `motion (T,24,3)` key in the raw pickle. Global joint positions are computed via SMPL-H FK from `root_orient + pose_body + trans + betas`.

### Object pose convention
- Rotation stored as **rotation matrix** `(T, 3, 3)` → convert with `scipy.spatial.transform.Rotation.from_matrix()`
- Translation stored as `(T, 3, 1)` → reshape with `obj_trans[:, :, 0]`
- Unified format expects quaternion **wxyz** `[qw, qx, qy, qz, x, y, z]`

---

## SMPL-H Joints (24-joint subset, `joints24`)

| Index | Name |
|-------|------|
| 0 | Pelvis |
| 1 | L_Hip |
| 2 | R_Hip |
| 3 | Spine1 |
| 4 | L_Knee |
| 5 | R_Knee |
| 6 | Spine2 |
| 7 | L_Ankle |
| 8 | R_Ankle |
| 9 | Spine3 |
| 10 | L_Foot |
| 11 | R_Foot |
| 12 | Neck |
| 13 | L_Collar |
| 14 | R_Collar |
| 15 | Head |
| 16 | L_Shoulder |
| 17 | R_Shoulder |
| 18 | L_Elbow |
| 19 | R_Elbow |
| 20 | L_Wrist |
| 21 | R_Wrist |
| 22 | L_Hand |
| 23 | R_Hand |

> The unified format uses 22 joints (SMPL-X convention). Joints 22 and 23 (L_Hand, R_Hand) are dropped when converting to unified.

---

## Object Assets

Located in `captured_objects/`. Each object has:

```
captured_objects/
└── {object_name}/
    ├── {object_name}_cleaned_simplified.obj    # mesh (Wavefront OBJ)
    └── ...
```

17 objects: `clothesstand`, `floorlamp`, `largebox`, `largetable`, `monitor`, `mop`, `mop_bottom`, `mop_top`, `plasticbox`, `smallbox`, `smalltable`, `suitcase`, `trashcan`, `tripod`, `vacuum`, `vacuum_bottom`, `vacuum_top`, `whitechair`, `woodchair`

URDF and XML assets (`.urdf`, `.xml`) are **generated** from `.obj` files by `prep_omomo_for_rt.py` and stored in `01_retargeted_motions/assets/OMOMO/objects/`.

---

## Supplementary NPY Files

| Folder | Content |
|--------|---------|
| `object_bps_npy_files_joints24/` | Ball-pivot surface (BPS) object shape representations for training |
| `object_bps_npy_files_for_eval_joints24/` | BPS representations for evaluation |
| `rest_object_sdf_256_npy_files/` | Signed Distance Function (SDF) at 256³ resolution |

These are used by the diffusion model (InterMimic/InterAct), not directly by the retargeter.

---

## SMPL-H Body Model (`smplh/`)

Required for forward kinematics to get global joint positions:

```
smplh/
├── male/model.npz
├── female/model.npz
└── neutral/model.npz
```

Download: [mano.is.tue.mpg.de](https://mano.is.tue.mpg.de) → Extended SMPL+H model for AMASS (`smplh.tar.xz`)

---

## Sequence Naming Convention

Sequence IDs follow the pattern: `sub{subject_id}_{object_name}_{index:03d}`

Examples: `sub3_largebox_003`, `sub1_smallbox_012`
