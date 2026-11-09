set -euo pipefail
export PATH=/home/oluyi/.venvs/margin-empero-lora/bin:/usr/local/cuda/bin:$PATH
export CUDA_HOME=/usr/local/cuda
cd /mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA
python scripts/monitor.py --root "$PWD" > logs/pilot-monitor.log 2>&1 &
margin_monitor_pid=$!
trap 'kill "$margin_monitor_pid" 2>/dev/null || true' EXIT
python -u scripts/train.py --root "$PWD" --mode pilot > logs/pilot.log 2>&1
