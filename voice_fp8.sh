#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# 4-model TTS provisioning for Vast.ai / AI-Dock ComfyUI
#
# Models:
#   1. VoxCPM2
#   2. Chatterbox Multilingual V3
#   3. CosyVoice3 0.5B
#   4. IndexTTS-2.5
#
# Fish Audio S2 is removed.
# ============================================================

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"

CUSTOM_NODES_DIR="${COMFYUI_DIR}/custom_nodes"

# NOTE:
# TTS-Audio-Suite uses models/TTS/
# ComfyUI-VoxCPM2 uses models/tts/
# Linux is case-sensitive, so keep both exactly as written.
TTS_ROOT="${COMFYUI_DIR}/models/TTS"
LOWER_TTS_ROOT="${COMFYUI_DIR}/models/tts"

AUDIO_SUITE_DIR="${CUSTOM_NODES_DIR}/TTS-Audio-Suite"
VOX_NODE_DIR="${CUSTOM_NODES_DIR}/ComfyUI-VoxCPM2"

AUDIO_SUITE_REPO="https://github.com/diodiogod/TTS-Audio-Suite.git"
VOX_NODE_REPO="https://github.com/Saganaki22/ComfyUI-VoxCPM2.git"

# ------------------------------------------------------------
# Model directories
# ------------------------------------------------------------

VOX_MODEL_DIR="${LOWER_TTS_ROOT}/VoxCPM/VoxCPM2"

CHATTER_MODEL_DIR="${TTS_ROOT}/chatterbox_official_23lang/ChatterBox Official 23-Lang"

COSY_MODEL_DIR="${TTS_ROOT}/CosyVoice/Fun-CosyVoice3-0.5B"

INDEX_MODEL_DIR="${TTS_ROOT}/IndexTTS/IndexTTS-2.5"
INDEX_W2V_DIR="${TTS_ROOT}/IndexTTS/w2v-bert-2.0"


log() {
    echo
    echo "============================================================"
    echo "[tts4] $*"
    echo "============================================================"
}


die() {
    echo "[tts4] ERROR: $*" >&2
    exit 1
}


update_repo() {
    local repo="$1"
    local dir="$2"
    local branch="${3:-main}"

    if [[ -d "${dir}/.git" ]]; then
        git -C "${dir}" fetch --depth 1 origin "${branch}"
        git -C "${dir}" reset --hard "origin/${branch}"
    else
        rm -rf "${dir}"
        git clone \
            --depth 1 \
            --branch "${branch}" \
            "${repo}" \
            "${dir}"
    fi
}


# ============================================================
# Check environment
# ============================================================

log "Checking AI-Dock / ComfyUI paths"

[[ -d "${COMFYUI_DIR}" ]] \
    || die "ComfyUI directory not found: ${COMFYUI_DIR}"

[[ -x "${PYTHON_BIN}" ]] \
    || die "Python not found/executable: ${PYTHON_BIN}"

echo "[tts4] ComfyUI: ${COMFYUI_DIR}"
echo "[tts4] Python : ${PYTHON_BIN}"

"${PYTHON_BIN}" --version

mkdir -p \
    "${CUSTOM_NODES_DIR}" \
    "${TTS_ROOT}" \
    "${LOWER_TTS_ROOT}"


# ============================================================
# Remove Fish Audio S2
# ============================================================

log "Removing Fish Audio S2"

rm -rf \
    "${CUSTOM_NODES_DIR}/ComfyUI-FishAudioS2" \
    "${COMFYUI_DIR}/models/fishaudioS2" \
    "${TTS_ROOT}/fish_audio_s2_pro" \
    "${TTS_ROOT}/fish_audio_s2_pro_fp8"

echo "[tts4] Fish Audio S2 node/models removed."


# ------------------------------------------------------------
# Undo the exact Fish-specific GLSL workaround from old script
# ------------------------------------------------------------

GLSL_FILE="${COMFYUI_DIR}/comfy_extras/nodes_glsl.py"

if [[ -f "${GLSL_FILE}" ]] \
    && grep -q \
        'disabled: comfy-angle/libffi conflict with FishAudioS2' \
        "${GLSL_FILE}"
then
    sed -i -E \
        's/^([[:space:]]*)#[[:space:]]*_preload_angle\(\)[[:space:]]*#[[:space:]]*disabled: comfy-angle\/libffi conflict with FishAudioS2[[:space:]]*$/\1_preload_angle()/' \
        "${GLSL_FILE}"

    echo "[tts4] Restored _preload_angle() disabled by old Fish script."
else
    echo "[tts4] No Fish-specific GLSL patch found."
fi


