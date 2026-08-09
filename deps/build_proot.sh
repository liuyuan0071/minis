#!/bin/bash
set -e

# ============================================================================
# PRoot Android Build Script (OpenMinis fork)
# ============================================================================
# Cross-compiles a statically-linked libtalloc and the OpenMinis/proot fork
# for Android aarch64 using the Android NDK. Produces a single self-contained
# proot binary with the loader bundled, and installs it into
# `src/android/app/src/main/assets/proot-aarch64`.
#
# Repository: https://github.com/OpenMinis/proot (fork of termux/proot)
#
# Prerequisites:
#   - Android NDK r28+ (default path: ~/Library/Android/sdk/ndk/28.0.12433566,
#     or set $ANDROID_NDK_HOME)
#   - curl, tar, make, awk, sed
#
# Usage:
#   ./build_proot.sh           # incremental build
#   ./build_proot.sh clean     # clean all build artifacts and rebuild
#   ./build_proot.sh distclean # also remove vendored talloc source
#
# Output:
#   src/android/app/src/main/assets/proot-aarch64
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROOT_DIR="$SCRIPT_DIR/proot"
TALLOC_DIR="$SCRIPT_DIR/talloc"
ASSETS_DIR="$PROJECT_ROOT/src/android/app/src/main/assets"

# talloc version pinned to a known-good release. Single-file build avoids
# Samba's waf-based build system entirely (we just compile talloc.c).
TALLOC_VERSION="2.4.2"
TALLOC_TARBALL_URL="https://download.samba.org/pub/talloc/talloc-${TALLOC_VERSION}.tar.gz"

# Android targets — build proot + loader for BOTH ABIs:
#   * arm64-v8a (real phones, primary)
#   * x86_64    (desktop emulators like MuMu run the x86_64 image NATIVELY;
#                the arm64 binary would otherwise run under ARM→x86
#                translation where the ptrace-heavy loader crawls and hangs)
# Format: <abi>:<ndk-triple>:<asset-basename>. minSdk=26 in build.gradle.kts.
declare -a ANDROID_TARGETS=(
    "arm64-v8a:aarch64-linux-android:proot-aarch64"
    "x86_64:x86_64-linux-android:proot-x86_64"
)
ANDROID_API=26

# Per-target variables (assigned by build_target below):
BUILD_DIR=""
OUTPUT_BIN=""
JNILIBS_DIR=""
JNILIBS_BIN=""
ANDROID_ABI=""
NDK_TRIPLE=""
PROOT_ASSET_BASENAME=""
FORCE_REBUILD=0

# ----------------------------------------------------------------------------
# Log helpers
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[build_proot] $1${NC}"; }
log_success() { echo -e "${GREEN}[build_proot] $1${NC}"; }
log_warn()    { echo -e "${YELLOW}[build_proot] $1${NC}"; }
log_error()   { echo -e "${RED}[build_proot] $1${NC}" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Locate NDK + clang
# ----------------------------------------------------------------------------
resolve_ndk() {
    if [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ]; then
        echo "$ANDROID_NDK_HOME"
        return
    fi
    if [ -n "$ANDROID_NDK_ROOT" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
        echo "$ANDROID_NDK_ROOT"
        return
    fi

    # Auto-detect highest available NDK in the SDK folder (macOS default path
    # + common Linux CI locations). CI runners expose $ANDROID_HOME /
    # $ANDROID_SDK_ROOT, so falling back to those saves us when the exported
    # $ANDROID_NDK_HOME happens to be empty/wrong.
    local base="$HOME/Library/Android/sdk/ndk"
    if [ -d "$base" ]; then
        local latest
        latest=$(ls "$base" 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$latest" ]; then
            echo "$base/$latest"
            return
        fi
    fi
    for sdk in "$ANDROID_SDK_ROOT" "$ANDROID_HOME"; do
        if [ -n "$sdk" ] && [ -d "$sdk/ndk" ]; then
            local latest
            latest=$(ls "$sdk/ndk" 2>/dev/null | sort -V | tail -n 1)
            if [ -n "$latest" ]; then
                echo "$sdk/ndk/$latest"
                return
            fi
        fi
    done

    log_error "Android NDK not found. Set \$ANDROID_NDK_HOME or install via Android Studio."
}

setup_toolchain() {
    NDK_HOME="$(resolve_ndk)"
    log_info "Using NDK: $NDK_HOME"

    local host_tag
    case "$(uname -s)-$(uname -m)" in
        Darwin-*)         host_tag="darwin-x86_64" ;;
        Linux-x86_64)     host_tag="linux-x86_64" ;;
        *)                log_error "Unsupported host: $(uname -s) $(uname -m)" ;;
    esac

    TOOLCHAIN_BIN="$NDK_HOME/toolchains/llvm/prebuilt/$host_tag/bin"
    if [ ! -d "$TOOLCHAIN_BIN" ]; then
        log_error "Toolchain dir missing: $TOOLCHAIN_BIN"
    fi

    CC="$TOOLCHAIN_BIN/${NDK_TRIPLE}${ANDROID_API}-clang"
    AR="$TOOLCHAIN_BIN/llvm-ar"
    STRIP="$TOOLCHAIN_BIN/llvm-strip"
    OBJCOPY="$TOOLCHAIN_BIN/llvm-objcopy"
    OBJDUMP="$TOOLCHAIN_BIN/llvm-objdump"
    RANLIB="$TOOLCHAIN_BIN/llvm-ranlib"

    for tool in "$CC" "$AR" "$STRIP" "$OBJCOPY" "$OBJDUMP" "$RANLIB"; do
        if [ ! -x "$tool" ]; then
            log_error "Missing toolchain binary: $tool"
        fi
    done
    log_info "Clang: $CC"
}

