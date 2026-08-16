#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# MangaJaNai provisioning for Vast.ai (Linux / NVIDIA)
#
# Installs:
#   - MangaJaNaiConverterGui source (CLI backend)
#   - Separate Python venv
#   - PyTorch 2.9.1 + TorchVision 0.24.1 (CUDA 12.8 wheels)
#   - Current backend dependencies
#   - Official MangaJaNai V1 manga models directly from the
#     official MangaJaNai model release
#   - IllustrationJaNai V1 models by default (optional)
#
# Main paths:
#   /workspace/MangaJaNai/repo
#   /workspace/MangaJaNai/venv
#   /workspace/MangaJaNai/input
#   /workspace/MangaJaNai/output
#   /workspace/MangaJaNai/downloads
#
# Usage after provisioning:
#   /workspace/MangaJaNai/mangajanai.sh -h
#   /workspace/MangaJaNai/mangajanai.sh \
#       -d /workspace/MangaJaNai/input \
#       -o /workspace/MangaJaNai/output
#
# Set MANGAJANAI_INCLUDE_ILLUSTRATION=0 to skip the extra
# IllustrationJaNai V1 model archive.
# ============================================================

ROOT="${MANGAJANAI_ROOT:-/workspace/MangaJaNai}"
REPO_DIR="${ROOT}/repo"
VENV_DIR="${ROOT}/venv"
INPUT_DIR="${ROOT}/input"
OUTPUT_DIR="${ROOT}/output"
DOWNLOAD_DIR="${ROOT}/downloads"

REPO_URL="https://github.com/the-database/MangaJaNaiConverterGui.git"
BACKEND_SRC="${REPO_DIR}/MangaJaNaiConverterGui/backend/src"
MODELS_DIR="${REPO_DIR}/MangaJaNaiConverterGui/backend/models"

MANGAJANAI_INCLUDE_ILLUSTRATION="${MANGAJANAI_INCLUDE_ILLUSTRATION:-1}"

MANGA_MODELS_URL="https://github.com/the-database/MangaJaNai/releases/download/1.0.0/MangaJaNai_V1_ModelsOnly.zip"
ILLUSTRATION_MODELS_URL="https://github.com/the-database/MangaJaNai/releases/download/1.0.0/IllustrationJaNai_V1_ModelsOnly.zip"

log() {
    echo
    echo "============================================================"
    echo "[MangaJaNai] $*"
    echo "============================================================"
}