# ============================================================
# Install / update TTS Audio Suite
#
# Handles:
#   - Chatterbox Multilingual V3
#   - CosyVoice3
#   - IndexTTS-2.5
# ============================================================

log "Installing/updating TTS Audio Suite"

update_repo \
    "${AUDIO_SUITE_REPO}" \
    "${AUDIO_SUITE_DIR}" \
    main

"${PYTHON_BIN}" -m pip install -U \
    pip \
    setuptools \
    wheel

(
    cd "${AUDIO_SUITE_DIR}"
    "${PYTHON_BIN}" install.py
)


# ============================================================
# Install / update VoxCPM2 ComfyUI node
# ============================================================

log "Installing/updating ComfyUI-VoxCPM2"

update_repo \
    "${VOX_NODE_REPO}" \
    "${VOX_NODE_DIR}" \
    main


# ------------------------------------------------------------
# IMPORTANT:
#
# ComfyUI-VoxCPM2 vendors the inference implementation itself.
#
# Do NOT install the standalone PyPI "voxcpm" dependency here.
# It can unnecessarily upgrade Gradio / huggingface_hub and
# other shared ComfyUI dependencies.
# ------------------------------------------------------------

VOX_REQ_TMP="$(mktemp)"

trap 'rm -f "${VOX_REQ_TMP}"' EXIT

grep -Ev \
    '^[[:space:]]*voxcpm([<>=!~[:space:]].*)?$' \
    "${VOX_NODE_DIR}/requirements.txt" \
    > "${VOX_REQ_TMP}"

"${PYTHON_BIN}" -m pip install \
    -r "${VOX_REQ_TMP}"


# ============================================================
# Download models
# ============================================================

log "Downloading 4 TTS model sets"

export \
    VOX_MODEL_DIR \
    CHATTER_MODEL_DIR \
    COSY_MODEL_DIR \
    INDEX_MODEL_DIR \
    INDEX_W2V_DIR


"${PYTHON_BIN}" - <<'PY'
import os

from huggingface_hub import snapshot_download


token = os.environ.get("HF_TOKEN") or None


def download(
    repo_id,
    local_dir,
    allow_patterns=None,
    ignore_patterns=None,
):
    os.makedirs(local_dir, exist_ok=True)

    print()
    print(f"[tts4] Hugging Face repo : {repo_id}")
    print(f"[tts4] Destination       : {local_dir}")

    snapshot_download(
        repo_id=repo_id,
        local_dir=local_dir,
        token=token,
        allow_patterns=allow_patterns,
        ignore_patterns=ignore_patterns,
    )

    print(f"[tts4] Download complete : {repo_id}")


# ============================================================
# 1. VoxCPM2
# ============================================================
#
# Official repo: ~4.96 GB
# Small enough that we just download the complete model repo.
#

download(
    "openbmb/VoxCPM2",
    os.environ["VOX_MODEL_DIR"],
)


# ============================================================
# 2. Chatterbox Multilingual V3
# ============================================================
#
# The complete Hugging Face repo contains:
#   - older versions
#   - multiple T3 checkpoints
#   - duplicate weight formats
#
# We only download V3 + common files needed for inference.
#

download(
    "ResembleAI/chatterbox",
    os.environ["CHATTER_MODEL_DIR"],
    allow_patterns=[
        "t3_mtl23ls_v3.safetensors",
        "s3gen.pt",
        "ve.pt",
        "grapheme_mtl_merged_expanded_v1.json",
        "mtl_tokenizer.json",
        "conds.pt",
        "Cangjie5_TC.json",
        "README.md",
    ],
)


# ============================================================
# 3. CosyVoice3 0.5B
# ============================================================
#
# Download normal 0.5B inference variant.
#
# Do NOT download:
#   llm.rl.pt
#   speech_tokenizer_v3.batch.onnx
#   flow.decoder.estimator.fp32.onnx
#
# Those are not needed for the standard inference variant here.
#

download(
    "FunAudioLLM/Fun-CosyVoice3-0.5B-2512",
    os.environ["COSY_MODEL_DIR"],
    allow_patterns=[
        "CosyVoice-BlankEN/**",
        "asset/**",

        "campplus.onnx",

        "config.json",
        "configuration.json",
        "cosyvoice3.yaml",

        "flow.pt",
        "hift.pt",
        "llm.pt",

        "speech_tokenizer_v3.onnx",

        "README.md",
    ],
)


# ============================================================
# 4. IndexTTS-2.5
# ============================================================

download(
    "IndexTeam/IndexTTS-2.5",
    os.environ["INDEX_MODEL_DIR"],
)


# ------------------------------------------------------------
# IndexTTS semantic feature model
#
# Pre-download it now instead of making the first generation
# wait for another ~2 GB model.
# ------------------------------------------------------------

