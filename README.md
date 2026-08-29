# OpenBimRL monorepo

Bazel workspace for Engine (JNI + Kotlin), Engine-REST (Spring Boot), and CreatorTool webapp (Vue/Vite).

## Structure

| Path | Role |
|------|------|
| `OpenBimRL-Engine/` | Standalone Bazel module — Kotlin/JVM rule engine + JNI native (`libopenbimrl_jni.so`) |
| `OpenBimRL-Engine-REST/` | Standalone Bazel module — Spring Boot REST API; from this root uses local Engine via `local_path_override` |
| `OpenBimRL-CreatorTool/webapp/` | Vue/Vite UI — built with `aspect_rules_js` + pnpm |

Root `MODULE.bazel` wires Engine, REST, and native with `local_path_override`. Root `BUILD.bazel` exposes short aliases (`//:engine`, `//:rest`, `//:webapp_*`).

## Prerequisites

- **Bazelisk / Bazel 9.2.0** (pinned in `.bazelversion` at root, Engine, and REST)
- **Java 21** runtime (sources compile to Java 17 bytecode for Engine; REST uses JVM 21)
- **Node 20** + **pnpm 9** — provided by the root Bazel toolchain for webapp builds; use local pnpm only to refresh `pnpm-lock.yaml`
- **IfcOpenShell** at `/opt/ifcopenshell` (DevContainer default) — set `OPENBIMRL_IFCOPENSHELL_PREFIX` if elsewhere
- For native Engine/REST **runs**: `LD_LIBRARY_PATH=/opt/ifcopenshell/lib` (shared IfcOpenShell/OCCT)
- **Standalone REST only**: GitHub Packages auth via `~/.netrc` (see [Standalone modules](#standalone-modules))

## Common commands (workspace root)

From `/workspace/openbimrl` (or the repo root):

```bash
# Smoke / docs target
bazel build //:help

# Engine library (Kotlin + embedded JNI .so)
bazel build //:engine

# CreatorTool webapp
bazel build //:webapp_build
bazel run //:webapp_dev          # Vite on 0.0.0.0:8000

# REST (Kotlin 21 toolchain — always pass --config=rest from root)
bazel build //:rest --config=rest
bazel build //:rest_deploy.jar --config=rest

LD_LIBRARY_PATH=/opt/ifcopenshell/lib \
  bazel run //:rest --config=rest -- --spring.profiles.active=dev

# REST with ROCm-offload native build (gpu fields on /status come from the embedded .so)
OPENBIMRL_ROCM_OFFLOAD_ARCH=gfx1100 \
LD_LIBRARY_PATH=/opt/ifcopenshell/lib \
  bazel run //:rest --config=rest --config=rocm_offload -- --spring.profiles.active=dev

# Engine tests (via Engine module labels)
bazel test @openbimrl_engine//:engine_unit_tests   # fast JVM-only
bazel test @openbimrl_engine//:engine_tests         # needs native / IFC fixtures
```

Root aliases → actual targets:

| Alias | Actual |
|-------|--------|
| `//:help` | `@openbimrl_engine//:help` |
| `//:engine` | `@openbimrl_engine//:engine_lib` |
| `//:webapp_dev` | `//OpenBimRL-CreatorTool/webapp:dev` |
| `//:webapp_build` | `//OpenBimRL-CreatorTool/webapp:build` |
| `//:rest` | `@openbimrl_engine_rest//:rest_app` |
| `//:rest_deploy.jar` | `@openbimrl_engine_rest//:rest_deploy.jar` |

### Webapp lockfile

Bazel owns Node/pnpm for builds (`update_pnpm_lock = True` in root `MODULE.bazel`). To change dependencies, edit `OpenBimRL-CreatorTool/webapp/package.json` and refresh the lock with pnpm **in that directory**, then rebuild:

```bash
cd OpenBimRL-CreatorTool/webapp
pnpm install
cd ../..
bazel build //:webapp_build
```

## Standalone modules

Each submodule can be the Bazel root on its own.

### Engine

```bash
cd OpenBimRL-Engine
bazel build //:engine_lib
bazel build //:console_app_deploy.jar
bazel test //:engine_unit_tests
bazel test //:engine_tests
```

More detail: [`OpenBimRL-Engine/BUILD.md`](OpenBimRL-Engine/BUILD.md).

### REST

When REST is the root module, Engine comes from GitHub Packages via `third_party/engine_maven_shim` (not the local Engine tree). Auth:

```bash
cd OpenBimRL-Engine-REST
cp .netrc.example .netrc   # fill in GitHub user + PAT (read:packages)
chmod 600 .netrc
install -m 600 .netrc ~/.netrc   # do not set HOME to the repo
```

```bash
bazel build //:rest_deploy.jar
bazel run //:rest_app -- --spring.profiles.active=dev
bazel test //:rest_tests
```

From the monorepo root, local Engine is used instead — no `.netrc` needed for Engine resolution.

## Configs (`.bazelrc`)

Root `.bazelrc` try-imports Engine defaults and adds:

| Config / flag | Purpose |
|---------------|---------|
| `--config=rest` | Use REST Kotlin 21 toolchain for `build`/`run`/`test` of `//:rest` (required from workspace root) |
| Engine `--config=rocm_offload` | Native OpenMP AMD GPU offload (see Engine `BUILD.md`). `/status` reads offload flags from the compiled `libopenbimrl_jni.so` via JNI. Set `OPENBIMRL_ROCM_OFFLOAD_ARCH` when building if `rocminfo` auto-detect is unavailable. |
| Engine `--config=cuda_offload` | Native OpenMP NVIDIA offload (WIP) |
| Engine `--config=docker` | Use image `local_jdk` instead of downloading remote JDK |

## Native library notes

- JNI artifact: classpath resource `libopenbimrl_jni.so` (from `@openbimrl_native`, aliased as Engine `//:openbimrl_native` / `//:native_lib_so`).
- Prebuilt IfcOpenShell: `OPENBIMRL_IFCOPENSHELL_PREFIX=/opt/ifcopenshell` (DevContainer).
- Runtime shared libs: set `LD_LIBRARY_PATH=/opt/ifcopenshell/lib` when running Engine/REST outside tests that already inject it.
- Engine embeds the JNI `.so` in the jar; IfcOpenShell/OCCT remain dynamic host dependencies.
