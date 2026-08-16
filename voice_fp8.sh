#!/usr/bin/env bash
set -Eeuo pipefail

# Fish Audio S2 Pro FP8 provisioning for Vast.ai / AI-Dock ComfyUI

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"

NODE_DIR="${COMFYUI_DIR}/custom_nodes/ComfyUI-FishAudioS2"
MODEL_ROOT="${COMFYUI_DIR}/models/fishaudioS2"
MODEL_DIR="${MODEL_ROOT}/s2-pro-fp8"

NODE_REPO="https://github.com/Saganaki22/ComfyUI-FishAudioS2.git"

log() {
    echo
    echo "============================================================"
    echo "[voice-fp8] $*"
    echo "============================================================"
}

die() {
    echo "[voice-fp8] ERROR: $*" >&2
    exit 1
}

log "Checking AI-Dock / ComfyUI paths"

[[ -d "${COMFYUI_DIR}" ]] || die "ComfyUI directory not found: ${COMFYUI_DIR}"
[[ -x "${PYTHON_BIN}" ]] || die "Python not found/executable: ${PYTHON_BIN}"

echo "[voice-fp8] ComfyUI: ${COMFYUI_DIR}"
echo "[voice-fp8] Python : ${PYTHON_BIN}"
"${PYTHON_BIN}" --version

mkdir -p "${COMFYUI_DIR}/custom_nodes"
mkdir -p "${MODEL_ROOT}"

log "Installing/updating ComfyUI-FishAudioS2"

if [[ -d "${NODE_DIR}/.git" ]]; then
    git -C "${NODE_DIR}" fetch --depth 1 origin main
    git -C "${NODE_DIR}" reset --hard origin/main
else
    rm -rf "${NODE_DIR}"
    git clone --depth 1 "${NODE_REPO}" "${NODE_DIR}"
fi

# fish-speech itself is bundled in this node. Do not pip-install fish-speech.
"${PYTHON_BIN}" -m pip install -U pip
"${PYTHON_BIN}" -m pip install -r "${NODE_DIR}/requirements.txt"

# Install these without deps to avoid their protobuf<5 constraint breaking ComfyUI.
"${PYTHON_BIN}" -m pip install --no-deps "descript-audio-codec==1.0.0"
"${PYTHON_BIN}" -m pip install --no-deps "descript-audiotools>=0.7.2"

log "Downloading Fish S2 Pro FP8 model"

"${PYTHON_BIN}" -m pip install -U huggingface_hub

export MODEL_DIR
"${PYTHON_BIN}" - <<'PY'
import os
from huggingface_hub import snapshot_download

model_dir = os.environ["MODEL_DIR"]
token = os.environ.get("HF_TOKEN") or None

print("[voice-fp8] Hugging Face repo : drbaph/s2-pro-fp8")
print(f"[voice-fp8] Destination       : {model_dir}")

snapshot_download(
    repo_id="drbaph/s2-pro-fp8",
    local_dir=model_dir,
    token=token,
)

print("[voice-fp8] FP8 model download complete.")
PY

[[ -f "${MODEL_DIR}/model.safetensors" ]] || die "model.safetensors missing after download"
[[ -f "${MODEL_DIR}/codec.pth" ]] || die "codec.pth missing after download"

echo "[voice-fp8] model.safetensors: OK"
echo "[voice-fp8] codec.pth        : OK"

log "Applying FishAudioS2 libffi compatibility workaround"

GLSL_FILE="${COMFYUI_DIR}/comfy_extras/nodes_glsl.py"

if [[ -f "${GLSL_FILE}" ]]; then
    if grep -Eq '^[[:space:]]*_preload_angle\(\)[[:space:]]*$' "${GLSL_FILE}"; then
        cp -n "${GLSL_FILE}" "${GLSL_FILE}.voice_fp8_backup" || true

        sed -i -E \
            's/^([[:space:]]*)_preload_angle\(\)[[:space:]]*$/\1# _preload_angle()  # disabled: comfy-angle\/libffi conflict with FishAudioS2/' \
            "${GLSL_FILE}"

        echo "[voice-fp8] Disabled bare _preload_angle() call in nodes_glsl.py"
    else
        echo "[voice-fp8] No bare _preload_angle() call found; patch not needed/already applied."
    fi
else
    echo "[voice-fp8] nodes_glsl.py not found; skipping libffi workaround."
fi

log "Verifying Python dependencies"

"${PYTHON_BIN}" - <<'PY'
mods = [
    "torch",
    "transformers",
    "soundfile",
    "librosa",
    "dac",
    "audiotools",
    "huggingface_hub",
]

failed = []
for name in mods:
    try:
        mod = __import__(name)
        ver = getattr(mod, "__version__", "")
        print(f"[voice-fp8] OK   {name} {ver}".rstrip())
    except Exception as e:
        failed.append((name, repr(e)))
        print(f"[voice-fp8] FAIL {name}: {e}")

if failed:
    raise SystemExit("Dependency verification failed.")
PY

log "Restarting ComfyUI if available"

if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl restart comfyui || true
else
    echo "[voice-fp8] supervisorctl not available yet; ComfyUI will load FishAudioS2 on normal startup."
fi

log "DONE"
echo "[voice-fp8] Node : ${NODE_DIR}"
echo "[voice-fp8] Model: ${MODEL_DIR}"
echo "[voice-fp8] In ComfyUI select model: s2-pro-fp8"