download(
    "facebook/w2v-bert-2.0",
    os.environ["INDEX_W2V_DIR"],
)

PY


# ============================================================
# Verify downloaded model files
# ============================================================

log "Verifying model files"


check_file() {
    local file="$1"

    [[ -f "${file}" ]] \
        || die "Required model file missing: ${file}"

    echo "[tts4] OK  ${file}"
}


# ------------------------------------------------------------
# VoxCPM2
# ------------------------------------------------------------

check_file \
    "${VOX_MODEL_DIR}/model.safetensors"

check_file \
    "${VOX_MODEL_DIR}/audiovae.pth"


# ------------------------------------------------------------
# Chatterbox Multilingual V3
# ------------------------------------------------------------

check_file \
    "${CHATTER_MODEL_DIR}/t3_mtl23ls_v3.safetensors"

check_file \
    "${CHATTER_MODEL_DIR}/s3gen.pt"

check_file \
    "${CHATTER_MODEL_DIR}/ve.pt"

check_file \
    "${CHATTER_MODEL_DIR}/grapheme_mtl_merged_expanded_v1.json"


# ------------------------------------------------------------
# CosyVoice3
# ------------------------------------------------------------

check_file \
    "${COSY_MODEL_DIR}/llm.pt"

check_file \
    "${COSY_MODEL_DIR}/flow.pt"

check_file \
    "${COSY_MODEL_DIR}/hift.pt"

check_file \
    "${COSY_MODEL_DIR}/speech_tokenizer_v3.onnx"

check_file \
    "${COSY_MODEL_DIR}/cosyvoice3.yaml"


# ------------------------------------------------------------
# IndexTTS-2.5
# ------------------------------------------------------------

check_file \
    "${INDEX_MODEL_DIR}/gpt.pth"

check_file \
    "${INDEX_MODEL_DIR}/codec.pth"

check_file \
    "${INDEX_MODEL_DIR}/s2mel.pth"

check_file \
    "${INDEX_MODEL_DIR}/config.yaml"


# ============================================================
# Verify core Python environment
# ============================================================

log "Verifying core Python dependencies"


"${PYTHON_BIN}" - <<'PY'
mods = [
    "torch",
    "torchaudio",
    "transformers",
    "soundfile",
    "huggingface_hub",
]

failed = []

for name in mods:
    try:
        mod = __import__(name)
        version = getattr(mod, "__version__", "")

        print(
            f"[tts4] OK   {name} {version}".rstrip()
        )

    except Exception as exc:
        failed.append(
            (name, repr(exc))
        )

        print(
            f"[tts4] FAIL {name}: {exc}"
        )


if failed:
    raise SystemExit(
        "Core dependency verification failed."
    )
PY


# ============================================================
# Print actual disk usage
# ============================================================

log "Model disk usage"

du -sh \
    "${VOX_MODEL_DIR}" \
    "${CHATTER_MODEL_DIR}" \
    "${COSY_MODEL_DIR}" \
    "${INDEX_MODEL_DIR}" \
    "${INDEX_W2V_DIR}" \
    2>/dev/null || true


# ============================================================
# Restart ComfyUI
# ============================================================

log "Restarting ComfyUI if available"

if command -v supervisorctl >/dev/null 2>&1; then

    supervisorctl restart comfyui || true

else

    echo \
        "[tts4] supervisorctl not available yet; ComfyUI will load the nodes on normal startup."

fi


# ============================================================
# Done
# ============================================================

log "DONE"

echo "[tts4] TTS Audio Suite : ${AUDIO_SUITE_DIR}"
echo "[tts4] VoxCPM2 node    : ${VOX_NODE_DIR}"

echo
echo "[tts4] Models"

echo "[tts4] VoxCPM2:"
echo "       ${VOX_MODEL_DIR}"

echo "[tts4] Chatterbox V3:"
echo "       ${CHATTER_MODEL_DIR}"

echo "[tts4] CosyVoice3:"
echo "       ${COSY_MODEL_DIR}"

echo "[tts4] IndexTTS-2.5:"
echo "       ${INDEX_MODEL_DIR}"

echo "[tts4] Index w2v-bert:"
echo "       ${INDEX_W2V_DIR}"

echo
echo "[tts4] ComfyUI usage:"
echo "  - VoxCPM2:"
echo "      dedicated VoxCPM2 nodes under audio/tts"
echo
echo "  - Chatterbox V3:"
echo "      TTS Audio Suite -> ChatterBox Official 23-Lang -> V3"
echo
echo "  - CosyVoice3:"
echo "      TTS Audio Suite -> CosyVoice3"
echo
echo "  - IndexTTS-2.5:"
echo "      TTS Audio Suite -> IndexTTS -> 2.5"
