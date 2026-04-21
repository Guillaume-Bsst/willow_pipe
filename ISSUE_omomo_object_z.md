# ISSUE: OMOMO → Holosoma object Z position 13 cm systematic error

**Symptom:** Generated `.pt` tensor has relative object Z (obj - pelvis) = **-0.9475**,
reference OMOMO_new gives **-0.8168**. Difference = **+0.1307 m (13 cm)**.

---

## Pipeline

```
OMOMO raw .p
    │
    ▼  process_omomo.py  (interact env, exec() in wrapper)
sequences/{seq}/human.npz + object.npz   ← Y-up, floor-fixed, yaw-aligned
    │
    ▼  canonicalize_human.py  (exec() in wrapper)
sequences_canonical/{seq}/human.npz + object.npz   ← further yaw-canonicalized + floor-fixed
    │
    ▼  interact2mimic.py  (exec() in wrapper)
sub3_largebox_003.pt
```

Wrapper: `scripts/wrappers/omomo_to_intermimic.py`  
Sequence tested: `sub3_largebox_003`

---

## What `interact2mimic.py` does (condensed, OMOMO path)

```python
# ~line 551
root_trans = smpl_data_entry['trans'].copy()           # canonical human.npz trans (Y-up)

# ~line 582
vertices, joints = forward_smpl(pose_aaa, beta, root_trans, gender, 'smplx', 16)
pelvis = joints[:, 0].detach().clone()                 # Y-up FK pelvis (SMPLX BodyModel)

# [... contact detection ...]

# ~line 706
obj_trans_delta = rotation_matrix_x.apply(obj_trans - pelvis.cpu().numpy())
# rotation_matrix_x = Rx(+90°) → converts Y-up → Z-up

# ~line 708
root_trans = rotation_matrix_x.apply(root_trans)       # root_trans now Z-up

# ~line 786
root_trans_offset = torch.from_numpy(root_trans) + skeleton_tree.local_translation[0]
new_sk_state = SkeletonState.from_rotation_and_root_translation(...)

# ~line 825
trans = new_sk_state.global_translation[:, 0, :]      # poselib pelvis position Z-up

# ~lines 846-850 (second FK pass + floor fix)
offset = joints[:30, 0] - trans[:30]
diff_fix = ((verts[:30] - offset[:,None])[:30,...,-1].min(dim=-1).values).min()
trans[..., -1] -= diff_fix

# ~line 860
obj_new_trans = trans + torch.from_numpy(obj_trans_delta).double()

# stored at data[:, 0:3] = trans, data[:, 318:321] = obj_new_trans
```

**Key math:**  
`obj_trans_delta_Z = Rx(+90°)(obj_Y - pelvis_Y)` = `obj_Y_yup - pelvis_Y_yup`  
After floor fix: `trans_Z ≈ pelvis_Y_yup` (confirmed by debug)  
Therefore: **relative_Z = obj_new_trans_Z - trans_Z = obj_Y_yup - pelvis_Y_yup** (canonical space)

---

## Debug output (run on `sub3_largebox_003`, frame 0)

```
[DBG] obj_trans[0]        = [ 0.02382690  0.07486112  0.50092345]   # Y-up canonical
[DBG] pelvis[0]           = [-3.57e-08    1.02237110 -6.89e-08  ]   # Y-up FK pelvis
[DBG] root_trans_before_Rx[0] = [-0.00167162  1.44670928 -0.02147561]  # Y-up canonical trans
[DBG] obj_minus_pelvis_Y  = -0.9475                                  # THE error
[DBG] obj_trans_delta[0]  = [ 0.02382694 -0.50092351 -0.94750993]

[DBG] trans_after_floorfix[0] = [-0.00167162  0.02147561  1.022371]  # Z-up poselib trans
[DBG] obj_new_trans[0]        = [ 0.02215532 -0.47944790  0.07486112]
[DBG] relative_Z_frame0   = -0.9475
```

---

## Key anomaly: 42 cm gap between `root_trans` and FK `pelvis`

In Y-up canonical space, frame 0:
- `root_trans_Y = 1.4467 m`  (canonical human.npz trans parameter)
- `pelvis_Y     = 1.0224 m`  (FK Jtr[0] from SMPLX BodyModel)
- **gap = 0.4243 m**

**This is expected, not a bug.** In SMPLX with 16 betas, the pelvis joint position =  
`trans + shape_offset(betas)`. For this subject, `shape_offset_Y ≈ -0.4243 m`.  
The gap is a legitimate property of the body model with these betas.