# ----------------------------------------------------------------------------
# Stage: fetch talloc source (single-file build)
# ----------------------------------------------------------------------------
fetch_talloc() {
    if [ -f "$TALLOC_DIR/talloc.c" ] && [ -f "$TALLOC_DIR/talloc.h" ]; then
        log_info "talloc source already present, skipping download"
        return
    fi

    log_info "Downloading talloc $TALLOC_VERSION..."
    mkdir -p "$TALLOC_DIR"
    local tarball="$SCRIPT_DIR/build/talloc-src/talloc-${TALLOC_VERSION}.tar.gz"
    mkdir -p "$SCRIPT_DIR/build/talloc-src"
    if [ ! -f "$tarball" ]; then
        # Primary source is download.samba.org; it is occasionally slow or
        # unreachable from CI runners. Ubuntu's archive carries the same
        # upstream tarball (talloc_<ver>.orig.tar.gz) and is a fast fallback.
        if ! curl -fsSL --connect-timeout 15 --max-time 90 "$TALLOC_TARBALL_URL" -o "$tarball"; then
            log_warn "download.samba.org failed — trying Ubuntu archive mirror..."
            curl -fsSL --connect-timeout 15 --max-time 90 \
                "http://archive.ubuntu.com/ubuntu/pool/main/t/talloc/talloc_${TALLOC_VERSION}.orig.tar.gz" \
                -o "$tarball"
        fi
    fi

    local tmp
    tmp=$(mktemp -d)
    tar xzf "$tarball" -C "$tmp"
    cp "$tmp/talloc-${TALLOC_VERSION}/talloc.c" "$TALLOC_DIR/"
    cp "$tmp/talloc-${TALLOC_VERSION}/talloc.h" "$TALLOC_DIR/"
    rm -rf "$tmp"

    # talloc.c expects Samba's `replace.h` — a compat shim that pulls in the
    # standard C + POSIX headers and provides a handful of fallback macros.
    # We ship a minimal standalone version so talloc builds against bionic
    # without needing the rest of Samba. Numbers must match talloc.h constants.
    cat > "$TALLOC_DIR/replace.h" <<'EOF'
#ifndef REPLACE_H
#define REPLACE_H

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/auxv.h>

#define TALLOC_BUILD_VERSION_MAJOR   2
#define TALLOC_BUILD_VERSION_MINOR   4
#define TALLOC_BUILD_VERSION_RELEASE 2

#define HAVE_SYS_AUXV_H 1
#define HAVE_INTPTR_T 1
#define HAVE_VA_COPY 1

/* valgrind hooks are no-ops outside Samba */
#define VALGRIND_MAKE_MEM_UNDEFINED(p, n) do { (void)(p); (void)(n); } while (0)
#define VALGRIND_MAKE_MEM_DEFINED(p, n)   do { (void)(p); (void)(n); } while (0)
#define VALGRIND_MAKE_MEM_NOACCESS(p, n)  do { (void)(p); (void)(n); } while (0)

#ifndef ZERO_STRUCT
#define ZERO_STRUCT(x) memset((char *)&(x), 0, sizeof(x))
#endif

#ifndef discard_const
#define discard_const(ptr) ((void *)((uintptr_t)(ptr)))
#endif

#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif

#define HAVE_CONSTRUCTOR_ATTRIBUTE 1

#endif /* REPLACE_H */
EOF

    log_success "talloc $TALLOC_VERSION unpacked into deps/talloc/"
}

