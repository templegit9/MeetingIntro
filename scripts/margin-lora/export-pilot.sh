set -euo pipefail
export PATH=/home/oluyi/.venvs/margin-empero-lora/bin:$PATH
cd /mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA
python -u scripts/export_preflight.py --root "$PWD" --phase pilot
python -u scripts/verify_merge.py --root "$PWD" --phase pilot
python -u scripts/convert_exports.py --root "$PWD" --phase pilot --adapted-only
