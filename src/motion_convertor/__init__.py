"""
motion_convertor — adapter layer between all pipeline stages.

Public API — 4 flat dispatch functions:

    to_retargeter_input(dataset, retargeter, raw_path, out_path, **kwargs)
    to_unified_input(dataset, raw_path, out_path, **kwargs)
    to_unified_output(retargeter, output_raw_path, out_path, height, **kwargs)
    to_trainer_input(retargeter, trainer, output_raw_path, out_path, **kwargs)

Called by scripts/retarget.py and scripts/train.py — never standalone.
"""
from pathlib import Path


# ---------------------------------------------------------------------------
# Role 1b — raw dataset → retargeter native input
# ---------------------------------------------------------------------------

def to_retargeter_input(
    dataset: str,
    retargeter: str,
    raw_path: Path | str,
    out_path: Path | str,
    **kwargs,
) -> None:
    """
    Convert raw dataset file to retargeter-native input format.

    Parameters
    ----------
    dataset   : "LAFAN" | "SFU" | "OMOMO"
    retargeter: "gmr" | "holosoma"
    raw_path  : path to raw source file (.bvh / .npz / .p)
    out_path  : destination path
    kwargs    :
        seq_data (dict) — required for OMOMO (one sequence entry from joblib.load)
        task_type (str) — "robot_only" | "object_interaction" (OMOMO→holosoma only)
    """
    dataset = dataset.upper()
    retargeter = retargeter.lower()
    raw_path = Path(raw_path)
    out_path = Path(out_path)

    if dataset == "LAFAN":
        if retargeter == "gmr":
            from ._to_retargeter_input.lafan_gmr import convert
            convert(raw_path, out_path)
        elif retargeter == "holosoma":
            from ._to_retargeter_input.lafan_holosoma import convert
            convert(raw_path, out_path)
        else:
            raise ValueError(f"Unknown retargeter for LAFAN: {retargeter!r}")

    elif dataset == "SFU":
        if retargeter == "gmr":
            from ._to_retargeter_input.sfu_gmr import convert
            convert(raw_path, out_path)
        elif retargeter == "holosoma":
            from ._to_retargeter_input.sfu_holosoma import convert
            convert(raw_path, out_path)
        else:
            raise ValueError(f"Unknown retargeter for SFU: {retargeter!r}")

    elif dataset == "OMOMO":
        seq_data = kwargs.get("seq_data")
        if seq_data is None:
            raise ValueError("OMOMO conversion requires seq_data= keyword argument")

        if retargeter == "gmr":
            from ._to_retargeter_input.omomo_gmr import convert
            convert(seq_data, out_path)
        elif retargeter == "holosoma":
            task_type = kwargs.get("task_type", "robot_only")
            if task_type == "robot_only":
                from ._to_retargeter_input.omomo_holosoma import convert_robot_only
                convert_robot_only(seq_data, out_path)
            else:
                seq_name = seq_data.get("seq_name", "unknown")
                from ._to_retargeter_input.omomo_holosoma import convert_object_interaction
                convert_object_interaction(seq_name, raw_path, out_path)
        else:
            raise ValueError(f"Unknown retargeter for OMOMO: {retargeter!r}")

    else:
        raise ValueError(f"Unknown dataset: {dataset!r}")


# ---------------------------------------------------------------------------
# Role 1a — raw dataset → unified input npz
# ---------------------------------------------------------------------------

def to_unified_input(
    dataset: str,
    raw_path: Path | str,
    out_path: Path | str,
    **kwargs,
) -> None:
    """
    Convert raw dataset file to unified input format.

    Parameters
    ----------
    dataset  : "LAFAN" | "SFU" | "OMOMO"
    raw_path : path to raw source file
    out_path : destination .npz path
    kwargs   :
        seq_data (dict) — required for OMOMO (one sequence entry from joblib.load)
    """
    dataset = dataset.upper()
    raw_path = Path(raw_path)
    out_path = Path(out_path)

    if dataset == "LAFAN":
        from ._to_unified_input.lafan import convert
        convert(raw_path, out_path)

    elif dataset == "SFU":
        from ._to_unified_input.sfu import convert
        convert(raw_path, out_path)

    elif dataset == "OMOMO":
        seq_data = kwargs.get("seq_data")
        if seq_data is None:
            raise ValueError("OMOMO conversion requires seq_data= keyword argument")
        from ._to_unified_input.omomo import convert
        convert(seq_data, out_path)

    else:
        raise ValueError(f"Unknown dataset: {dataset!r}")


# ---------------------------------------------------------------------------
# Role 2 — retargeter native output → unified output npz
# ---------------------------------------------------------------------------

def to_unified_output(
    retargeter: str,
    output_raw_path: Path | str,
    out_path: Path | str,
    height: float,
    **kwargs,
) -> None:
    """
    Convert retargeter output to unified format.

    Parameters
    ----------
    retargeter      : "gmr" | "holosoma"
    output_raw_path : retargeter output file (.pkl for GMR, .npz for holosoma)
    out_path        : destination unified .npz path
    height          : subject height in metres (from input_unified.npz)
    kwargs          :
        xml_path (Path) — robot XML for GMR FK (default: G1 29-DOF)
    """
    retargeter = retargeter.lower()
    output_raw_path = Path(output_raw_path)
    out_path = Path(out_path)

    if retargeter == "gmr":
        from ._to_unified_output.gmr import convert
        convert(output_raw_path, out_path, height, xml_path=kwargs.get("xml_path"))

    elif retargeter == "holosoma":
        from ._to_unified_output.holosoma import convert
        convert(output_raw_path, out_path, height)

    else:
        raise ValueError(f"Unknown retargeter: {retargeter!r}")


# ---------------------------------------------------------------------------
# Role 3 — retargeter native output → trainer input
# ---------------------------------------------------------------------------

def to_trainer_input(
    retargeter: str,
    trainer: str,
    output_raw_path: Path | str,
    out_path: Path | str,
    **kwargs,
) -> None:
    """
    Convert retargeter output to trainer-native input format.

    Called by scripts/train.py — independent of the retargeting step.
    Reads output_raw directly; never reads the unified output.

    Parameters
    ----------
    retargeter      : "gmr" | "holosoma"
    trainer         : "holosoma"
    output_raw_path : retargeter output file
    out_path        : destination .npz path
    kwargs          :
        xml_path (Path) — robot XML for GMR FK (default: G1 29-DOF)
    """
    retargeter = retargeter.lower()
    trainer = trainer.lower()
    output_raw_path = Path(output_raw_path)
    out_path = Path(out_path)

    if retargeter == "holosoma" and trainer == "holosoma":
        from ._to_trainer_input.holosoma_holosoma import convert
        convert(output_raw_path, out_path,
                robot=kwargs.get("robot", "g1"),
                input_fps=kwargs.get("input_fps", 30),
                output_fps=kwargs.get("output_fps", 50))

    elif retargeter == "gmr" and trainer == "holosoma":
        from ._to_trainer_input.gmr_holosoma import convert
        convert(output_raw_path, out_path, xml_path=kwargs.get("xml_path"))

    else:
        raise ValueError(
            f"No trainer input bridge for retargeter={retargeter!r}, trainer={trainer!r}"
        )
