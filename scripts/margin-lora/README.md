# Margin Empero LoRA workstation pilot

Workstation: `oluyi@100.126.58.91` (Temple-Workstation, RTX 5070 Ti).
Project: `C:\Users\oluyi\Documents\Projects\Margin-Empero-LoRA`.
WSL: Ubuntu-24.04; environment: `/home/oluyi/.venvs/margin-empero-lora`.

## Dashboard

While the SSH session is connected, open http://127.0.0.1:18766 on the Mac.
The read-only dashboard shows phase, optimizer steps, loss, GPU usage,
checkpoints, dataset counts and timestamped logs. Refreshes every 10 seconds.
It does not prove evaluation improvements.

To reopen the dashboard server and tunnel after shutdown:

```sh
ssh -o ExitOnForwardFailure=yes -L 18766:127.0.0.1:8766 oluyi@100.126.58.91 "wsl -d Ubuntu-24.04 -- python3 /mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA/scripts/dashboard.py --root /mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA --port 8766"
```

If the server is already running, use `ssh -N -L 18766:127.0.0.1:8766 oluyi@100.126.58.91` instead.
The server binds loopback; no public firewall port is opened.
Keep remote WSL training attached to SSH: detached children did not reliably
survive the WSL launcher ending in this environment.

## Artifacts and boundaries

`status.json` is current state; `logs/metrics.jsonl` records optimizer metrics;
`logs/gpu.jsonl` records total GPU samples; `artifacts/` holds configs,
base revision, tokenization reports and adapters/checkpoints.

The initial corpus contains 3,000 train, 400 validation and 600 heldout
synthetic development examples. Shared generator patterns mean these are
not independent adversarial holdouts. All 4,000 pass structural validation;
27 of 29 tools are represented. Original frozen eval prompts are excluded.
Full original evals, independent tests and quantized 16 GB Mac deployment
validation are required before selecting an adapter for the app.

The first smoke attempt loaded BF16 weights but failed before any optimizer
step because Unsloth expects adapter leaf names, not complete module paths.
The corrected script disables vision adapters explicitly. No app model has
been replaced. Existing workstation ComfyUI was left running.

## Export preflight and full pilot

`export_preflight.py` reloads the smoke adapter against the pinned BF16 base,
checks a JSON generation and merges with PEFT safe_merge. `setup-export.sh`
builds llama.cpp's CPU quantizer at the revision recorded in artifacts.
`convert_exports.py` writes independent base-control and smoke-adapted BF16
and Q4_K_M files with SHA-256 digests. `check_ollama_export.py` loads each
export separately on the Mac and checks JSON and native tool-call decoding.
These are transport checks, not a category accuracy evaluation.

`run-pilot.sh` starts the full 3,000-example rank-16 pilot from the original
base after `artifacts/export-gate.json` records passed checks. It does not
resume smoke weights. The main run saves every 10 optimizer steps. A STOP
file requests a recoverable stop at the next logging boundary.


### Empero merge repair

The first adapted export failed in Ollama with missing `blk.32.attn_norm.weight`.
Transformers serialization repeated language_model prefixes and omitted 15
`mtp.*` tensors while keeping the auxiliary layer in the config. Use
`canonicalize_merge.py` after merging: it maps each tensor uniquely to an
original source key, rejects unexpected omissions and restores only untouched
MTP tensors. `verify_merge.py` proves sampled trained weights changed and all
15 MTP tensors match the source exactly. Convert `smoke-canonical`, not the
uncorrected `smoke-merged` directory. Keep this repair in the pilot export path.


### Long-run ownership

The full pilot is registered as the limited-permission, on-demand Windows task
`Margin-Empero-LoRA-Pilot-20260912`. It has no automatic trigger. Start only after
export-gate.json passes; the task runs the pilot and monitor together, independent
of the Mac SSH connection. The dashboard still uses the SSH tunnel for access.
Checkpoint recovery after a host restart is explicit, not automatic.

A differential transfer into an APFS clone stalled in macOS uninterruptible I/O;
the task-owned rsync and replacement scp did not exit after SIGKILL. Their old
`/private/tmp/margin-smoke-adapted-Q4_K_M.gguf` destination is left untouched.
The fresh non-cloned `margin-smoke-repaired-v2.gguf` SCP transfer works. Do not
reuse the blocked destination or infer a model failure from that host I/O incident.
