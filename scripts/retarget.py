#!/usr/bin/env python3
"""
retarget.py — run a full retargeting job for one (dataset, robot, retargeter) combination.

Usage:
    python scripts/retarget.py \\
        --dataset LAFAN \\
        --robot G1 \\
        --retargeter GMR \\
        [--sequences seq1 seq2 ...] \\
        [--run-id run_20240301_120000]

Output: data/01_retargeted_motions/{dataset}_{robot}/{retargeter}/run_{timestamp}/
"""
import argparse
import sys
import shutil
import subprocess
import yaml
from datetime import datetime
from pathlib import Path

# Ensure src/ is on sys.path so motion_convertor is importable
_REPO_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(_REPO_ROOT / "src"))

import motion_convertor
from motion_convertor._config import dataset_path, output_path, repo_root
from motion_convertor._subprocess import load_module_cfg, conda_run


# ---------------------------------------------------------------------------
# Dataset helpers
# ---------------------------------------------------------------------------

def discover_sequences(dataset: str, sequences: list[str] | None) -> list[tuple]:
    """
    Return list of (seq_name, raw_path) for a dataset.

    For LAFAN: one .bvh per sequence.
    For SFU: one .npz per sequence (skip neutral_stagei.npz).
    For OMOMO: loaded once as a dict — each key is a sequence index.
                Returns (seq_name, seq_index) tuples; raw_path is the .p file.
    """
    ds = dataset.upper()
    raw_dir = dataset_path(ds)

    if ds == "LAFAN":
        files = sorted(raw_dir.glob("*.bvh"))
        seqs = [(f.stem, f) for f in files]

    elif ds == "SFU":
        files = sorted(raw_dir.rglob("*_stageii.npz"))
        seqs = [(f.stem, f) for f in files]

    elif ds == "OMOMO":
        # The pickle file — sequences are keys inside it
        p_file = raw_dir / "train_diffusion_manip_seq_joints24.p"
        seqs = [("omomo_train", p_file)]   # will be expanded later per-sequence

    else:
        raise ValueError(f"Unknown dataset: {dataset!r}")

    if sequences:
        seqs = [(name, path) for name, path in seqs if name in sequences]

    return seqs


def _get_retargeter_format(dataset: str, retargeter: str) -> str:
    """Return data_format string expected by holosoma retargeter."""
    dataset = dataset.upper()
    if retargeter.lower() == "holosoma":
        if dataset == "LAFAN":
            return "lafan"
        elif dataset in ("SFU", "OMOMO"):
            return "smplx"
    return ""


def _get_file_ext(dataset: str, retargeter: str) -> str:
    """Return expected file extension for retargeter native input."""
    if retargeter.lower() == "gmr":
        if dataset.upper() == "LAFAN":
            return ".bvh"
        return ".npz"
    elif retargeter.lower() == "holosoma":
        if dataset.upper() == "LAFAN":
            return ".npy"
        return ".npz"
    return ".bin"


def _get_output_ext(retargeter: str) -> str:
    if retargeter.lower() == "gmr":
        return ".pkl"
    return ".npz"


# ---------------------------------------------------------------------------
# Per-sequence retargeting
# ---------------------------------------------------------------------------

def retarget_sequence(
    seq_name: str,
    raw_path: Path,
    run_dir: Path,
    dataset: str,
    robot: str,
    retargeter: str,
    cfg: dict,
    seq_data: dict | None = None,
    task_type: str = "robot_only",
) -> None:
    """Run full retargeting pipeline for one sequence."""
    dataset_up = dataset.upper()
    retargeter_lo = retargeter.lower()

    input_ext = _get_file_ext(dataset_up, retargeter_lo)
    output_ext = _get_output_ext(retargeter_lo)

    # holosoma expects {data_path}/{task_name}.ext — use a dedicated input/ subdir
    # so the retargeter input files don't mix with its outputs in run_dir.
    if retargeter_lo == "holosoma":
        input_dir = run_dir / "input"
        input_dir.mkdir(parents=True, exist_ok=True)
        input_raw_path = input_dir / f"{seq_name}{input_ext}"
    else:
        input_raw_path = run_dir / f"{seq_name}_input_raw{input_ext}"

    input_unified_path = run_dir / f"{seq_name}_input_unified.npz"
    output_raw_path = run_dir / f"{seq_name}_output_raw{output_ext}"
    output_unified_path = run_dir / f"{seq_name}_output_unified.npz"

    # Step a: retargeter native input
    print(f"  [1/4] to_retargeter_input → {input_raw_path.name}")
    kw = {}
    if dataset_up == "OMOMO":
        kw["seq_data"] = seq_data
        kw["task_type"] = task_type
        if task_type == "object_interaction":
            kw["out_dir"] = run_dir
    motion_convertor.to_retargeter_input(dataset_up, retargeter_lo, raw_path, input_raw_path, **kw)

    # Step b: unified input
    print(f"  [2/4] to_unified_input    → {input_unified_path.name}")
    kw_uni = {}
    if dataset_up == "OMOMO":
        kw_uni["seq_data"] = seq_data
    motion_convertor.to_unified_input(dataset_up, raw_path, input_unified_path, **kw_uni)

    # Step c: run retargeter subprocess
    print(f"  [3/4] retargeter subprocess ({cfg['env']})")
    _run_retargeter(
        retargeter_lo, cfg, dataset_up, robot,
        input_raw_path, output_raw_path, run_dir,
        seq_name, task_type,
    )

    # Step d: unified output
    print(f"  [4/4] to_unified_output   → {output_unified_path.name}")
    from motion_convertor.unified import load_unified
    unified_in = load_unified(input_unified_path)
    height = unified_in["height"]
    motion_convertor.to_unified_output(retargeter_lo, output_raw_path, output_unified_path, height)