die() {
    echo "[MangaJaNai] ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# 0. System packages
# ------------------------------------------------------------
log "Installing system packages"

export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends \
        git curl ca-certificates unzip \
        python3 python3-venv \
        libgl1 libglib2.0-0
    rm -rf /var/lib/apt/lists/*
else
    echo "[MangaJaNai] apt-get not found; assuming required system packages already exist."
fi

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"
command -v unzip >/dev/null 2>&1 || die "unzip is not installed"

# Prefer AI-Dock's Python when present; otherwise use the template's python3.
if [[ -x "/venv/main/bin/python" ]]; then
    BASE_PYTHON="/venv/main/bin/python"
elif command -v python3.13 >/dev/null 2>&1; then
    BASE_PYTHON="$(command -v python3.13)"
elif command -v python3.12 >/dev/null 2>&1; then
    BASE_PYTHON="$(command -v python3.12)"
elif command -v python3 >/dev/null 2>&1; then
    BASE_PYTHON="$(command -v python3)"
else
    die "No usable Python interpreter found"
fi

echo "[MangaJaNai] Base Python: ${BASE_PYTHON}"
"${BASE_PYTHON}" --version

mkdir -p \
    "${ROOT}" \
    "${INPUT_DIR}" \
    "${OUTPUT_DIR}" \
    "${DOWNLOAD_DIR}"

# ------------------------------------------------------------
# 1. Clone/update official MangaJaNaiConverterGui
# ------------------------------------------------------------
log "Cloning/updating official MangaJaNaiConverterGui"

if [[ -d "${REPO_DIR}/.git" ]]; then
    git -C "${REPO_DIR}" fetch --depth 1 origin main
    git -C "${REPO_DIR}" reset --hard origin/main
else
    rm -rf "${REPO_DIR}"
    git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
fi

[[ -d "${BACKEND_SRC}" ]] || die "Backend source not found: ${BACKEND_SRC}"

# ------------------------------------------------------------
# 2. Create isolated Python environment
# ------------------------------------------------------------
log "Creating isolated Python venv"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    rm -rf "${VENV_DIR}"
    "${BASE_PYTHON}" -m venv "${VENV_DIR}"
fi

PY="${VENV_DIR}/bin/python"
PIP="${VENV_DIR}/bin/pip"

"${PY}" -m pip install -U pip setuptools wheel

echo "[MangaJaNai] Python: $("${PY}" --version 2>&1)"

# ------------------------------------------------------------
# 3. Install CUDA PyTorch explicitly
# ------------------------------------------------------------
log "Installing PyTorch 2.9.1 + CUDA 12.8"

"${PIP}" install --no-cache-dir \
    torch==2.9.1 \
    torchvision==0.24.1 \
    --index-url https://download.pytorch.org/whl/cu128

# ------------------------------------------------------------
# 4. Install the backend package and its non-Torch dependencies
# ------------------------------------------------------------
log "Installing MangaJaNai backend dependencies"

"${PIP}" install --no-cache-dir \
    chainner_ext==0.3.10 \
    numpy==2.2.5 \
    opencv-python==4.11.0.86 \
    packaging==25.0 \
    psutil==6.0.0 \
    pynvml==11.5.3 \
    pyvips==3.0.0 \
    pyvips-binary==8.16.1 \
    rarfile==4.2 \
    sanic==24.6.0 \
    spandrel_extra_arches==0.2.0 \
    spandrel==0.4.1

"${PIP}" install --no-deps "${BACKEND_SRC}"

# ------------------------------------------------------------
# 5. Download official model archives DIRECTLY
#
# IMPORTANT:
# Do NOT try to extract models from the Windows GUI Portable ZIP
# or Setup EXE. The actual official model release already provides
# dedicated ModelsOnly archives.
#
# Official CLI docs expect MangaJaNai models in:
#   MangaJaNaiConverterGui/backend/models
# ------------------------------------------------------------
log "Downloading official MangaJaNai models"

mkdir -p "${MODELS_DIR}" "${DOWNLOAD_DIR}"

MANGA_ZIP="${DOWNLOAD_DIR}/MangaJaNai_V1_ModelsOnly.zip"
ILLUSTRATION_ZIP="${DOWNLOAD_DIR}/IllustrationJaNai_V1_ModelsOnly.zip"

download_zip() {
    local url="$1"
    local dest="$2"
    local label="$3"

    if [[ -s "${dest}" ]] && unzip -tq "${dest}" >/dev/null 2>&1; then
        echo "[MangaJaNai] Reusing cached ${label}: ${dest}"
        return 0
    fi

    rm -f "${dest}"

    echo "[MangaJaNai] Downloading ${label}"
    echo "[MangaJaNai] URL: ${url}"

    curl -fL \
        --retry 8 \
        --retry-delay 3 \
        --retry-all-errors \
        --connect-timeout 30 \
        --speed-time 60 \
        --speed-limit 1024 \
        -o "${dest}.part" \
        "${url}"

    mv -f "${dest}.part" "${dest}"

    unzip -tq "${dest}" >/dev/null 2>&1 || {
        rm -f "${dest}"
        die "Downloaded archive is corrupt: ${label}"
    }
}

extract_model_archive() {
    local archive="$1"
    local label="$2"
    local tmp_extract

    tmp_extract="$(mktemp -d)"

    echo "[MangaJaNai] Extracting ${label}"
    unzip -q -o "${archive}" -d "${tmp_extract}"

    local copied=0
    while IFS= read -r -d '' model_file; do
        cp -f "${model_file}" "${MODELS_DIR}/$(basename "${model_file}")"
        ((copied += 1))
    done < <(
        find "${tmp_extract}" -type f \
            \( -iname '*.pth' -o -iname '*.pt' -o -iname '*.safetensors' -o -iname '*.onnx' \) \
            -print0
    )

    rm -rf "${tmp_extract}"

    if [[ "${copied}" -eq 0 ]]; then
        die "No model files found inside ${label}"
    fi

    echo "[MangaJaNai] Copied ${copied} model file(s) from ${label}"
}

download_zip \
    "${MANGA_MODELS_URL}" \
    "${MANGA_ZIP}" \
    "MangaJaNai V1 manga model archive"

extract_model_archive \
    "${MANGA_ZIP}" \
    "MangaJaNai V1 manga model archive"

if [[ "${MANGAJANAI_INCLUDE_ILLUSTRATION}" == "1" ]]; then
    download_zip \
        "${ILLUSTRATION_MODELS_URL}" \
        "${ILLUSTRATION_ZIP}" \
        "IllustrationJaNai V1 model archive"

    extract_model_archive \
        "${ILLUSTRATION_ZIP}" \
        "IllustrationJaNai V1 model archive"
else
    echo "[MangaJaNai] Skipping IllustrationJaNai models (MANGAJANAI_INCLUDE_ILLUSTRATION=${MANGAJANAI_INCLUDE_ILLUSTRATION})"
fi

# The official MangaJaNai V1 release has seven target-height models
# for 2x and another seven for 4x. Verify all 14 explicitly so that
# provisioning cannot silently succeed with an incomplete model set.
EXPECTED_MANGA_MODELS=(
    "2x_MangaJaNai_1200p_V1_ESRGAN_70k.pth"
    "2x_MangaJaNai_1300p_V1_ESRGAN_75k.pth"
    "2x_MangaJaNai_1400p_V1_ESRGAN_70k.pth"
    "2x_MangaJaNai_1500p_V1_ESRGAN_90k.pth"
    "2x_MangaJaNai_1600p_V1_ESRGAN_90k.pth"
    "2x_MangaJaNai_1920p_V1_ESRGAN_70k.pth"
    "2x_MangaJaNai_2048p_V1_ESRGAN_95k.pth"
    "4x_MangaJaNai_1200p_V1_ESRGAN_70k.pth"
    "4x_MangaJaNai_1300p_V1_ESRGAN_75k.pth"
    "4x_MangaJaNai_1400p_V1_ESRGAN_105k.pth"
    "4x_MangaJaNai_1500p_V1_ESRGAN_105k.pth"
    "4x_MangaJaNai_1600p_V1_ESRGAN_70k.pth"
    "4x_MangaJaNai_1920p_V1_ESRGAN_105k.pth"
    "4x_MangaJaNai_2048p_V1_ESRGAN_70k.pth"
)

MISSING_MODELS=0
for model_name in "${EXPECTED_MANGA_MODELS[@]}"; do
    if [[ ! -s "${MODELS_DIR}/${model_name}" ]]; then
        echo "[MangaJaNai] MISSING: ${model_name}" >&2
        MISSING_MODELS=1
    fi
done

[[ "${MISSING_MODELS}" -eq 0 ]] || die \
    "MangaJaNai model installation is incomplete"

echo "[MangaJaNai] Verified all 14 official MangaJaNai V1 manga models."

if [[ "${MANGAJANAI_INCLUDE_ILLUSTRATION}" == "1" ]]; then
    for model_name in \
        "4x_IllustrationJaNai_V1_ESRGAN_135k.pth" \
        "4x_IllustrationJaNai_V1_DAT2_190k.pth"
    do
        [[ -s "${MODELS_DIR}/${model_name}" ]] || die \
            "IllustrationJaNai model missing after extraction: ${model_name}"
    done
    echo "[MangaJaNai] Verified IllustrationJaNai V1 models."
fi

# ------------------------------------------------------------
# 6. Create simple launcher
# ------------------------------------------------------------
log "Creating launcher"

cat > "${ROOT}/mangajanai.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${BACKEND_SRC}"
exec "${PY}" run_upscale.py "\$@"
EOF

chmod +x "${ROOT}/mangajanai.sh"

# Optional environment helper for Jupyter terminals.
cat > "${ROOT}/activate.sh" <<EOF
#!/usr/bin/env bash
source "${VENV_DIR}/bin/activate"
cd "${BACKEND_SRC}"
echo "MangaJaNai environment activated."
echo "Input : ${INPUT_DIR}"
echo "Output: ${OUTPUT_DIR}"
echo "Help  : ${ROOT}/mangajanai.sh -h"
EOF

chmod +x "${ROOT}/activate.sh"

# ------------------------------------------------------------
# 7. Verify GPU / imports / CLI
# ------------------------------------------------------------
log "Verifying installation"

"${PY}" - <<'PY'
import torch
import torchvision

print("[MangaJaNai] torch      :", torch.__version__)
print("[MangaJaNai] torchvision:", torchvision.__version__)
print("[MangaJaNai] CUDA build :", torch.version.cuda)
print("[MangaJaNai] CUDA ready :", torch.cuda.is_available())

if torch.cuda.is_available():
    print("[MangaJaNai] GPU        :", torch.cuda.get_device_name(0))
else:
    print("[MangaJaNai] WARNING: CUDA is not currently available.")
PY

"${ROOT}/mangajanai.sh" -h >/dev/null

MODEL_COUNT="$(
    find "${MODELS_DIR}" -maxdepth 1 -type f \
        \( -iname '*.pth' -o -iname '*.pt' -o -iname '*.safetensors' -o -iname '*.onnx' \) \
        | wc -l | tr -d ' '
)"

log "DONE"
echo "[MangaJaNai] Root       : ${ROOT}"
echo "[MangaJaNai] Backend    : ${BACKEND_SRC}"
echo "[MangaJaNai] Models     : ${MODELS_DIR}"
echo "[MangaJaNai] Model files: ${MODEL_COUNT}"
echo "[MangaJaNai] Input      : ${INPUT_DIR}"
echo "[MangaJaNai] Output     : ${OUTPUT_DIR}"
echo "[MangaJaNai] Downloads  : ${DOWNLOAD_DIR}"
echo
echo "Example:"
echo "  ${ROOT}/mangajanai.sh -d ${INPUT_DIR} -o ${OUTPUT_DIR}"
