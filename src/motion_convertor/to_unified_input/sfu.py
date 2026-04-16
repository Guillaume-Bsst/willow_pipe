"""
SFU (AMASS SMPL-X) → unified format.

Input : AMASS .npz with keys root_orient (T,3), pose_body (T,63), trans (T,3),
        betas (16,), gender, mocap_frame_rate (120 Hz).
Output: unified .npz at 30 Hz, global_joint_positions (T,22,3) Z-up metres.

Requires: smplx, torch
"""
import numpy as np
import torch
from pathlib import Path

from ..unified import save_unified
from .._config import body_model_path


def convert(npz_path: Path | str, out_path: Path | str) -> None:
    """
    Convert a single SFU .npz sequence to unified format.

    Parameters
    ----------
    npz_path : path to the AMASS .npz file
    out_path : path to write the unified .npz output
    """
    import smplx

    npz_path = Path(npz_path)
    out_path = Path(out_path)

    data = np.load(npz_path, allow_pickle=True)

    root_orient = data["root_orient"]   # (T, 3)
    pose_body = data["pose_body"]       # (T, 63)
    trans = data["trans"]               # (T, 3)
    betas = data["betas"]               # (16,)
    gender = str(data["gender"])
    fps = float(data.get("mocap_frame_rate", 120.0))

    # Downsample 120 Hz → 30 Hz
    step = max(1, round(fps / 30.0))
    root_orient = root_orient[::step]
    pose_body = pose_body[::step]
    trans = trans[::step]
    T = root_orient.shape[0]

    model_dir = body_model_path("SFU") / "models"
    model = smplx.create(
        str(model_dir),
        model_type="smplx",
        gender=gender,
        num_betas=16,
        use_pca=False,
        flat_hand_mean=True,
    )

    # AMASS pose_body = (T, 63) = 21 body joints only.
    # SMPL-X with use_pca=False expects body_pose + hand poses separately.
    # Pass zero hand poses so batch sizes stay consistent.
    zero_hand = np.zeros((T, 45), dtype=np.float32)

    # Run FK in batches to avoid OOM on long sequences
    batch_size = 512
    all_joints = []
    for start in range(0, T, batch_size):
        end = min(start + batch_size, T)
        bs = end - start
        output = model(
            betas=torch.from_numpy(betas).float().unsqueeze(0).expand(bs, -1),
            body_pose=torch.from_numpy(pose_body[start:end]).float(),
            global_orient=torch.from_numpy(root_orient[start:end]).float(),
            transl=torch.from_numpy(trans[start:end]).float(),
            left_hand_pose=torch.zeros(bs, 45),
            right_hand_pose=torch.zeros(bs, 45),
        )
        all_joints.append(output.joints[:, :22, :].detach().numpy())

    joints = np.concatenate(all_joints, axis=0)  # (T, 22, 3) Z-up metres

    # Compute height from T-pose (zero body pose, betas only)
    tpose_output = model(
        betas=torch.from_numpy(betas).float().unsqueeze(0),
        body_pose=torch.zeros(1, 63),
        global_orient=torch.zeros(1, 3),
        transl=torch.zeros(1, 3),
        left_hand_pose=torch.zeros(1, 45),
        right_hand_pose=torch.zeros(1, 45),
    )
    tpose_joints = tpose_output.joints[0, :22, :].detach().numpy()
    height = float(tpose_joints[:, 2].max() - tpose_joints[:, 2].min())

    save_unified(out_path, joints, height)
