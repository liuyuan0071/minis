#!/usr/bin/env bash
#
# Prepare Android sandbox assets:
#   1. Download Alpine Linux aarch64 minirootfs
#   2. Download PRoot aarch64 static binary from Termux packages
#   3. Place both into src/android/app/src/main/assets/
#
# Usage: ./scripts/prepare_android_sandbox.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSETS_DIR="$PROJECT_ROOT/src/android/app/src/main/assets"

ALPINE_VERSION="3.21"
ALPINE_RELEASE="3.21.3"
# Mirror order targets the current CI (GitHub Actions, US runners): the
# official dl-cdn.alpinelinux.org CDN is fast there, while the CN mirrors
# (USTC/Tsinghua/Aliyun) are kept as fallbacks for China-based runners
# (Gitee Go). Per-mirror timeout is short so a dead mirror can't hang the
# build past the runner's wall-clock limit.
ALPINE_REL="v${ALPINE_VERSION}/releases/aarch64/alpine-minirootfs-${ALPINE_RELEASE}-aarch64.tar.gz"
ALPINE_URLS=(
    "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_REL}"
    "https://mirrors.ustc.edu.cn/alpine/${ALPINE_REL}"
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/${ALPINE_REL}"
    "https://mirrors.aliyun.com/alpine/${ALPINE_REL}"
)

# Termux proot package — aarch64 static binary
# Version format uses '.' separators (e.g. 5.1.107.89); a '-' breaks the URL
# and returns 404 (verified against packages.termux.dev on 2026-08-05).
PROOT_VERSION="5.1.107.89"
PROOT_DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_${PROOT_VERSION}_aarch64.deb"

# Termux libtalloc — proot links against libtalloc.so.2 dynamically
# NOTE on the pool path: Termux uses Debian's pool layout for package names
# longer than 4 chars — first two letters + full name. The directory is
# pool/main/libt/libtalloc/, NOT pool/main/t/talloc/ (that 404s, verified
# 2026-08-08; a missing libtalloc silently skipped patching and shipped an
# APK whose proot could not load — "libtalloc.so.2 not found" on device).
TALLOC_VERSION="2.4.3"
TALLOC_DEB_URL="https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_${TALLOC_VERSION}_aarch64.deb"

mkdir -p "$ASSETS_DIR"

ROOTFS_FILE="$ASSETS_DIR/alpine-minirootfs.tar.gz"
PROOT_FILE="$ASSETS_DIR/proot-aarch64"
JNILIBS_DIR="$PROJECT_ROOT/src/android/app/src/main/jniLibs/arm64-v8a"
JNILIBS_PROOT="$JNILIBS_DIR/libproot.so"

# --- Alpine rootfs ---
if [ -f "$ROOTFS_FILE" ]; then
    echo "✓ Alpine rootfs already exists: $ROOTFS_FILE"
else
    echo "Downloading Alpine Linux ${ALPINE_RELEASE} aarch64 minirootfs..."
    DL_OK=0
    for url in "${ALPINE_URLS[@]}"; do
        echo "  trying: $url"
        # --max-time 60 per mirror: a dead mirror must not hang the build and
        # push it past the runner's wall-clock limit.
        if curl -fSL --connect-timeout 10 --max-time 60 -o "$ROOTFS_FILE" "$url"; then
            DL_OK=1
            break
        fi
        rm -f "$ROOTFS_FILE"
    done
    if [ "$DL_OK" -ne 1 ]; then
        echo "Error: all Alpine mirror URLs failed" >&2
        exit 1
    fi
    echo "✓ Downloaded: $ROOTFS_FILE ($(du -h "$ROOTFS_FILE" | cut -f1))"
fi

# --- PRoot binary ---
if [ -f "$PROOT_FILE" ]; then
    echo "✓ PRoot binary already exists: $PROOT_FILE"
    # build_proot.sh installs to both assets/ and jniLibs/; if it only got as
    # far as the assets copy, propagate it here instead of re-downloading.
    if [ ! -f "$JNILIBS_PROOT" ]; then
        mkdir -p "$JNILIBS_DIR"
        cp "$PROOT_FILE" "$JNILIBS_PROOT"
        chmod +x "$JNILIBS_PROOT"
        echo "✓ Copied existing proot to $JNILIBS_PROOT"
    fi
