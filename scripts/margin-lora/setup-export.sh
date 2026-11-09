set -euo pipefail
export PATH=/home/oluyi/.venvs/margin-empero-lora/bin:$PATH
cd /mnt/c/Users/oluyi/Documents/Projects/Margin-Empero-LoRA
/home/oluyi/.local/bin/uv pip install --python /home/oluyi/.venvs/margin-empero-lora/bin/python cmake ninja gguf sentencepiece
if [ ! -d tools/llama.cpp ]; then
 mkdir -p tools
 git clone --depth 1 https://github.com/ggml-org/llama.cpp tools/llama.cpp
fi
git -C tools/llama.cpp rev-parse HEAD > artifacts/llama-cpp-revision.txt
cmake -S tools/llama.cpp -B tools/llama.cpp/build -G Ninja -DGGML_CUDA=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF
cmake --build tools/llama.cpp/build --target llama-quantize -j 4
