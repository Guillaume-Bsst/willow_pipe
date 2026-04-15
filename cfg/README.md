# cfg/

Configuration files for all pipeline stages. Each yaml is the **single point of contact** between Willow WBT and an external module — it describes how to call the module without touching its code.

---

## Structure

```
cfg/
├── data.yaml              # paths to raw datasets and body models
├── retargeting/
│   ├── gmr.yaml           # GMR env, entry points, args, FK wrapper
│   └── holosoma_retargeting.yaml
├── training/
│   └── holosoma.yaml      # one entry per simulator (isaacgym / isaacsim / mjwarp)
├── inference/
│   └── holosoma_inference.yaml
└── processing/
    └── interact.yaml      # InterAct env — OMOMO .p → .pt conversion pipeline
```

Wrapper scripts (our thin Python scripts that run inside a module's env to expose specific utilities) live in `scripts/wrappers/` and are referenced from the relevant yaml under the `wrappers:` key.

---

## data.yaml

Centralises all dataset paths and body model locations. Read by `src/motion_convertor/` to resolve input paths without hardcoding.

---

## Module yamls (`retargeting/`, `training/`, `inference/`)

Each yaml describes one external module. The format is intentionally **not standardised** — each yaml mirrors the actual structure of the module it wraps.

Common fields (when applicable):

| Field | Description |
|-------|-------------|
| `env` | conda environment name to activate for this module |
| `cmd` | python command to run (relative to repo root) |
| `args` | mapping of Willow argument names → module CLI flags |
| `setup_script` | module's own setup/activation script (if needed) |

Modules with multiple environments (e.g. holosoma training with isaacgym/isaacsim/mjwarp) use a `simulators:` sub-dict — one entry per env.

### Customisation

These files ship with defaults matching the standard install of each submodule. If you fork a module, rename a script, or use a different conda env name — edit only the relevant yaml. Nothing else in the pipeline needs to change.

### Adding a new module

1. Add the submodule under `modules/`
2. Create `cfg/{stage}/{module_name}.yaml` following the pattern of existing yamls
3. Add the corresponding adapter in `src/motion_convertor/` (see `src/motion_convertor/TODO.md`)