else
    echo "Downloading PRoot ${PROOT_VERSION} aarch64 from Termux..."

    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    DEB_FILE="$TMPDIR/proot.deb"
    curl -fSL -o "$DEB_FILE" "$PROOT_DEB_URL"

    # Extract .deb (it's an ar archive containing data.tar.xz)
    cd "$TMPDIR"
    ar x "$DEB_FILE"

    # Extract data archive
    if [ -f "data.tar.xz" ]; then
        tar xf data.tar.xz
    elif [ -f "data.tar.gz" ]; then
        tar xzf data.tar.gz
    elif [ -f "data.tar.zst" ]; then
        zstd -d data.tar.zst -o data.tar
        tar xf data.tar
    else
        echo "Error: Could not find data archive in .deb"
        ls -la "$TMPDIR"
        exit 1
    fi

    # Find the proot binary
    PROOT_BIN=$(find "$TMPDIR" -name "proot" -type f | head -1)
    if [ -z "$PROOT_BIN" ]; then
        echo "Error: Could not find proot binary in extracted .deb"
        find "$TMPDIR" -type f
        exit 1
    fi

    cp "$PROOT_BIN" "$PROOT_FILE"
    chmod +x "$PROOT_FILE"

    # Also install as a native library so Android extracts it to
    # nativeLibraryDir/libproot.so at install time (RootfsManager
    # reads the binary from there). The build_proot.sh script does
    # this naturally; the prebuilt download path must match it.
    mkdir -p "$JNILIBS_DIR"
    cp "$PROOT_BIN" "$JNILIBS_DIR/libproot.so"
    chmod +x "$JNILIBS_DIR/libproot.so"
    echo "✓ Installed: $JNILIBS_DIR/libproot.so"

    cd "$PROJECT_ROOT"

    echo "✓ Extracted PRoot binary: $PROOT_FILE ($(du -h "$PROOT_FILE" | cut -f1))"
fi

# --- libtalloc (PRoot runtime dependency) ---
#
# Background: Termux's prebuilt proot links libtalloc DYNAMICALLY
# (DT_NEEDED = "libtalloc.so.2"). On stock Android this is a problem:
#   1. The APK installer (NativeLibraryHelper) only extracts jniLibs entries
#      whose filename ends with ".so"; "libtalloc.so.2" ends in ".2" and is
#      silently skipped, so it never lands in nativeLibraryDir.
#   2. Android's linker uses namespace isolation (API 24+): even if we stage
#      libtalloc.so.2 into an app-private dir and add it to LD_LIBRARY_PATH,
#      the linker won't search non-whitelisted paths. Only nativeLibraryDir
#      is whitelisted for the app.
#
# Fix (what PRoot Distro / UserLAnd do): use patchelf to rewrite proot's
# DT_NEEDED from "libtalloc.so.2" → "libtalloc.so", then ship the lib renamed
# to "libtalloc.so" in jniLibs. The installer extracts it to
# nativeLibraryDir/libtalloc.so (name ends in ".so" ✓, path is in the app's
# linker namespace ✓), and proot resolves it at load time with no
# LD_LIBRARY_PATH gymnastics.
#
# Fallback when patchelf is unavailable (e.g. a bare Windows host): stage
# libtalloc.so.2 under assets/native-libs/ and rely on
# RootfsManager.stageRuntimeLibraryIfNeeded() + PRootKernel.ldLibraryPath.
# This only works on devices where the linker honours LD_LIBRARY_PATH for
# app-private dirs (older Android / non-namespace-isolated), so patchelf is
# strongly preferred.

# Ensure patchelf is available; try to install it on Linux CI runners.
# (GitHub Actions runs as a non-root user, so we need sudo; Gitee Go / root
# containers don't.)
if ! command -v patchelf >/dev/null 2>&1; then
    if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
        echo "Installing patchelf (needed to rewrite proot's libtalloc NEEDED)..."
        APT_INSTALL="apt-get install -y patchelf"
        if ! $APT_INSTALL >/dev/null 2>&1; then
            if command -v sudo >/dev/null 2>&1; then
                sudo -n apt-get update -y >/dev/null 2>&1 || true
                sudo -n $APT_INSTALL >/dev/null 2>&1 || true
            fi
        fi
    fi
