#!/bin/bash
set -euo pipefail

TOPDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# cmake binary (do NOT bake configure-only flags into it)
CMAKE_BIN="cmake"
# configure flags only
CMAKE_CONFIGURE="${CMAKE_BIN} -DCMAKE_EXPORT_COMPILE_COMMANDS=1 --log-level=STATUS"

ALL_ARGS=("$@")
BUILD_ARGS=()
MAKE_ARGS=(-j 4)

echo "$0 ${ALL_ARGS[*]}"

# Install 3rd deps into project-local directory (avoid /usr/local permission issues)
DEPS_PREFIX="${TOPDIR}/deps/install"
mkdir -p "${DEPS_PREFIX}"

function usage
{
  echo "Usage:"
  echo "./build.sh -h"
  echo "./build.sh init # build & install dependencies into deps/install"
  echo "./build.sh clean"
  echo "./build.sh [BuildType] [--make [MakeOptions]]"
  echo ""
  echo "OPTIONS:"
  echo "BuildType => debug(default), release"
  echo "MakeOptions => Options to make command, default: -j N"
  echo ""
  echo "Examples:"
  echo "./build.sh init"
  echo "./build.sh debug --make -j4"
}

function parse_args
{
  local make_start=false
  for arg in "${ALL_ARGS[@]}"; do
    if [[ "$arg" == "--make" ]]; then
      make_start=true
    elif [[ "$make_start" == false ]]; then
      BUILD_ARGS+=("$arg")
    else
      MAKE_ARGS+=("$arg")
    fi
  done
}

function try_make
{
  make "${MAKE_ARGS[@]}" || make
}

function prepare_build_dir
{
  rm -rf "${TOPDIR}/build"
  mkdir -p "${TOPDIR}/build"
  cd "${TOPDIR}/build"
}

# Parse -j from MAKE_ARGS; default 4
function get_jobs
{
  local jobs=4
  for ((i=0; i<${#MAKE_ARGS[@]}; i++)); do
    if [[ "${MAKE_ARGS[$i]}" == "-j" && $((i+1)) -lt ${#MAKE_ARGS[@]} ]]; then
      jobs="${MAKE_ARGS[$((i+1))]}"
    elif [[ "${MAKE_ARGS[$i]}" =~ ^-j[0-9]+$ ]]; then
      jobs="${MAKE_ARGS[$i]#-j}"
    fi
  done
  echo "${jobs}"
}

function cmake_build_install
{
  # Usage: cmake_build_install <src_dir> <build_dir> [cmake_args...]
  local src_dir="$1"; shift
  local build_dir="$1"; shift
  local jobs
  jobs="$(get_jobs)"

  mkdir -p "${build_dir}"

  # Configure
  ${CMAKE_CONFIGURE} -S "${src_dir}" -B "${build_dir}" \
    -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
    "$@"

  # Build (use cmake binary only; do NOT include -D/--log-level here)
  ${CMAKE_BIN} --build "${build_dir}" --parallel "${jobs}"

  # Install
  ${CMAKE_BIN} --install "${build_dir}"
}

function do_init
{
  git submodule update --init --recursive

  # libevent
  (
    cd "${TOPDIR}/deps/3rd/libevent"
    git checkout release-2.1.12-stable
  )
  cmake_build_install "${TOPDIR}/deps/3rd/libevent" "${TOPDIR}/deps/3rd/libevent/build" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DEVENT__DISABLE_OPENSSL=ON \
    -DEVENT__LIBRARY_TYPE=BOTH

  # googletest
  cmake_build_install "${TOPDIR}/deps/3rd/googletest" "${TOPDIR}/deps/3rd/googletest/build"

  # benchmark
  cmake_build_install "${TOPDIR}/deps/3rd/benchmark" "${TOPDIR}/deps/3rd/benchmark/build" \
    -DBENCHMARK_ENABLE_TESTING=OFF \
    -DBENCHMARK_INSTALL_DOCS=OFF \
    -DBENCHMARK_ENABLE_GTEST_TESTS=OFF \
    -DBENCHMARK_USE_BUNDLED_GTEST=OFF \
    -DBENCHMARK_ENABLE_ASSEMBLY_TESTS=OFF

  # jsoncpp
  cmake_build_install "${TOPDIR}/deps/3rd/jsoncpp" "${TOPDIR}/deps/3rd/jsoncpp/build" \
    -DJSONCPP_WITH_TESTS=OFF \
    -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF

  echo ""
  echo "[OK] Dependencies installed to: ${DEPS_PREFIX}"
  echo "     include: ${DEPS_PREFIX}/include"
  echo "     lib:     ${DEPS_PREFIX}/lib"
  echo ""
}

function do_build
{
  local TYPE="$1"; shift
  prepare_build_dir

  export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  echo "${CMAKE_CONFIGURE} -S ${TOPDIR} -B ${TOPDIR}/build $*"
  ${CMAKE_CONFIGURE} -S "${TOPDIR}" -B "${TOPDIR}/build" \
    -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
    "$@"

  mkdir -p "${TOPDIR}/build/bin"
  cp -f "${TOPDIR}/test/data.txt" "${TOPDIR}/build/bin/" || true
}

function do_clean
{
  echo "clean build dir and dependency build dirs"
  rm -rf "${TOPDIR}/build"
  rm -rf "${TOPDIR}/deps/3rd/libevent/build" \
         "${TOPDIR}/deps/3rd/googletest/build" \
         "${TOPDIR}/deps/3rd/benchmark/build" \
         "${TOPDIR}/deps/3rd/jsoncpp/build"
}

function build
{
  set -- "${BUILD_ARGS[@]:-}"
  case "x${1:-}" in
    xrelease)
      shift || true
      do_build release -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDEBUG=OFF "$@"
      ;;
    xdebug|"x")
      if [[ "x${1:-}" == "xdebug" ]]; then shift || true; fi
      do_build debug -DCMAKE_BUILD_TYPE=Debug -DDEBUG=ON "$@"
      ;;
    *)
      BUILD_ARGS=(debug "${BUILD_ARGS[@]}")
      build
      ;;
  esac
}

function main
{
  case "${1:-}" in
    -h|--help)
      usage
      ;;
    init)
      do_init
      ;;
    clean)
      do_clean
      ;;
    *)
      parse_args
      build
      try_make
      ;;
  esac
}

main "$@"