# ----------------------------------------------------------------------------
# Stage: build libtalloc.a (static)
# ----------------------------------------------------------------------------
build_talloc() {
    local out="$BUILD_DIR/libtalloc.a"
    if [ -f "$out" ] && [ "$FORCE_REBUILD" != "1" ]; then
        log_info "libtalloc.a already built, skipping"
        return
    fi

    log_info "Compiling libtalloc.a for android-$ANDROID_API ($ANDROID_ABI)..."
    mkdir -p "$BUILD_DIR/talloc-obj"

    # talloc.c needs a small amount of Samba boilerplate that's gated by
    # HAVE_* defines. We define just enough for a standalone build against
    # bionic: the common Linux/POSIX features minus Samba-specific plumbing.
    local defines=(
        -DHAVE_STDARG_H=1
        -DHAVE_VA_COPY=1
        -DHAVE_UNISTD_H=1
        -DHAVE_INTPTR_T=1
    )

    "$CC" -c "$TALLOC_DIR/talloc.c" \
        -o "$BUILD_DIR/talloc-obj/talloc.o" \
        -I"$TALLOC_DIR" \
        -fPIC -O2 -Wall -std=gnu99 \
        "${defines[@]}"

    "$AR" rcs "$out" "$BUILD_DIR/talloc-obj/talloc.o"
    "$RANLIB" "$out"

    log_success "libtalloc.a built ($(du -h "$out" | awk '{print $1}'))"
}

# ----------------------------------------------------------------------------
# Stage: build proot
# ----------------------------------------------------------------------------
build_proot() {
    if [ ! -d "$PROOT_DIR/src" ]; then
        # deps/proot is registered in .gitmodules but its gitlink was never
        # committed in this repo, so `git submodule update` has nothing to
        # clone. Fetch the fork directly (shallow) to stay self-sufficient.
        log_warn "PRoot source missing at $PROOT_DIR — cloning OpenMinis/proot (master, shallow)..."
        rm -rf "$PROOT_DIR"
        git clone --depth 1 --branch master \
            https://github.com/OpenMinis/proot.git "$PROOT_DIR" \
            || log_error "Could not clone OpenMinis/proot into $PROOT_DIR"
    fi

    # [T-quiet-exit] The fork enables talloc_enable_leak_report() in
    # src/cli/cli.c (main()), which dumps the whole talloc hierarchy to
    # stderr on EVERY exit — pure noise that floods the terminal after each
    # shell session and hides the real failure reason. Comment it out so a
    # release build exits clean.
    if grep -q 'talloc_enable_leak_report' "$PROOT_DIR/src/cli/cli.c"; then
        sed -i 's/^[[:space:]]*talloc_enable_leak_report();/\/\/ talloc_enable_leak_report(); \/* disabled for Minis release builds *\//' \
            "$PROOT_DIR/src/cli/cli.c"
        log_info "Disabled talloc_enable_leak_report() (exit noise)"
    fi

    log_info "Building proot ($ANDROID_ABI)..."

    # proot's GNUmakefile has a quirk where `-f <path>` out-of-tree builds
    # double-prefix source paths via $(SRC)$<. Simpler to build in-tree under
    # src/ — object files land next to sources, cleaned by `make clean`.
    # Note: Makefile's default CPPFLAGS adds `-D_FILE_OFFSET_BITS=64
    # -D_GNU_SOURCE -I. -I$(VPATH)` — we must preserve -I. since proot
    # sources use paths like `#include "execve/elf.h"`.
    local cppflags="-D_FILE_OFFSET_BITS=64 -D_GNU_SOURCE -I. -DARG_MAX=131072 -I$TALLOC_DIR"
    local cflags="-O2 -Wall -Wextra -fPIE"
    local ldflags="-Wl,-z,noexecstack -pie -L$BUILD_DIR -ltalloc"

    (
        cd "$PROOT_DIR/src"
        # Always clean first: the same in-tree src/ is reused for every ABI,
        # and make would otherwise reuse .o files compiled for the previous
        # target's toolchain.
        make clean >/dev/null 2>&1 || true

        make \
            CC="$CC" \
            STRIP="$STRIP" \
            OBJCOPY="$OBJCOPY" \
            OBJDUMP="$OBJDUMP" \
            CPPFLAGS="$cppflags" \
            CFLAGS="$cflags" \
            LDFLAGS="$ldflags" \
            -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
    )

    local built="$PROOT_DIR/src/proot"
    if [ ! -f "$built" ]; then
        log_error "Build finished but $built is missing"
    fi

    "$STRIP" "$built"

    # Sanity-check: ELF of the right machine type (PIE)
    case "$ANDROID_ABI" in
        arm64-v8a) ARCH_GREP='aarch64' ;;
        x86_64)    ARCH_GREP='x86-64' ;;
        *)         ARCH_GREP='' ;;
    esac
    if [ -n "$ARCH_GREP" ] && ! "$OBJDUMP" -a "$built" | grep -q "$ARCH_GREP"; then
        log_error "Output is not $ANDROID_ABI ELF"
    fi

    log_success "proot built: $built ($(du -h "$built" | awk '{print $1}'))"
    BUILT_PROOT="$built"
}

