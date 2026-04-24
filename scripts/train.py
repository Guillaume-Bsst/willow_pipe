#!/usr/bin/env python3
"""
train.py — prepare trainer input and launch training from an existing retargeting run.

Usage:
    python scripts/train.py \\
        --dataset LAFAN \\
        --robot G1 \\
        --retargeter GMR \\
        --trainer holosoma \\
        --simulator mjwarp \\
        [--retarget-run latest] \\
        [--num-envs 4096] \\
        [--checkpoint path/to/checkpoint.pt]

Output: data/02_policies/{dataset}_{robot}/{retargeter}_{trainer}/run_{timestamp}/
"""
import argparse
import sys
import yaml
from datetime import datetime
from pathlib import Path

_REPO_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(_REPO_ROOT / "src"))

import motion_convertor
from motion_convertor._config import output_path, repo_root
from motion_convertor._subprocess import conda_run


def resolve_retarget_run(dataset: str, robot: str, retargeter: str, run_id: str) -> Path:
    """Resolve a retargeting run directory (or 'latest' symlink)."""
    base = output_path("retargeted_motions")
    run_parent = base / f"{dataset}_{robot}" / retargeter.upper()

    if run_id == "latest":
        link = run_parent / "latest"
        if not link.exists():
            raise FileNotFoundError(f"No 'latest' symlink in {run_parent}")
        return link.resolve()

    run_dir = run_parent / run_id
    if not run_dir.exists():
        raise FileNotFoundError(f"Retarget run not found: {run_dir}")
    return run_dir


def prepare_trainer_inputs(retarget_run: Path, retargeter: str, trainer: str) -> list[Path]:
    from motion_convertor._subprocess import load_module_cfg
    from motion_convertor.formats import validate_format

    ret_cfg = load_module_cfg("retargeting", retargeter.lower())
    output_format = ret_cfg["native_output_format"]
    validate_format(output_format)

    suffix = output_format.rsplit("_", 1)[-1]
    _EXT_MAP = {"bvh": ".bvh", "npy": ".npy", "npz": ".npz", "pkl": ".pkl", "p": ".p", "pt": ".pt"}
    output_ext = _EXT_MAP[suffix]

    output_raw_files = sorted(retarget_run.glob(f"*_output_raw{output_ext}"))
    trainer_input_paths = []

    for output_raw in output_raw_files:
        seq_name = output_raw.stem.replace("_output_raw", "")
        trainer_input_path = retarget_run / f"{seq_name}_trainer_input.npz"

        if trainer_input_path.exists():
            print(f"  [skip] {trainer_input_path.name} already exists")
        else:
            print(f"  to_trainer_input → {trainer_input_path.name}")
            motion_convertor.to_trainer_input(
                retargeter.lower(), trainer.lower(),
                output_raw, trainer_input_path,
            )

        trainer_input_paths.append(trainer_input_path)

    return trainer_input_paths


def run_training(
    cfg: dict,
    simulator: str,
    trainer_input_paths: list[Path],
    policy_run_dir: Path,
    robot: str,
    num_envs: int | None,
    checkpoint: str | None,
) -> None:
    """Launch the trainer subprocess."""
    sim_cfg = cfg["simulators"][simulator]
    env = sim_cfg["env"]
    cmd = sim_cfg["cmd"]
    extra_args = sim_cfg.get("extra_args", "")
    arg_map = cfg.get("args", {})

    # holosoma expects a motion file or directory
    # Pass the retarget run directory so trainer can find all trainer_input.npz files
    motion_dir = trainer_input_paths[0].parent if trainer_input_paths else policy_run_dir
    cmd += f" {arg_map['motion_file']} {motion_dir}"
    cmd += f" {arg_map['output_dir']} {policy_run_dir}"
    cmd += f" {arg_map['robot']} {robot.lower()}"
    if num_envs:
        cmd += f" {arg_map['num_envs']} {num_envs}"
    if checkpoint:
        cmd += f" {arg_map['checkpoint']} {checkpoint}"
    if extra_args:
        cmd += f" {extra_args}"

    conda_run(env, cmd, cwd=repo_root())


def main():
    parser = argparse.ArgumentParser(description="Run a training job.")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--robot", required=True)
    parser.add_argument("--retargeter", required=True)
    parser.add_argument("--trainer", required=True, help="holosoma")
    parser.add_argument("--simulator", default="mjwarp",
                        help="Simulator backend (must match a key under 'simulators:' in the trainer YAML)")
    parser.add_argument("--retarget-run", default="latest",
                        help="Retargeting run ID or 'latest' (default: latest)")
    parser.add_argument("--num-envs", type=int, default=None)
    parser.add_argument("--checkpoint", default=None, help="Resume from checkpoint")
    args = parser.parse_args()

    dataset = args.dataset.upper()
    robot = args.robot.upper()
    retargeter = args.retargeter.lower()
    trainer = args.trainer.lower()

    # Load trainer config
    cfg_path = repo_root() / "cfg" / "training" / f"{trainer}.yaml"
    with open(cfg_path) as f:
        cfg = yaml.safe_load(f)

    # Locate retargeting run
    retarget_run = resolve_retarget_run(dataset, robot, retargeter, args.retarget_run)
    print(f"Retarget run: {retarget_run}")

    # Prepare trainer inputs
    print("Preparing trainer inputs...")
    trainer_inputs = prepare_trainer_inputs(retarget_run, retargeter, trainer)
    print(f"  {len(trainer_inputs)} sequences ready")

    # Create policy run directory
    policies_base = output_path("policies")
    policy_parent = policies_base / f"{dataset}_{robot}" / f"{retargeter}_{trainer}"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    policy_run_dir = policy_parent / f"run_{timestamp}"
    policy_run_dir.mkdir(parents=True, exist_ok=True)

    print(f"Policy run: {policy_run_dir}")

    # Launch training
    print(f"Launching {trainer} training ({args.simulator})...")
    run_training(cfg, args.simulator, trainer_inputs, policy_run_dir, robot,
                 args.num_envs, args.checkpoint)

    # Write config snapshot
    with open(policy_run_dir / "config.yaml", "w") as f:
        yaml.dump({
            "dataset": dataset,
            "robot": robot,
            "retargeter": retargeter,
            "trainer": trainer,
            "simulator": args.simulator,
            "retarget_run": str(retarget_run),
            "num_envs": args.num_envs,
        }, f)

    # Update latest symlink
    latest_link = policy_parent / "latest"
    if latest_link.is_symlink():
        latest_link.unlink()
    latest_link.symlink_to(policy_run_dir.name)

    print(f"\nDone. Policy output: {policy_run_dir}")


if __name__ == "__main__":
    main()
