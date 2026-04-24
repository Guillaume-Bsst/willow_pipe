#!/usr/bin/env python3
"""
retarget.py — run a full retargeting job for one (dataset, robot, retargeter) combination.

Usage:
    python scripts/retarget.py \
        --dataset LAFAN \
        --robot G1 \
        --retargeter GMR \
        [--sequences seq1 seq2 ...] \
        [--run-id run_20240301_120000]

Output: data/01_retargeted_motions/{dataset}_{robot}/{retargeter}/run_{timestamp}/
"""
import argparse
import sys
import yaml
from datetime import datetime
from pathlib import Path

_REPO_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(_REPO_ROOT / "src"))

import motion_convertor
from motion_convertor._config import dataset_path, output_path, repo_root, body_model_smplx_path
from motion_convertor._subprocess import load_module_cfg, conda_run
from motion_convertor.formats import validate_format


# ---------------------------------------------------------------------------
# Dataset helpers — driven by cfg/datasets/<dataset>.yaml
# ---------------------------------------------------------------------------

def _load_dataset_cfg(dataset: str) -> dict:
    cfg_path = repo_root() / "cfg" / "datasets" / f"{dataset.lower()}.yaml"
    return yaml.safe_load(cfg_path.read_text())


def discover_sequences(dataset: str, sequences: list[str] | None) -> list[tuple]:
    ds = dataset.upper()
    ds_cfg = _load_dataset_cfg(ds)
    raw_dir = dataset_path(ds)
    discover = ds_cfg["discover"]

    if discover == "single_files":
        pattern = ds_cfg["file_pattern"]
        if "**" in pattern:
            files = sorted(raw_dir.rglob(pattern))
        else:
            files = sorted(raw_dir.glob(pattern))
        seqs = [(f.stem, f) for f in files]

    elif discover == "pickle_keys":
        p_file = next(raw_dir.glob(ds_cfg["file_pattern"]))
        seqs = [("omomo_train", p_file)]   # expanded later per-sequence

    else:
        raise ValueError(f"Unknown discover strategy {discover!r} for dataset {ds!r}")

    if sequences:
        seqs = [(name, path) for name, path in seqs if name in sequences]
    return seqs


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
    visualize: bool = False,
) -> None:
    dataset_up = dataset.upper()
    retargeter_lo = retargeter.lower()

    # Resolve formats from module YAML
    input_format = cfg["native_input_format"][dataset_up]
    output_format = cfg["native_output_format"]
    validate_format(input_format)
    validate_format(output_format)

    # Derive file extensions from format names
    input_ext = _ext_from_format(input_format)
    output_ext = _ext_from_format(output_format)

    if cfg.get("input_path_style") == "dir":
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
    motion_convertor.to_retargeter_input(dataset_up, retargeter_lo, raw_path, input_raw_path, **kw)

    # Step b: unified input (skipped for OMOMO_NEW)
    if dataset_up != "OMOMO_NEW":
        print(f"  [2/4] to_unified_input    → {input_unified_path.name}")
        kw_uni = {}
        if dataset_up == "OMOMO":
            kw_uni["seq_data"] = seq_data
        motion_convertor.to_unified_input(dataset_up, raw_path, input_unified_path, **kw_uni)
    else:
        print(f"  [2/4] to_unified_input    → skipped (OMOMO_new precomputed)")

    # Step c: run retargeter subprocess
    print(f"  [3/4] retargeter subprocess ({cfg['env']})")
    _run_retargeter(
        retargeter_lo, cfg, input_format,
        input_raw_path, output_raw_path, run_dir,
        seq_name, robot, task_type, visualize,
        dataset=dataset_up,
    )

    # Step d: unified output
    print(f"  [4/4] to_unified_output   → {output_unified_path.name}")
    if dataset_up == "OMOMO_NEW":
        height = 0.0
    else:
        from motion_convertor.unified import load_unified
        height = load_unified(input_unified_path)["height"]
    motion_convertor.to_unified_output(retargeter_lo, output_raw_path, output_unified_path, height)


_EXT_MAP: dict[str, str] = {
    "bvh": ".bvh", "npy": ".npy", "npz": ".npz",
    "pkl": ".pkl", "p": ".p", "pt": ".pt",
}


def _ext_from_format(fmt: str) -> str:
    """Derive file extension from format name (suffix after last underscore)."""
    suffix = fmt.rsplit("_", 1)[-1]
    ext = _EXT_MAP.get(suffix)
    if ext is None:
        raise ValueError(f"Cannot derive file extension from format {fmt!r}")
    return ext


