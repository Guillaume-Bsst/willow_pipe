#!/usr/bin/env python3
"""
holosoma data conversion wrapper — runs in `hsretargeting` conda environment.

Thin CLI shim around holosoma's convert_data_format_mj.py.
Reads a retargeter output .npz (containing qpos), runs the MuJoCo simulation
loop via the native holosoma bridge, and writes form B output .npz.

Usage (called via subprocess from motion_convertor):
    python scripts/wrappers/holosoma_convert.py \\
        --input_file  <path/to/output_raw.npz> \\
        --output_name <path/to/trainer_input.npz> \\
        --robot       g1 \\
        --input_fps   30 \\
        --output_fps  50

This is a pass-through to convert_data_format_mj.py with --once so it runs
one full pass and exits (no interactive viewer loop).
"""
import subprocess
import sys
from pathlib import Path

# The actual bridge lives in hsretargeting env — invoke it directly
# (this wrapper just forwards args and ensures --once is always set)
_BRIDGE = (
    Path(__file__).parents[2]
    / "modules/third_party/holosoma/src/holosoma_retargeting"
    / "holosoma_retargeting/data_conversion/convert_data_format_mj.py"
)


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--input_file", required=True)
    parser.add_argument("--output_name", required=True)
    parser.add_argument("--robot", default="g1")
    parser.add_argument("--input_fps", type=int, default=30)
    parser.add_argument("--output_fps", type=int, default=50)
    args = parser.parse_args()

    cmd = [
        sys.executable, str(_BRIDGE),
        f"--input_file={args.input_file}",
        f"--output_name={args.output_name}",
        f"--robot={args.robot}",
        f"--input_fps={args.input_fps}",
        f"--output_fps={args.output_fps}",
        "--once",
    ]
    result = subprocess.run(cmd, check=True)
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
