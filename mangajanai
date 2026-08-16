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
#   - All MangaJaNai / IllustrationJaNai models by extracting
#     them from the latest official Windows Portable release
#
# Main paths:
#   /workspace/MangaJaNai/repo
#   /workspace/MangaJaNai/venv
#   /workspace/MangaJaNai/input
#   /workspace/MangaJaNai/output
#
# Usage after provisioning:
#   /workspace/MangaJaNai/mangajanai.sh -h
#   /workspace/MangaJaNai/mangajanai.sh \
#       -d /workspace/MangaJaNai/input \
#       -o /workspace/MangaJaNai/output
# ============================================================

ROOT="${MANGAJANAI_ROOT:-/workspace/MangaJaNai}"
REPO_DIR="${ROOT}/repo"
VENV_DIR="${ROOT}/venv"
INPUT_DIR="${ROOT}/input"
OUTPUT_DIR="${ROOT}/output"

REPO_URL="https://github.com/the-database/MangaJaNaiConverterGui.git"
BACKEND_SRC="${REPO_DIR}/MangaJaNaiConverterGui/backend/src"
MODELS_DIR="${REPO_DIR}/MangaJaNaiConverterGui/backend/models"

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
        git curl ca-certificates unzip p7zip-full \
        python3 python3-venv \
        libgl1 libglib2.0-0
    rm -rf /var/lib/apt/lists/*
else
    echo "[MangaJaNai] apt-get not found; assuming required system packages already exist."
fi

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

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

mkdir -p "${ROOT}" "${INPUT_DIR}" "${OUTPUT_DIR}"

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
#
# Current MangaJaNai backend pins:
#   torch==2.9.1
#   torchvision==0.24.1
#
# The repo's old [tool.uv.pip] cu121 URL is stale for current
# PyTorch 2.9.1, so install the official CUDA 12.8 wheels first.
# ------------------------------------------------------------
log "Installing PyTorch 2.9.1 + CUDA 12.8"

"${PIP}" install --no-cache-dir \
    torch==2.9.1 \
    torchvision==0.24.1 \
    --index-url https://download.pytorch.org/whl/cu128

# ------------------------------------------------------------
# 4. Install the backend package and its non-Torch dependencies
#
# These versions mirror the current official pyproject.toml.
# We install them explicitly so pip cannot replace CUDA Torch
# with a CPU build during dependency resolution.
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
# 5. Download all current official models
#
# Official Linux docs say the CLI expects all models in:
#   MangaJaNaiConverterGui/backend/models
#
# The official release bundles them, so fetch the latest Portable
# ZIP and extract only its backend/models tree.
# ------------------------------------------------------------
log "Downloading latest official MangaJaNai model bundle"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

export TMP_DIR
ASSET_INFO="$("${PY}" - <<'PY'
import json
import urllib.request

api = "https://api.github.com/repos/the-database/MangaJaNaiConverterGui/releases/latest"
req = urllib.request.Request(
    api,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "MangaJaNai-Vast-Provisioner",
    },
)

with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)

portable = ""
setup = ""

for a in data.get("assets", []):
    name = (a.get("name") or "")
    low = name.lower()
    url = a.get("browser_download_url") or ""

    if "portable" in low and low.endswith(".zip") and not portable:
        portable = url

    if low.endswith(".exe") and ("setup" in low or "installer" in low) and not setup:
        setup = url

print(data.get("tag_name", "unknown"))
print(portable)
print(setup)
PY
)" || die "Failed to discover latest release assets"

LATEST_TAG="$(printf '%s\n' "${ASSET_INFO}" | sed -n '1p')"
PORTABLE_URL="$(printf '%s\n' "${ASSET_INFO}" | sed -n '2p')"
SETUP_URL="$(printf '%s\n' "${ASSET_INFO}" | sed -n '3p')"

echo "[MangaJaNai] Latest release: ${LATEST_TAG}"
echo "[MangaJaNai] Portable URL : ${PORTABLE_URL:-not found}"
echo "[MangaJaNai] Setup URL    : ${SETUP_URL:-not found}"

find_and_copy_models() {
    local search_root="$1"

    export SEARCH_ROOT="${search_root}"
    export MODELS_DIR

    "${PY}" - <<'PY'
import os
import shutil
from pathlib import Path

root = Path(os.environ["SEARCH_ROOT"])
dst = Path(os.environ["MODELS_DIR"])

candidates = []

for p in root.rglob("models"):
    if not p.is_dir():
        continue

    # Prefer the official backend/models layout.
    if p.parent.name == "backend":
        candidates.append(p)

# Fallback: any model-looking directory containing common weights.
if not candidates:
    for p in root.rglob("models"):
        if not p.is_dir():
            continue
        model_files = [
            q for q in p.rglob("*")
            if q.is_file() and q.suffix.lower() in {".pth", ".pt", ".safetensors", ".onnx"}
        ]
        if model_files:
            candidates.append(p)

if not candidates:
    raise SystemExit(2)

def file_count(path):
    return sum(1 for q in path.rglob("*") if q.is_file())

src = max(candidates, key=file_count)
print(f"[MangaJaNai] Found bundled models at: {src}")

if dst.exists():
    shutil.rmtree(dst)

dst.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(src, dst)

files = [q for q in dst.rglob("*") if q.is_file()]
print(f"[MangaJaNai] Copied {len(files)} files")

if not files:
    raise SystemExit(3)
PY
}

MODELS_FOUND=0

# First try the Portable ZIP (simplest archive to extract).
if [[ -n "${PORTABLE_URL}" ]]; then
    log "Trying latest Portable ZIP for bundled models"

    if curl -fL \
        --retry 5 \
        --retry-delay 3 \
        --connect-timeout 30 \
        -o "${TMP_DIR}/portable.zip" \
        "${PORTABLE_URL}"; then

        mkdir -p "${TMP_DIR}/portable"
        if unzip -q "${TMP_DIR}/portable.zip" -d "${TMP_DIR}/portable"; then
            if find_and_copy_models "${TMP_DIR}/portable"; then
                MODELS_FOUND=1
            fi
        fi
    fi
fi

# Official Linux README explicitly says models can be extracted from
# the release .exe, so use the Setup EXE as a fallback.
if [[ "${MODELS_FOUND}" -ne 1 && -n "${SETUP_URL}" ]]; then
    log "Portable archive did not expose models; trying official Setup EXE"

    curl -fL \
        --retry 5 \
        --retry-delay 3 \
        --connect-timeout 30 \
        -o "${TMP_DIR}/setup.exe" \
        "${SETUP_URL}"

    mkdir -p "${TMP_DIR}/setup_extracted"
    7z x -y \
        -o"${TMP_DIR}/setup_extracted" \
        "${TMP_DIR}/setup.exe" >/dev/null

    if find_and_copy_models "${TMP_DIR}/setup_extracted"; then
        MODELS_FOUND=1
    fi
fi

[[ "${MODELS_FOUND}" -eq 1 ]] || die \
    "Could not extract MangaJaNai models from the latest official release assets"

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

MODEL_COUNT="$(find "${MODELS_DIR}" -type f | wc -l | tr -d ' ')"

log "DONE"

echo "[MangaJaNai] Root       : ${ROOT}"
echo "[MangaJaNai] Backend    : ${BACKEND_SRC}"
echo "[MangaJaNai] Models     : ${MODELS_DIR}"
echo "[MangaJaNai] Model files: ${MODEL_COUNT}"
echo "[MangaJaNai] Input      : ${INPUT_DIR}"
echo "[MangaJaNai] Output     : ${OUTPUT_DIR}"
echo
echo "Example:"
echo "  ${ROOT}/mangajanai.sh -d ${INPUT_DIR} -o ${OUTPUT_DIR}"
