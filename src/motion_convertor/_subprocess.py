"""
Helpers for running module commands in their own conda environments.
Reads cfg/ yamls to get env names and command templates.
"""
import os
import subprocess
import sys
import yaml
from pathlib import Path

from ._config import repo_root


def load_module_cfg(stage: str, module: str) -> dict:
    """Load cfg/{stage}/{module}.yaml"""
    cfg_path = repo_root() / "cfg" / stage / f"{module}.yaml"
    return yaml.safe_load(cfg_path.read_text())


def conda_run(
    env: str,
    cmd: str,
    cwd: Path | None = None,
    check: bool = True,
    interactive: bool = False,
    prefix: str | None = None,
) -> subprocess.CompletedProcess:
    """
    Run a shell command inside a conda environment.

    Uses `conda run -n {env} --no-capture-output {cmd}` so that the
    subprocess inherits stdout/stderr (visible to the caller).

    When interactive=True, stdin is inherited from the calling terminal so
    that blocking prompts (e.g. input()) work correctly.
    """
    if cwd is None:
        cwd = repo_root()

    # `conda run` does not respect the calling shell's cwd — prepend an explicit cd.
    # Use --prefix when the env lives outside the active conda root (e.g. holosoma envs).
    if prefix is not None:
        env_selector = f"--prefix {os.path.expandvars(prefix)}"
    else:
        env_selector = f"-n {env}"
        python_exec_path = f"{os.path.expandvars(prefix)}/bin/python"
        # Assuming python3.11 based on the error message
        python_version_dir = "python3.11"
        site_packages_path = f"{os.path.expandvars(prefix)}/lib/{python_version_dir}/site-packages"

        # The python executable is invoked as part of the `cmd` string.
        # We need to insert the PYTHONPATH export right before this python invocation.
        # Find the specific python executable from the given `prefix` in the `cmd` string.
        # We replace the invocation pattern `&& <python_exec_path>` with
        # `&& export PYTHONPATH=<site_packages_path>:${PYTHONPATH} && <python_exec_path>`
        # This ensures the correct site-packages are prioritized after any other environment setups (like ROS2 sourcing).
        search_pattern = f"&& {python_exec_path}"
        if search_pattern in cmd:
            replacement_pattern = f"&& export PYTHONPATH={site_packages_path}:${{PYTHONPATH}} && {python_exec_path}"
            cmd = cmd.replace(search_pattern, replacement_pattern, 1) # Replace only the first occurrence

    full_cmd = f"conda run {env_selector} --no-capture-output bash -c 'cd {cwd} && {cmd}'"
    stdin = None if interactive else subprocess.DEVNULL
    return subprocess.run(
        full_cmd,
        shell=True,
        check=check,
        stdin=stdin,
    )


def run_entry_point(stage: str, module: str, entry: str, args: dict, cwd: Path | None = None) -> subprocess.CompletedProcess:
    """
    Run a named entry point from cfg/{stage}/{module}.yaml.

    `args` is a dict mapping Willow arg names → values.
    Unrecognised keys are silently ignored (some entry points have no args).
    """
    cfg = load_module_cfg(stage, module)
    env = cfg["env"]
    ep = cfg["entry_points"][entry]

    cmd = os.path.expandvars(ep["cmd"])
    arg_map = ep.get("args", {})
    for willow_key, value in args.items():
        flag = arg_map.get(willow_key)
        if flag is not None:
            cmd += f" {flag} {value}"

    # Use per-entry cwd if specified in yaml, otherwise fall back to caller-supplied cwd
    ep_cwd = ep.get("cwd")
    if ep_cwd is not None:
        effective_cwd = repo_root() / ep_cwd
    elif cwd is not None:
        effective_cwd = cwd
    else:
        effective_cwd = repo_root()

    prefix = cfg.get("env_prefix")
    return conda_run(env, cmd, cwd=effective_cwd, prefix=prefix)
