#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAVEN_LOCAL_REPO="${ROOT_DIR}/.m2/repository"
MVN_COMMON_ARGS=(-Dmaven.repo.local="${MAVEN_LOCAL_REPO}")
export MAVEN_USER_HOME="${ROOT_DIR}/.m2"

ENGINE_DIR="${ROOT_DIR}/OpenBimRL-Engine"
REST_DIR="${ROOT_DIR}/OpenBimRL-Engine-REST"
WEBAPP_DIR="${ROOT_DIR}/OpenBimRL-CreatorTool/webapp"
OPENBIMRL_ENABLE_ROCM_OFFLOAD="OFF"
OPENBIMRL_ROCM_OFFLOAD_ARCH=""
CLEAN_CACHE="OFF"

print_usage() {
  cat <<'EOF'
Usage: ./scripts/dev-start.sh [--gpu] [--gpu-arch <gfx-arch>] [--clean]

Options:
  --gpu                    Enable ROCm OpenMP offloading for the Engine build.
  --gpu-arch <gfx-arch>    Set explicit ROCm offload arch (e.g. gfx1100).
  --clean                  Remove local build/dependency caches before startup.
  -h, --help               Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu)
      OPENBIMRL_ENABLE_ROCM_OFFLOAD="ON"
      shift
      ;;
    --gpu-arch)
      if [[ $# -lt 2 ]]; then
        echo "Error: --gpu-arch requires a value."
        print_usage
        exit 1
      fi
      OPENBIMRL_ENABLE_ROCM_OFFLOAD="ON"
      OPENBIMRL_ROCM_OFFLOAD_ARCH="$2"
      shift 2
      ;;
    --clean)
      CLEAN_CACHE="ON"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'"
      print_usage
      exit 1
      ;;
  esac
done

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}"
    echo "Rebuild the dev image: docker compose -f docker-compose.dev.yml up --build -d"
    exit 1
  fi
}

mvn_local() {
  mvn "${MVN_COMMON_ARGS[@]}" "$@"
}

engine_version() {
  awk '
    /<artifactId>openbimrl-engine<\/artifactId>/ { in_dep=1; next }
    in_dep && /<version>/ {
      gsub(/.*<version>|<\/version>.*/, "", $0);
      print $0;
      exit
    }
  ' "${REST_DIR}/pom.xml"
}

engine_project_version() {
  awk '
    /<artifactId>openbimrl-engine<\/artifactId>/ { in_project=1; next }
    in_project && /<version>/ {
      gsub(/.*<version>|<\/version>.*/, "", $0);
      print $0;
      exit
    }
  ' "${ENGINE_DIR}/pom.xml"
}

ensure_rest_engine_version_alias() {
  local rest_version project_version jar_path
  rest_version="$(engine_version || true)"
  project_version="$(engine_project_version || true)"

  if [[ -z "${rest_version}" || -z "${project_version}" ]]; then
    return
  fi

  if [[ "${rest_version}" == "${project_version}" ]]; then
    return
  fi

  jar_path="${ENGINE_DIR}/target/openbimrl-engine-${project_version}-jar-with-dependencies.jar"
  if [[ ! -f "${jar_path}" ]]; then
    jar_path="${ENGINE_DIR}/target/openbimrl-engine-${project_version}.jar"
  fi
  if [[ -f "${jar_path}" ]]; then
    echo "Installing local alias openbimrl-engine:${rest_version} -> ${project_version}"
    mvn_local install:install-file \
      -Dfile="${jar_path}" \
      -DgroupId=inf.bi.rub.de \
      -DartifactId=openbimrl-engine \
      -Dversion="${rest_version}" \
      -Dpackaging=jar \
      -DgeneratePom=true
  fi
}

build_engine() {
  echo "Building OpenBIMRL Engine (includes native build) ..."
  (
    cd "${ENGINE_DIR}"
    export OPENBIMRL_ENABLE_ROCM_OFFLOAD
    export OPENBIMRL_ROCM_OFFLOAD_ARCH
    # Use one canonical Maven lifecycle invocation to avoid mixed execution modes
    # (e.g. direct default-cli goal + lifecycle compile), which can cause unstable
    # Kotlin/Java ordering in clean builds.
    mvn_local -f "${ENGINE_DIR}/pom.xml" install -DskipTests
  )
  ensure_rest_engine_version_alias
}

start_rest() {
  echo "Starting OpenBIMRL backend (Spring Boot dev mode) ..."
  (
    cd "${REST_DIR}"
    SPRING_PROFILES_ACTIVE=dev sh ./mvnw "${MVN_COMMON_ARGS[@]}" -s maven-settings.xml spring-boot:run
  ) &
  BACKEND_PID=$!
}

stop_rest() {
  if [[ -n "${BACKEND_PID:-}" ]] && kill -0 "${BACKEND_PID}" 2>/dev/null; then
    kill "${BACKEND_PID}" 2>/dev/null || true
    wait "${BACKEND_PID}" 2>/dev/null || true
  fi
}

restart_rest() {
  echo "Restarting OpenBIMRL backend to pick up updated engine ..."
  stop_rest
  start_rest
}

