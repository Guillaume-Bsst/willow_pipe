"""
holosoma retargeter output → holosoma trainer input (form B).

Delegates to holosoma's native bridge (convert_data_format_mj.py) via
subprocess in the `hsretargeting` conda environment, exactly as gmr_holosoma.py
delegates to gmr_fk.py in the `gmr` env.

The native bridge:
  - Reads retargeter output .npz containing qpos (T, 36) at 30 Hz (form A)
  - Runs a headless MuJoCo simulation (--once) to extract body positions,
    quaternions, and velocities at 50 Hz
  - Writes form B .npz: fps, joint_pos, joint_vel, body_pos_w, body_quat_w,
    body_lin_vel_w, body_ang_vel_w, joint_names, body_names
"""
from pathlib import Path

from .._subprocess import conda_run
from .._config import repo_root

_WRAPPER = "scripts/wrappers/holosoma_convert.py"
_ENV = "hsretargeting"


def convert(
    output_raw_path: Path | str,
    out_path: Path | str,
    robot: str = "g1",
    input_fps: int = 30,
    output_fps: int = 50,
) -> None:
    """
    Convert holosoma retargeter output to trainer input (form B) via the
    native holosoma bridge running in the hsretargeting env.

    Parameters
    ----------
    output_raw_path : holosoma retargeter output .npz (contains qpos)
    out_path        : destination form B .npz path
    robot           : robot name as expected by holosoma (default: g1)
    input_fps       : FPS of the retargeter output (default: 30)
    output_fps      : FPS for trainer input (default: 50)
    """
    output_raw_path = Path(output_raw_path)
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    wrapper = repo_root() / _WRAPPER
    cmd = (
        f"python {wrapper} "
        f"--input_file {output_raw_path} "
        f"--output_name {out_path} "
        f"--robot {robot} "
        f"--input_fps {input_fps} "
        f"--output_fps {output_fps}"
    )
    conda_run(_ENV, cmd, cwd=repo_root())