fi
HAVE_PATCHELF=0
command -v patchelf >/dev/null 2>&1 && HAVE_PATCHELF=1

# Does the proot we're shipping actually need libtalloc? (Static builds from
# build_proot.sh carry no libtalloc DT_NEEDED and can skip all of this.)
PROOT_NEEDS_TALLOC=0
if [ -f "$JNILIBS_PROOT" ]; then
    if [ "$HAVE_PATCHELF" = "1" ]; then
        if patchelf --print-needed "$JNILIBS_PROOT" 2>/dev/null | grep -q 'libtalloc'; then
            PROOT_NEEDS_TALLOC=1
        fi
    else
        # Best-effort: the dynamic Termux proot always needs libtalloc.
        # If a static build happened to land here without patchelf to inspect,
        # the staging below is just unused dead weight (~50K).
        if strings "$JNILIBS_PROOT" 2>/dev/null | grep -q 'libtalloc.so.2'; then
            PROOT_NEEDS_TALLOC=1
        fi
    fi
fi

NATIVE_LIBS_ASSET_DIR="$ASSETS_DIR/native-libs"
ASSET_TALLOC="$NATIVE_LIBS_ASSET_DIR/libtalloc.so.2"

if [ "$PROOT_NEEDS_TALLOC" = "0" ]; then
    echo "✓ proot does not need libtalloc (static build) — nothing to do"
    # Clean up any stale assets from a previous dynamic build.
    rm -f "$ASSET_TALLOC" "$JNILIBS_DIR/libtalloc.so"
else
    echo "proot needs libtalloc — preparing runtime lib..."
    # Extract libtalloc.so.2 from the Termux .deb into a temp dir.
    TALLOC_TMPDIR="$(mktemp -d)"
    TALLOC_DEB_FILE="$TALLOC_TMPDIR/talloc.deb"
    FOUND_SO=""
    if curl -fSL --connect-timeout 10 --max-time 60 -o "$TALLOC_DEB_FILE" "$TALLOC_DEB_URL"; then
        cd "$TALLOC_TMPDIR"
        ar x "$TALLOC_DEB_FILE"
        if [ -f "data.tar.xz" ]; then
            tar xf data.tar.xz
        elif [ -f "data.tar.gz" ]; then
            tar xzf data.tar.gz
        elif [ -f "data.tar.zst" ]; then
            zstd -d data.tar.zst -o data.tar
            tar xf data.tar
        fi
        # libtalloc.so.2 lives under ./system/lib/ or ./data/data/.../lib/ on Termux.
        FOUND_SO=$(find "$TALLOC_TMPDIR" -name "libtalloc.so.2*" -type f 2>/dev/null | head -1)
    else
        echo "! Failed to download libtalloc (proot may fail at runtime)" >&2
    fi

    cd "$PROJECT_ROOT"

    if [ -n "$FOUND_SO" ] && [ "$HAVE_PATCHELF" = "1" ]; then
        # --- Preferred path: rewrite NEEDED + ship libtalloc.so in jniLibs ---
        mkdir -p "$JNILIBS_DIR"
        # Rewrite DT_NEEDED on the copy that actually runs
        # (nativeLibraryDir/libproot.so) and the assets copy (for parity).
        patchelf --replace-needed libtalloc.so.2 libtalloc.so "$JNILIBS_PROOT"
        if [ -f "$PROOT_FILE" ]; then
            patchelf --replace-needed libtalloc.so.2 libtalloc.so "$PROOT_FILE"
        fi
        # Ship the lib under a ".so" name so the installer extracts it.
        cp "$FOUND_SO" "$JNILIBS_DIR/libtalloc.so"
        chmod +x "$JNILIBS_DIR/libtalloc.so"
        # Remove any stale versioned-asset staging from older builds.
        rm -f "$ASSET_TALLOC"
        rmdir "$NATIVE_LIBS_ASSET_DIR" 2>/dev/null || true
        echo "✓ Patched proot NEEDED → libtalloc.so and installed: $JNILIBS_DIR/libtalloc.so ($(du -h "$JNILIBS_DIR/libtalloc.so" | cut -f1))"
        echo "  ( installer will extract it to nativeLibraryDir/libtalloc.so ; linker resolves it in-app namespace )"
    elif [ -n "$FOUND_SO" ]; then
        # --- Fallback path (no patchelf): asset-staging ---
        # Works only where the linker honours LD_LIBRARY_PATH for app-private
        # dirs (older Android). Kept as a last resort.
        echo "! patchelf not found — falling back to asset-staging (may fail on namespace-isolated devices)" >&2
        mkdir -p "$NATIVE_LIBS_ASSET_DIR"
        cp "$FOUND_SO" "$ASSET_TALLOC"
        chmod +x "$ASSET_TALLOC"
        echo "✓ Installed (fallback): $ASSET_TALLOC ($(du -h "$ASSET_TALLOC" | cut -f1))"
    else
        echo "! libtalloc.so.2 not found in Termux package — proot will fail at runtime" >&2
    fi
    rm -rf "$TALLOC_TMPDIR"
