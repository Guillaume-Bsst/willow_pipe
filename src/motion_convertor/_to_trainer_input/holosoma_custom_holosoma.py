"""
holosoma_custom retargeter output → holosoma trainer input (form B).

Same logic as holosoma_holosoma.py but runs in the hscretargeting conda env
(Guillaume-Bsst/holosoma_custom ecosystem).
"""
from pathlib import Path

from .._subprocess import conda_run
from .._config import repo_root

_WRAPPER = "src/motion_convertor/wrappers/holosoma_convert.py"
_ENV = "hscretargeting"


def convert(
    output_raw_path: Path | str,
    out_path: Path | str,
    robot: str = "g1",
    input_fps: int = 30,
    output_fps: int = 50,
) -> None:
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
