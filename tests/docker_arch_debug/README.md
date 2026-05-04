# Docker Arch Debug Environment

Minimal Arch Linux container for debugging `install.sh` targets in a clean,
apt-free environment. The repo is volume-mounted — no rebuild needed between
`install.sh` edits.

## Build

```bash
# Run from the repo root
docker build -t willow-arch-debug tests/docker_arch_debug/
```

## Run

```bash
docker run -it --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  willow-arch-debug bash
```

## Inside the container

Git volume-mount ownership fix (required once per session):
```bash
git config --global --add safe.directory /workspace
```

Then run any install target:
```bash
./install.sh willow
./install.sh inference custom
./install.sh deployment
```

## Notes

- `sudo apt-get` calls are silently skipped by `install.sh`'s fake sudo wrapper
- Miniforge is installed to `~/.willow_deps/` inside the container (ephemeral — gone when container exits)
- Re-running `docker run` starts from a clean state; use a named volume if you want to persist conda envs across sessions:
  `docker run -it --rm -v $(pwd):/workspace -v willow-conda:/home/willow -w /workspace willow-arch-debug bash`
- `./install.sh deployment` runs a full `colcon build` (ROS2/cyclonedds) — expect 15-30 min on first run