fi

# --- Final hard check: never ship a proot that will fail on device ---
# Two acceptable end states for jniLibs/libproot.so:
#   (a) static proot (no libtalloc DT_NEEDED) — produced by build_proot.sh
#   (b) dynamic proot whose DT_NEEDED was rewritten to libtalloc.so, with
#       libtalloc.so shipped in jniLibs next to it — the patchelf path above
# Anything else (still asking for libtalloc.so.2) will fail at runtime on
# modern Android: the namespace-isolated linker ignores LD_LIBRARY_PATH for
# exec'd binaries, so only nativeLibraryDir is searched. Fail the build here
# instead of silently shipping a broken APK.
echo "=== Final check: proot linkage ==="
if [ -f "$JNILIBS_PROOT" ]; then
    # The app's shell ALWAYS passes --native-offload=<socket>:<handlers>
    # (PRootKernel.kt / PersistentShell.kt / TerminalSession.kt). Stock Termux
    # proot does NOT implement that option and would exit with "unrecognized
    # option" at startup, so verify the OpenMinis fork extension is compiled
    # in — this is what makes the sandbox actually usable.
    if strings "$JNILIBS_PROOT" 2>/dev/null | grep -q -- '--native-offload'; then
        echo "OK: proot has the native-offload extension (OpenMinis fork)"
    else
        echo "ERROR: proot lacks --native-offload (app requires it) — sandbox would fail at startup" >&2
        exit 1
    fi
    if [ "$HAVE_PATCHELF" = "1" ]; then
        NEEDED=$(patchelf --print-needed "$JNILIBS_PROOT" 2>/dev/null || true)
        echo "libproot.so DT_NEEDED: ${NEEDED:-<none/static>}"
        if printf '%s\n' "$NEEDED" | grep -q 'libtalloc\.so\.2'; then
            echo "ERROR: libproot.so still needs libtalloc.so.2 — would fail on device" >&2
            exit 1
        fi
        if printf '%s\n' "$NEEDED" | grep -q 'libtalloc\.so'; then
            if [ ! -f "$JNILIBS_DIR/libtalloc.so" ]; then
                echo "ERROR: libproot.so needs libtalloc.so but it was not shipped in jniLibs" >&2
                exit 1
            fi
            echo "OK: needs libtalloc.so and it is present in jniLibs"
        else
            echo "OK: no libtalloc dependency (static build)"
        fi
    else
        if strings "$JNILIBS_PROOT" 2>/dev/null | grep -q 'libtalloc\.so\.2'; then
            echo "ERROR: proot needs libtalloc.so.2 and patchelf is unavailable — cannot guarantee a working APK" >&2
            exit 1
        fi
    fi
else
    echo "WARN: no libproot.so in jniLibs — nothing to verify"
fi

echo ""
echo "Assets ready in: $ASSETS_DIR"
ls -lh "$ASSETS_DIR"
