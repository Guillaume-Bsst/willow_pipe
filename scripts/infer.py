#!/usr/bin/env python3
"""
infer.py — run a trained policy in simulation or on a real robot.

Usage:
    # sim
    python scripts/infer.py \\
        --dataset LAFAN --robot G1 \\
        --retargeter GMR --trainer holosoma \\
        --mode sim \\
        [--policy-run latest]

    # real robot
    python scripts/infer.py \\
        --dataset LAFAN --robot G1 \\
        --retargeter GMR --trainer holosoma \\
        --mode real \\
        [--policy-run latest]
"""
import argparse
import sys
import yaml
from pathlib import Path

_REPO_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(_REPO_ROOT / "src"))

from motion_convertor._config import output_path, repo_root
from motion_convertor._subprocess import conda_run


def resolve_policy_run(dataset: str, robot: str, retargeter: str, trainer: str, run_id: str) -> Path:
    """Resolve a policy run directory (or 'latest' symlink)."""
    base = output_path("policies")
    run_parent = base / f"{dataset}_{robot}" / f"{retargeter}_{trainer}"

    if run_id == "latest":
        link = run_parent / "latest"
        if not link.exists():
            raise FileNotFoundError(f"No 'latest' symlink in {run_parent}")
        return link.resolve()

    run_dir = run_parent / run_id
    if not run_dir.exists():
        raise FileNotFoundError(f"Policy run not found: {run_dir}")
    return run_dir


def main():
    parser = argparse.ArgumentParser(description="Run inference with a trained policy.")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--robot", required=True)
    parser.add_argument("--retargeter", required=True)
    parser.add_argument("--trainer", required=True, help="holosoma")
    parser.add_argument("--mode", required=True, choices=["sim", "real"])
    parser.add_argument("--engine", default="holosoma_inference",
                        help="Inference engine (default: holosoma_inference)")
    parser.add_argument("--policy-run", default="latest",
                        help="Policy run ID or 'latest' (default: latest)")
    parser.add_argument("--config", default=None,
                        help="Inference config name (e.g. inference:g1-29dof-wbt)")
    parser.add_argument("--motion-file", default=None,
                        help="Optional motion file for WBT inference mode")
    args = parser.parse_args()

    dataset = args.dataset.upper()
    robot = args.robot.upper()
    retargeter = args.retargeter.lower()
    trainer = args.trainer.lower()

    # Load inference config
    cfg_path = repo_root() / "cfg" / "inference" / f"{args.engine}.yaml"
    with open(cfg_path) as f:
        cfg = yaml.safe_load(f)

    # Locate policy run
    policy_run = resolve_policy_run(dataset, robot, retargeter, trainer, args.policy_run)
    print(f"Policy run: {policy_run}")

    # Find policy file
    onnx_files = list(policy_run.glob("*.onnx"))
    pt_files = list(policy_run.glob("*.pt"))
    model_path = onnx_files[0] if onnx_files else (pt_files[0] if pt_files else None)
    if model_path is None:
        raise FileNotFoundError(f"No .onnx or .pt policy file found in {policy_run}")
    print(f"Model: {model_path}")

    # Build command
    env = cfg["env"]
    ep = cfg["entry_points"][args.mode]
    cmd = ep["cmd"]
    arg_map = ep.get("args", {})

    if args.config:
        cmd += f" {args.config}"
    cmd += f" {arg_map['model_path']} {model_path}"
    if args.motion_file and arg_map.get("motion_file"):
        cmd += f" {arg_map['motion_file']} {args.motion_file}"

    print(f"Launching {args.engine} ({args.mode})...")
    conda_run(env, cmd, cwd=repo_root())


if __name__ == "__main__":
    main()