def _run_retargeter(
    retargeter: str,
    cfg: dict,
    input_format: str,
    input_raw_path: Path,
    output_raw_path: Path,
    run_dir: Path,
    seq_name: str,
    robot: str,
    task_type: str = "robot_only",
    visualize: bool = False,
    dataset: str = "",
) -> None:
    env = cfg["env"]
    ep_name = cfg["entry_point_by_input_format"][input_format]
    ep = cfg["entry_points"][ep_name]
    arg_map = ep.get("args", {})
    ep_cwd = repo_root() / ep["cwd"] if "cwd" in ep else repo_root()

    robot_cfg = cfg.get("robot_config", {}).get(robot.upper(), {})
    format_args = cfg.get("format_args", {}).get(input_format, {})

    cmd = ep["cmd"]

    # Input
    if "input" in arg_map:
        cmd += f" {arg_map['input']} {input_raw_path}"
    elif "input_dir" in arg_map:
        cmd += f" {arg_map['input_dir']} {input_raw_path.parent}"

    # Output
    if "output" in arg_map:
        cmd += f" {arg_map['output']} {output_raw_path}"
    elif "output_dir" in arg_map:
        cmd += f" {arg_map['output_dir']} {run_dir}"

    # Robot (name style — GMR)
    if "robot" in arg_map and "name" in robot_cfg:
        cmd += f" {arg_map['robot']} {robot_cfg['name']}"

    # Robot (urdf style — holosoma)
    if "robot_urdf" in arg_map and "urdf" in robot_cfg:
        cmd += f" {arg_map['robot_urdf']} {repo_root() / robot_cfg['urdf']}"

    # Body model path (GMR SMPLX entry points only)
    if "body_model_path" in arg_map and dataset and dataset != "LAFAN":
        cmd += f" {arg_map['body_model_path']} {body_model_smplx_path(dataset).parent}"

    # Holosoma-style args
    if "task_type" in arg_map:
        cmd += f" {arg_map['task_type']} {task_type}"
    if "task_name" in arg_map:
        cmd += f" {arg_map['task_name']} {seq_name}"
    if "data_format" in arg_map and "data_format" in format_args:
        cmd += f" {arg_map['data_format']} {format_args['data_format']}"

    # Visualize
    can_visualize = visualize and "visualize" in arg_map
    if can_visualize:
        cmd += f" {arg_map['visualize']}"
        if "debug" in arg_map:
            cmd += f" {arg_map['debug']}"

    conda_run(env, cmd, cwd=ep_cwd, interactive=can_visualize)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run a retargeting job.")
    parser.add_argument("--dataset", required=True, help="LAFAN | SFU | OMOMO | OMOMO_new")
    parser.add_argument("--robot", required=True, help="G1 | H1 | ...")
    parser.add_argument("--retargeter", required=True, help="gmr | holosoma | holosoma_custom")
    parser.add_argument("--sequences", nargs="*", help="Subset of sequences (default: all)")
    parser.add_argument("--run-id", default=None)
    parser.add_argument("--task-type", default="robot_only",
                        choices=["robot_only", "object_interaction"])
    parser.add_argument("--visualize", action="store_true")
    args = parser.parse_args()

    dataset = args.dataset.upper()
    robot = args.robot.upper()
    retargeter = args.retargeter.lower()
    task_type = args.task_type

    cfg = load_module_cfg("retargeting", retargeter)

    out_base = output_path("retargeted_motions")
    if dataset == "OMOMO":
        task_suffix = "robot" if task_type == "robot_only" else "object"
        dataset_dir = f"OMOMO_{task_suffix}_{robot}"
    elif dataset == "OMOMO_NEW":
        dataset_dir = f"OMOMO_new_object_{robot}"
    else:
        dataset_dir = f"{dataset}_{robot}"

    run_parent = out_base / dataset_dir / retargeter.upper()
    if args.run_id:
        run_dir = run_parent / args.run_id
    else:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        run_dir = run_parent / f"run_{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    print(f"Run directory: {run_dir}")

    omomo_data = None
    if dataset == "OMOMO":
        import joblib
        p_file = dataset_path("OMOMO") / "train_diffusion_manip_seq_joints24.p"
        print(f"Loading OMOMO pickle: {p_file}")
        omomo_data = joblib.load(p_file)

    seqs = discover_sequences(dataset, args.sequences)

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
                task_type=task_type,
                visualize=args.visualize,
            )
        except Exception as e:
            print(f"  ERROR: {e}")
            continue

    config_out = run_dir / "config.yaml"
    with open(config_out, "w") as f:
        yaml.dump({
            "dataset": dataset, "robot": robot, "retargeter": retargeter,
            "task_type": task_type, "run_dir": str(run_dir),
            "sequences": args.sequences,
        }, f)

    latest_link = run_parent / "latest"
    if latest_link.is_symlink():
        latest_link.unlink()
    latest_link.symlink_to(run_dir.name)

    print(f"\nDone. Output: {run_dir}")
    print(f"Latest symlink → {run_dir.name}")


if __name__ == "__main__":
    main()
