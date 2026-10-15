#!/data/data/com.termux/files/usr/bin/bash
#
# Build and install the Hyperon Python interface (hyperon / hyperonpy)
# on Termux (aarch64, Python 3.14), bypassing the upstream Conan-based
# build system which is not usable in Termux.
#
# Lives in docs/ for reference; run it from anywhere:
#   bash docs/build_python_interface_termux.sh
#
# Pipeline:
#   Rust crates  -> libhyperonc (C API, cbindgen)  [c/]
#   libhyperonc  -> hyperonpy (pybind11 module)    [python/hyperonpy.cpp]
#   hyperonpy.so -> pip package `hyperon`          [python/]
#
# The package is installed into the project venv: <repo>/.venv
#
set -euo pipefail

# Repository root: docs/ lives directly under it.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LOCAL_PREFIX="$HOME/.local"
VENV="$REPO/.venv"
JOBS="$(nproc 2>/dev/null || echo 2)"

# CFLAGS/CXXFLAGS exported by ~/.bashrc as "--sysroot=$PREFIX" make clang
# drop the libc++ include dir (breaks pybind11 headers). Clear them.
unset CFLAGS CXXFLAGS

log() { printf '\n=== %s\n' "$*"; }

log "Installing Termux build dependencies"
pkg install -y pybind11 check protobuf cmake >/dev/null

log "Installing cbindgen (if missing)"
command -v cbindgen >/dev/null || cargo install --locked cbindgen

log "Fetching optional-lite (header-only, not packaged for Termux)"
if [ ! -f "$LOCAL_PREFIX/include/nonstd/optional.hpp" ]; then
    mkdir -p "$LOCAL_PREFIX/include/nonstd"
    curl -fsSL -o "$LOCAL_PREFIX/include/nonstd/optional.hpp" \
        https://raw.githubusercontent.com/martinmoene/optional-lite/master/include/nonstd/optional.hpp
fi

log "Providing minimal CMake configs for optional-lite and check"
mkdir -p "$LOCAL_PREFIX/lib/cmake/optional-lite" "$LOCAL_PREFIX/lib/cmake/check"
cat > "$LOCAL_PREFIX/lib/cmake/optional-lite/optional-lite-config.cmake" <<EOF
set(optional-lite_INCLUDE_DIRS "$LOCAL_PREFIX/include")
if(NOT TARGET nonstd::optional-lite)
  add_library(nonstd::optional-lite INTERFACE IMPORTED)
  set_target_properties(nonstd::optional-lite PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "\${optional-lite_INCLUDE_DIRS}")
endif()
set(optional-lite_FOUND TRUE)
EOF
cat > "$LOCAL_PREFIX/lib/cmake/check/check-config.cmake" <<EOF
set(CHECK_INCLUDE_DIRS "$PREFIX/include")
set(CHECK_LIBRARIES "$PREFIX/lib/libcheck.so")
if(NOT TARGET Check::check)
  add_library(Check::check UNKNOWN IMPORTED)
  set_target_properties(Check::check PROPERTIES
    IMPORTED_LOCATION "\${CHECK_LIBRARIES}"
    INTERFACE_INCLUDE_DIRECTORIES "\${CHECK_INCLUDE_DIRS}")
endif()
set(Check_FOUND TRUE)
EOF

log "Building Rust core (libhyperonc) and installing into $LOCAL_PREFIX"
cmake -S "$REPO/c" -B "$REPO/c/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LOCAL_PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_PREFIX_PATH="$LOCAL_PREFIX"
cmake --build "$REPO/c/build" -j"$JOBS"
ctest --test-dir "$REPO/c/build" --output-on-failure
cmake --install "$REPO/c/build"

log "Building pybind11 module hyperonpy"
rm -rf "$REPO/python/build"
cmake -S "$REPO/python" -B "$REPO/python/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS= -DCMAKE_CXX_FLAGS= \
    -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$REPO/python" \
    -DPython3_EXECUTABLE="$PREFIX/bin/python3" \
    -Dpybind11_DIR="$PREFIX/lib/cmake/pybind11" \
    -DCMAKE_PREFIX_PATH="$LOCAL_PREFIX" \
    -DHYPERONC_INSTALL_PREFIX="$LOCAL_PREFIX" \
    -DGIT=ON
cmake --build "$REPO/python/build" -j"$JOBS"

log "Creating project venv and installing the Python package"
[ -d "$VENV" ] || "$PREFIX/bin/python3" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip setuptools wheel setuptools_scm pytest
"$VENV/bin/pip" install --no-build-isolation --no-deps "$REPO/python"

log "Smoke test"
"$VENV/bin/python" -c "
import hyperon
from hyperon import MeTTa
print('hyperon', hyperon.__version__)
print('(+(2 3)) =', MeTTa().run('!(+ 2 3)'))
"

log "Python test suite (excluding test_environment.py)"
# tests/test_environment.py hardcodes the Linux path "/tmp/hyperon-test".
# Termux has no writable /tmp (use $TMPDIR), and the Rust side unwraps the
# failed create_dir_all, so the process aborts. The environment API itself
# works when given a writable dir (e.g. $TMPDIR/hyperon-test).
"$VENV/bin/python" -m pytest "$REPO/python/tests" -q \
    --ignore="$REPO/python/tests/test_environment.py"

# --- Termux note: /tmp does not exist (writable), use $TMPDIR -----------
# On Termux /tmp is a read-only stub owned by the Android shell user:
#   $ ls -ld /tmp
#   drwxrwx--x. 2 shell shell 40 ... /tmp          # not writable
# The writable location is $TMPDIR = $PREFIX/tmp:
#   $ echo $TMPDIR
#   /data/data/com.termux/files/usr/tmp
# Consequences:
#   * temp files in scripts must go to "$TMPDIR", never hardcoded /tmp;
#   * any component that hardcodes /tmp (like tests/test_environment.py)
#     fails with PermissionDenied. The Environment API itself is fine:
#       python -c "import os; from hyperon import Environment; \
#         d=os.path.join(os.environ['TMPDIR'],'hyperon-test'); \
#         os.makedirs(d, exist_ok=True); \
#         print(Environment.init_common_env(config_dir=d, create_config=True))"
#     -> True
# Verify TMPDIR before running things that write temporary data:
#   test -w "$TMPDIR" || echo "TMPDIR not writable"

log "Done. Activate with: source $VENV/bin/activate"