def _run_retargeter(
    retargeter: str,
    cfg: dict,
    dataset: str,
    robot: str,
    input_raw_path: Path,
    output_raw_path: Path,
    run_dir: Path,
    seq_name: str,
    task_type: str,
) -> None:
    """Invoke the external retargeter via subprocess."""
    env = cfg["env"]

    if retargeter == "gmr":
        ep = cfg["entry_points"]["bvh" if dataset == "LAFAN" else "smplx"]
        cmd = ep["cmd"]
        arg_map = ep["args"]
        cmd += f" {arg_map['input']} {input_raw_path}"
        cmd += f" {arg_map['output']} {output_raw_path}"
        # Robot name: GMR uses lowercase e.g. "unitree_g1"
        robot_gmr = _robot_name_gmr(robot)
        cmd += f" {arg_map['robot']} {robot_gmr}"
        conda_run(env, cmd, cwd=repo_root())

    elif retargeter == "holosoma":
        ep = cfg["entry_points"]["single"]
        cmd = ep["cmd"]
        arg_map = ep["args"]
        data_format = _get_retargeter_format(dataset, "holosoma")
        robot_urdf = _robot_urdf_holosoma(robot)
        cmd += f" {arg_map['input_dir']} {input_raw_path.parent}"
        cmd += f" {arg_map['output_dir']} {run_dir}"
        cmd += f" {arg_map['task_type']} {task_type}"
        cmd += f" {arg_map['task_name']} {seq_name}"
        cmd += f" {arg_map['data_format']} {data_format}"
        cmd += f" {arg_map['robot_urdf']} {robot_urdf}"
        conda_run(env, cmd, cwd=repo_root())


def _robot_name_gmr(robot: str) -> str:
    """Map Willow robot names to GMR robot names."""
    mapping = {"G1": "unitree_g1", "H1": "unitree_h1"}
    return mapping.get(robot.upper(), robot.lower())


def _robot_urdf_holosoma(robot: str) -> str:
    """Return absolute URDF path for holosoma retargeting."""
    mapping = {
        "G1": "modules/third_party/holosoma/src/holosoma_retargeting/holosoma_retargeting/models/g1/g1_29dof.urdf",
    }
    rel = mapping.get(robot.upper(), "")
    return str(repo_root() / rel) if rel else ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run a retargeting job.")
    parser.add_argument("--dataset", required=True, help="LAFAN | SFU | OMOMO")
    parser.add_argument("--robot", required=True, help="G1 | H1 | ...")
    parser.add_argument("--retargeter", required=True, help="GMR | holosoma")
    parser.add_argument("--sequences", nargs="*", help="Subset of sequences (default: all)")
    parser.add_argument("--run-id", default=None, help="Resume existing run (e.g. run_20240301_120000)")
    parser.add_argument("--task-type", default="robot_only",
                        choices=["robot_only", "object_interaction"],
                        help="OMOMO task type (default: robot_only)")
    args = parser.parse_args()

    dataset = args.dataset.upper()
    robot = args.robot.upper()
    retargeter = args.retargeter.lower()

    # Load retargeter config
    cfg = load_module_cfg("retargeting", retargeter if retargeter == "gmr" else "holosoma_retargeting")

    # Resolve output run directory
    out_base = output_path("retargeted_motions")
    run_parent = out_base / f"{dataset}_{robot}" / retargeter.upper()
    if args.run_id:
        run_dir = run_parent / args.run_id
    else:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        run_dir = run_parent / f"run_{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"Run directory: {run_dir}")

    # OMOMO: load full pickle once
    omomo_data = None
    if dataset == "OMOMO":
        import joblib
        p_file = dataset_path("OMOMO") / "train_diffusion_manip_seq_joints24.p"
        print(f"Loading OMOMO pickle: {p_file}")
        omomo_data = joblib.load(p_file)

    # Discover sequences
    seqs = discover_sequences(dataset, args.sequences)

    # For OMOMO, expand to per-sequence entries
    if dataset == "OMOMO" and omomo_data is not None:
        expanded = []
        for seq_idx in omomo_data:
            seq_name = omomo_data[seq_idx].get("seq_name", str(seq_idx))
            if args.sequences and seq_name not in args.sequences:
                continue
            expanded.append((seq_name, seq_idx))
        seqs = expanded

    print(f"Processing {len(seqs)} sequences...")

    for i, (seq_name, seq_ref) in enumerate(seqs):
        print(f"\n[{i+1}/{len(seqs)}] {seq_name}")

        if dataset == "OMOMO":
            raw_path = dataset_path("OMOMO") / "train_diffusion_manip_seq_joints24.p"
            seq_data = omomo_data[seq_ref]
        else:
            raw_path = seq_ref
            seq_data = None

        try:
            retarget_sequence(
                seq_name, raw_path, run_dir,
                dataset, robot, retargeter,
                cfg, seq_data=seq_data,
                task_type=args.task_type,
            )
        except Exception as e:
            print(f"  ERROR: {e}")
            continue

    # Write config snapshot
    config_out = run_dir / "config.yaml"
    with open(config_out, "w") as f:
        yaml.dump({
            "dataset": dataset,
            "robot": robot,
            "retargeter": retargeter,
            "task_type": args.task_type,
            "run_dir": str(run_dir),
            "sequences": args.sequences,
        }, f)

    # Update latest symlink
    latest_link = run_parent / "latest"
    if latest_link.is_symlink():
        latest_link.unlink()
    latest_link.symlink_to(run_dir.name)

    print(f"\nDone. Output: {run_dir}")
    print(f"Latest symlink → {run_dir.name}")


if __name__ == "__main__":
    main()