start_frontend() {
  echo "Starting OpenBIMRL creator webapp (Vite hot reload) ..."
  (
    cd "${WEBAPP_DIR}"
    mkdir -p node_modules
    if ! touch node_modules/.permcheck 2>/dev/null; then
      if command -v sudo >/dev/null 2>&1; then
        sudo chown -R "$(id -u)":"$(id -g)" node_modules
      fi
    fi
    rm -f node_modules/.permcheck 2>/dev/null || true
    npm install
    npm run dev -- --host 0.0.0.0 --port 8000 --strictPort
  ) &
  FRONTEND_PID=$!
}

watch_engine_and_reload_rest() {
  local rest_engine_version
  rest_engine_version="$(engine_version || true)"
  if [[ -n "${rest_engine_version}" ]]; then
    echo "REST currently depends on openbimrl-engine version: ${rest_engine_version}"
  else
    echo "Warning: could not read engine dependency version from REST pom.xml"
  fi

  while true; do
    inotifywait -r -e close_write,create,delete,move \
      --exclude '(^|/)(\.git|target|build|node_modules)(/|$)' \
      "${ENGINE_DIR}" >/dev/null
    echo "Detected Engine change. Rebuilding Engine ..."
    if build_engine; then
      restart_rest
    else
      echo "Engine build failed. REST was not restarted."
    fi
  done
}

cleanup() {
  if [[ -n "${WATCHER_PID:-}" ]]; then
    kill "${WATCHER_PID}" 2>/dev/null || true
  fi
  stop_rest
  if [[ -n "${FRONTEND_PID:-}" ]]; then
    kill "${FRONTEND_PID}" 2>/dev/null || true
    wait "${FRONTEND_PID}" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

require_command mvn
require_command inotifywait
require_command npm
require_command git

cleanup_stale_processes() {
  # Old runs can keep background processes alive in the same container.
  pkill -f 'spring-boot:run' 2>/dev/null || true
  pkill -f 'vite --host 0.0.0.0 --port 8000' 2>/dev/null || true
}

clean_all_cache() {
  echo "Cleaning local caches (Maven, build outputs, frontend cache) ..."
  rm -rf "${MAVEN_LOCAL_REPO}"
  rm -rf "${ENGINE_DIR}/target" "${ENGINE_DIR}/build"
  rm -rf "${REST_DIR}/target"
  rm -rf "${WEBAPP_DIR}/dist" "${WEBAPP_DIR}/node_modules/.vite"
}

ensure_engine_dependencies() {
  local tmp_dir
  local openbimrl_api_version="2023.07.1"
  local openbimrl_api_commit="83bd65f"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  mkdir -p "${MAVEN_LOCAL_REPO}"

  if ! mvn_local -q dependency:get -Dartifact=de.rub.bi.inf:BVH:1.0 >/dev/null 2>&1; then
    echo "Installing missing dependency: de.rub.bi.inf:BVH:1.0"
    git clone --quiet https://github.com/RUB-Informatik-im-Bauwesen/Maven-Bounding-Volume-Hierarchy.git "${tmp_dir}/bvh"
    (
      cd "${tmp_dir}/bvh"
      mvn_local install -DskipTests
    )
  fi

  if ! mvn_local -q dependency:get -Dartifact=inf.bi.rub.de:OpenBIMRL-API:${openbimrl_api_version} >/dev/null 2>&1; then
    echo "Installing missing dependency: inf.bi.rub.de:OpenBIMRL-API:${openbimrl_api_version} (commit ${openbimrl_api_commit})"
    git clone --quiet https://github.com/RUB-Informatik-im-Bauwesen/OpenBimRL.git "${tmp_dir}/api"
    (
      cd "${tmp_dir}/api"
      git checkout "${openbimrl_api_commit}"
      # Upstream mvn install runs jaxb2 against a broken schema include and fails on Linux.
      # The generated sources are already committed; compile and install them directly.
      mvn_local -Dproject.build.sourceEncoding=ISO-8859-1 \
        compiler:compile jar:jar install:install \
        -DgroupId=inf.bi.rub.de \
        -DartifactId=OpenBIMRL-API \
        -Dversion="${openbimrl_api_version}" \
        -Dpackaging=jar
    )
  fi
}

echo "Preparing Engine so REST gets local artifacts ..."
if [[ "${OPENBIMRL_ENABLE_ROCM_OFFLOAD}" == "ON" ]]; then
  if [[ -n "${OPENBIMRL_ROCM_OFFLOAD_ARCH}" ]]; then
    echo "GPU offloading enabled (arch=${OPENBIMRL_ROCM_OFFLOAD_ARCH})."
  else
    echo "GPU offloading enabled (arch will be auto-detected by Makefile)."
  fi
else
  echo "GPU offloading disabled (OpenMP uses CPU cores only)."
fi
cleanup_stale_processes
if [[ "${CLEAN_CACHE}" == "ON" ]]; then
  clean_all_cache
fi
ensure_engine_dependencies
build_engine

start_rest
start_frontend

echo "Watching Engine changes and auto-restarting REST ..."
watch_engine_and_reload_rest &
WATCHER_PID=$!

echo "Backend:  http://localhost:8080"
echo "Frontend: http://localhost:8000"
echo "Press Ctrl+C to stop all processes."

wait -n "${BACKEND_PID}" "${FRONTEND_PID}" "${WATCHER_PID}"