# ----------------------------------------------------------------------------
# Stage: install into Android assets
# ----------------------------------------------------------------------------
install_asset() {
    if [ ! -f "$BUILT_PROOT" ]; then
        log_error "No proot binary to install"
    fi
    mkdir -p "$ASSETS_DIR"

    # No .bak of the previous binary: anything left in assets/ is packaged
    # into the APK, so a backup silently added ~260K of dead weight to every
    # build. The binary is reproducible from source — rerun this script.
    rm -f "$OUTPUT_BIN.bak"

    install -m 0755 "$BUILT_PROOT" "$OUTPUT_BIN"
    log_success "Installed: $OUTPUT_BIN ($(du -h "$OUTPUT_BIN" | awk '{print $1}'))"

    mkdir -p "$JNILIBS_DIR"
    install -m 0755 "$BUILT_PROOT" "$JNILIBS_BIN"
    log_success "Installed: $JNILIBS_BIN ($(du -h "$JNILIBS_BIN" | awk '{print $1}'))"

    # Ship a standalone loader alongside proot. proot's get_loader_path()
    # honours $PROOT_LOADER BEFORE falling back to its embedded loader, and
    # the app sets PROOT_LOADER = nativeLibraryDir/libproot-loader.so when the
    # file exists (PRootKernel.kt). On stock Android the app data dir is
    # exec-restricted, so the embedded-loader extraction to PROOT_TMP_DIR
    # fails with EACCES ("Permission denied" right at shell start) — pointing
    # PROOT_LOADER at a jniLibs entry (nativeLibraryDir is executable, proot
    # itself runs from there) avoids the temp-file exec entirely. The loader
    # intermediate is produced by the bundled build too (it is objcopy-wrapped
    # into proot afterwards).
    if [ -f "$PROOT_DIR/src/loader/loader" ]; then
        install -m 0755 "$PROOT_DIR/src/loader/loader" "$JNILIBS_DIR/libproot-loader.so"
        log_success "Installed: $JNILIBS_DIR/libproot-loader.so"
    fi
    if [ -f "$PROOT_DIR/src/loader/loader-m32" ]; then
        install -m 0755 "$PROOT_DIR/src/loader/loader-m32" "$JNILIBS_DIR/libproot-loader32.so"
        log_success "Installed: $JNILIBS_DIR/libproot-loader32.so"
    fi
}

# ----------------------------------------------------------------------------
# Entry points
# ----------------------------------------------------------------------------
do_clean() {
    log_info "Cleaning build artifacts..."
    for target in "${ANDROID_TARGETS[@]}"; do
        IFS=':' read -r abi triple asset <<< "$target"
        rm -rf "$SCRIPT_DIR/build/proot-android-$abi"
    done
    if [ -d "$PROOT_DIR/src" ]; then
        (cd "$PROOT_DIR/src" && make clean >/dev/null 2>&1 || true)
    fi
    log_success "Clean complete"
}

do_distclean() {
    do_clean
    rm -rf "$TALLOC_DIR"
    log_success "Distclean complete"
}

main() {
    case "${1:-}" in
        clean)     do_clean; FORCE_REBUILD=1 ;;
        distclean) do_distclean; FORCE_REBUILD=1 ;;
        "")        FORCE_REBUILD=0 ;;
        *)         log_error "Unknown argument: $1 (expected: clean|distclean)" ;;
    esac

    # talloc source is arch-independent — fetch/unpack once.
    fetch_talloc

    for target in "${ANDROID_TARGETS[@]}"; do
        IFS=':' read -r ANDROID_ABI NDK_TRIPLE PROOT_ASSET_BASENAME <<< "$target"
        BUILD_DIR="$SCRIPT_DIR/build/proot-android-$ANDROID_ABI"
        OUTPUT_BIN="$ASSETS_DIR/$PROOT_ASSET_BASENAME"
        JNILIBS_DIR="$PROJECT_ROOT/src/android/app/src/main/jniLibs/$ANDROID_ABI"
        JNILIBS_BIN="$JNILIBS_DIR/libproot.so"
        log_info "=== Target: $ANDROID_ABI ($NDK_TRIPLE) → $OUTPUT_BIN ==="
        setup_toolchain
        build_talloc
        build_proot
        install_asset
    done

    log_success "All done. proot built for: ${ANDROID_TARGETS[*]}"
}

main "$@"