Trace of why `root_trans_Y = 1.4467`:
1. `canonicalize_human.py` centers pelvis at origin: `new_trans = trans - centroid` (centroid = FK pelvis)
2. After centering: canonical pelvis Y = 0, canonical trans Y = `0 - shape_offset_Y ≈ +0.4243`
3. Floor fix in canonicalize: min body vertex Y ≈ -1.0 (feet below centered pelvis)
4. `trans_Y += |diff_fix| ≈ 1.0`  →  `canonical trans_Y ≈ 0.4243 + 1.0 ≈ 1.4467` ✓  
5. `canonical pelvis_Y = canonical trans_Y + shape_offset_Y ≈ 1.4467 - 0.4243 ≈ 1.0224` ✓

---

## For reference to give -0.8168

Either (or combination):
- `obj_Y_canonical_ref = 0.2056` (object 13 cm higher in reference canonical), OR
- `pelvis_Y_canonical_ref = 0.8917` (pelvis 13 cm lower in reference canonical)

The discrepancy lives in the **canonical intermediate data** before interact2mimic runs.  
Within interact2mimic, the math is self-consistent.

---

## Solutions tried and their outcome

### Attempt 1: Inline reimplementation of `canonicalize_human.py` logic

Wrote `_canonicalize_sequence()` in the wrapper that reproduced the centroid subtraction,
yaw rotation, and floor fix manually.

**Result:** Both robot Z and object Z were "beaucoup trop hautes" (much too high).
Thrown away. The inline reimplementation was wrong or missed something.

### Attempt 2: exec()-based `_run_canonicalize_human`

Replaced the inline reimplementation with an exec() of the actual
`canonicalize_human.py` script with patched paths, matching how `_run_process_omomo`
and `_run_interact2mimic` work.

**Result:** Z values returned to reasonable range. Relative Z = -0.9475.  
Still 13 cm off from reference -0.8168.

### Attempt 3: Investigating whether `pelvis` vs `root_trans` in obj_trans_delta is the bug

Hypothesis: line 706 uses FK `pelvis` but the final `trans` comes from `root_trans` via
poselib, creating an inconsistency.

**Result (rejected by analysis):** After floor fix, `trans_Z ≈ pelvis_Y_yup` exactly (confirmed
numerically). The obj_trans_delta_Z = `obj_Y - pelvis_Y` and `trans_Z = pelvis_Y`, so the
formula is self-consistent. Swapping `pelvis` with `root_trans` would make things WORSE
(gap is 42 cm, much larger than 13 cm).

---

## Current wrapper state

The 4-step pipeline is fully wired in `main()`. Debug prints exist in `_run_interact2mimic`
for obj_trans_delta and trans (can be removed once issue resolved).

The critical replacement in `_run_canonicalize_human`:
```python
# filter inner loop to target sequence only (8-space indent matters)
script = script.replace(
    "        data_name = os.listdir(MOTION_PATH)\n",
    "        data_name = os.listdir(MOTION_PATH)\n"
    "        data_name = [n for n in data_name if n == {seq_name!r}]\n",
)
```

---

## Hypotheses to investigate (priority order)

### H1 — process_omomo intermediate data is different from reference ⭐⭐⭐

The reference OMOMO_new may have been generated with a DIFFERENT version of
`process_omomo.py`, or the `process_omomo.py` in InterAct was patched after the
reference was generated.

**How to test:**  
Inspect the intermediate `sequences/{seq}/object.npz` after our process_omomo run,
specifically `obj_trans[:5, 1]` (Y-up object height). Compare against what the reference
pipeline would need (reverse-engineer from reference .pt frame 0 values and the
canonicalize/interact2mimic math).

Add a debug dump to `_run_process_omomo` to print `sequences/sub3_largebox_003/object.npz`
`trans[:3, 1]` and `human.npz` `trans[:3, 1]` after exec().

### H2 — canonicalize_human.py floor fix includes object vertices, skewing the floor ⭐⭐

In `canonicalize_human.py` lines 553-555:
```python
diff_candidates = [float(verts[:30, ..., 1].min())]
diff_candidates.extend(object_min_y)         # ← adds object vertices!
diff_fix = min(diff_candidates)
```

If the object is partially below the body floor level, the floor fix amount increases,
shifting BOTH human and object trans up. This changes the absolute canonical heights.

If the reference pipeline did NOT include object vertices in the floor fix (or used
body-only floor), the canonical heights would differ by ~13 cm.

