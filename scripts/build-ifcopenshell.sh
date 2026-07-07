#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IFCOPENSHELL_GIT_TAG="${IFCOPENSHELL_GIT_TAG:-eafa158ca0cd5ba2ca22b5e588b0375cab2efbce}"
INSTALL_PREFIX="${OPENBIMRL_IFCOPENSHELL_BUILD_PREFIX:-${ROOT_DIR}/.cache/openbimrl/ifcopenshell}"
BUILD_DIR="${ROOT_DIR}/.cache/openbimrl/ifcopenshell-build"
SRC_DIR="${ROOT_DIR}/.cache/openbimrl/IfcOpenShell-src"
STAMP="${INSTALL_PREFIX}/.build-stamp"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

ifcopenshell_runtime_ok() {
  local kernel="${INSTALL_PREFIX}/lib/libgeometry_kernel_opencascade.so"
  [[ -f "${kernel}" ]] || return 1
  LD_LIBRARY_PATH="${INSTALL_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    python3 -c "import ctypes; ctypes.CDLL('${kernel}')" >/dev/null 2>&1
}

if [[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" == "${IFCOPENSHELL_GIT_TAG}" ]] && ifcopenshell_runtime_ok; then
  echo "IfcOpenShell ${IFCOPENSHELL_GIT_TAG} already built at ${INSTALL_PREFIX}"
  exit 0
fi

require_command git
require_command cmake
require_command ninja

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "Cloning IfcOpenShell ..."
  git clone --quiet https://github.com/IfcOpenShell/IfcOpenShell.git "${SRC_DIR}"
fi

(
  cd "${SRC_DIR}"
  git fetch --quiet origin "${IFCOPENSHELL_GIT_TAG}" 2>/dev/null || true
  git checkout --quiet "${IFCOPENSHELL_GIT_TAG}"
)

echo "Building IfcOpenShell ${IFCOPENSHELL_GIT_TAG} for this system into ${INSTALL_PREFIX} ..."
cmake -G Ninja -S "${SRC_DIR}/cmake" -B "${BUILD_DIR}" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOCC_INCLUDE_DIR=/usr/include/opencascade \
  -DOCC_LIBRARY_DIR=/usr/lib/x86_64-linux-gnu \
  -DBUILD_SHARED_LIBS=ON \
  -DSCHEMA_VERSIONS="2x3;4;4x3_add2" \
  -DBUILD_CONVERT=OFF \
  -DBUILD_IFCPYTHON=OFF \
  -DBUILD_GEOMSERVER=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_DOCUMENTATION=OFF \
  -DWITH_CGAL=OFF \
  -DCOLLADA_SUPPORT=OFF \
  -DHDF5_SUPPORT=OFF \
  -DGLTF_SUPPORT=OFF \
  -DIFCXML_SUPPORT=OFF \
  -DUSD_SUPPORT=OFF

cmake --build "${BUILD_DIR}" -j"$(nproc)"
cmake --install "${BUILD_DIR}"
echo "${IFCOPENSHELL_GIT_TAG}" > "${STAMP}"

if ! ifcopenshell_runtime_ok; then
  echo "IfcOpenShell build finished but runtime verification still failed."
  exit 1
fi

echo "IfcOpenShell installed to ${INSTALL_PREFIX}"