**How to test:**  
Patch `_run_canonicalize_human` to print `diff_fix` and `float(verts[:30, ..., 1].min())`
and `object_min_y` during exec(). Compare `diff_fix` with what body-only floor would give.
The 13 cm discrepancy should equal the difference in `diff_fix`.

### H3 — the two floor fixes (process_omomo + canonicalize_human) interact incorrectly ⭐

`process_omomo.py` already floor-fixes the data (body + object). Then `canonicalize_human.py`
floor-fixes again (body + object). The two floor fixes use different object mesh
representations (process_omomo uses the scaled mesh, canonicalize_human samples it).

If the two floor fixes disagree (e.g., different object vertex sampling), the final
canonical heights drift.

**How to test:**  
Print the floor fix amounts from both process_omomo and canonicalize_human.

### H4 — smplx vs smplh model mismatch ⭐

OMOMO betas are for the SMPL+H body model. All three InterAct scripts apply them to
SMPLX BodyModel (different shape space). FK pelvis position depends on betas + J-regressor
(which differs between SMPLH and SMPLX).

If the reference was generated with SMPLH BodyModel instead of SMPLX BodyModel for
some FK step, the centroid / pelvis positions would differ.

**How to test:**  
In `canonicalize_human.py` for OMOMO, it calls `visualize_smpl(name, MOTION_PATH, 'smplx', 16)`
(line 440) which uses SMPLX16 (BodyModel with SMPLX_*.npz). The process_omomo.py also uses
SMPLX16 BodyModel (lines 36-52). Check the OMOMO paper to see which body model is canonical.

---

## Quick diagnostic script (run in interact env)

Add this block at the end of `_run_process_omomo` and `_run_canonicalize_human` to dump
critical intermediate values without changing the exec() flow:

```python
# After _run_process_omomo:
import numpy as np
_h = np.load(str(sequences_dir / seq_name / "human.npz"), allow_pickle=True)
_o = np.load(str(sequences_dir / seq_name / "object.npz"), allow_pickle=True)
print(f"[POST-process_omomo] human trans Y[:3] = {_h['trans'][:3, 1]}")
print(f"[POST-process_omomo] obj trans Y[:3]   = {_o['trans'][:3, 1]}")
print(f"[POST-process_omomo] obj-human rel Y[0] = {_o['trans'][0,1] - _h['trans'][0,1]:.4f}")

# After _run_canonicalize_human:
_h2 = np.load(str(sequences_can_dir / seq_name / "human.npz"), allow_pickle=True)
_o2 = np.load(str(sequences_can_dir / seq_name / "object.npz"), allow_pickle=True)
print(f"[POST-canonicalize]  human trans Y[:3] = {_h2['trans'][:3, 1]}")
print(f"[POST-canonicalize]  obj trans Y[:3]   = {_o2['trans'][:3, 1]}")
print(f"[POST-canonicalize]  obj-human trans rel Y[0] = {_o2['trans'][0,1] - _h2['trans'][0,1]:.4f}")
```

The `obj-human rel Y` after process_omomo is the pure Y-up relative height before
any canonicalization. Tracking it through each step will pinpoint where the 13 cm
enters.

---

## Reference values needed for verification

To reverse-engineer what the reference canonical data looked like, read the reference .pt:

```python
import torch
ref = torch.load("path/to/OMOMO_new/sub3_largebox_003.pt")
print("ref trans[0] (pelvis XYZ Z-up):", ref[0, 0:3])
print("ref obj[0] (XYZ Z-up):", ref[0, 318:321])
print("ref relative Z:", float(ref[0, 321-3+2] - ref[0, 2]))  # obj_Z - trans_Z
```

This gives `trans_Z` in Z-up space, which = `pelvis_Y` in Y-up canonical space.
From there, work backwards through interact2mimic to reconstruct what canonical
`obj_trans_Y` and `pelvis_Y` the reference used.

---

## Files involved

| File | Role |
|------|------|
| `scripts/wrappers/omomo_to_intermimic.py` | Main wrapper (all exec() patching here) |
| `src/motion_convertor/third_party/InterAct/process/process_omomo.py` | Step 1 (do NOT modify) |
| `src/motion_convertor/third_party/InterAct/process/canonicalize_human.py` | Step 2 (do NOT modify) |
| `src/motion_convertor/third_party/InterAct/simulation/interact2mimic.py` | Step 3 (do NOT modify) |

**Never modify InterAct files.** All fixes go in the wrapper via exec() string patching.
