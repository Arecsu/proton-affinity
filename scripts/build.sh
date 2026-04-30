#!/bin/bash
set -e

# ── Environment ──────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG=$(cat "$REPO_ROOT/CACHYOS_TAG")
PROTON_DIR="$REPO_ROOT/.proton-src"
BUILD_DIR="$PROTON_DIR/build"
WINE_SRC="$PROTON_DIR/wine"
PATCHES_PROTON="$PROTON_DIR/patches/_wine"
PATCHES_AFFINITY="$REPO_ROOT/patches"
STAMP_DIR="$PROTON_DIR/.patch-stamps"
CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"

# ── Functions ────────────────────────────────────────────────────────────────

show_help() {
    echo "Usage: build.sh [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --fetch          Fetch .proton-src and initialize submodules"
    echo "  --patch          Apply Proton and Affinity patches to wine"
    echo "  --wine-reset     Reset wine submodule to pristine state (asks confirmation)"
    echo "  dist             Build the full distribution (requires previous steps)"
    echo "  wine             Rebuild wine only (requires previous steps)"
    echo "  redist           Package the built distribution into a redistributable tar.zst"
    echo ""
}

fetch_sources() {
    if [ ! -d "$PROTON_DIR" ]; then
        echo "→ Cloning proton-cachyos @ $TAG"
        git clone --branch "$TAG" \
            https://github.com/CachyOS/proton-cachyos.git "$PROTON_DIR"
    else
        echo "→ Using existing proton-cachyos"
    fi

    echo "→ Initializing submodules (recursive)"
    git -C "$PROTON_DIR" submodule update --init --recursive --filter=tree:0

    echo "✓ Sources fetched."
}


apply_wine_patches() {
    if [ ! -d "$PROTON_DIR" ]; then
        echo "✗ Proton source not found. Run build.sh --fetch first."
        exit 1
    fi

    mkdir -p "$STAMP_DIR"

    # Rename patches/wine → patches/_wine (one-time, to hide from proton build)
    if [ -d "$PROTON_DIR/patches/wine" ] && [ ! -d "$PATCHES_PROTON" ]; then
        echo "→ Renaming patches/wine → patches/_wine"
        mv "$PROTON_DIR/patches/wine" "$PATCHES_PROTON"
    fi

    # Remove the old affinity symlink if it exists inside _wine
    [ -L "$PATCHES_PROTON/affinity" ] && rm "$PATCHES_PROTON/affinity"

    cd "$WINE_SRC"

    # Clean up interrupted git am/rebase
    if [ -d ".git/rebase-apply" ] || [ -d ".git/rebase-merge" ]; then
        echo "→ Aborting interrupted rebase/am"
        git am --abort 2>/dev/null || true
    fi

    # Ensure git repo is clean
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "✗ Wine source tree is dirty. Commit, stash, or run --wine-reset before patching."
        exit 1
    fi

    # Fast lookup of recent commit subjects using an associative array
    # We only check the last 500 commits to cover all applied patches + local work.
    echo "→ Pre-caching recent commit subjects..."
    declare -A subjects_map
    while read -r s; do
        subjects_map["$s"]=1
    done < <(git log -n 500 --format=%s)

    _apply_patch_dir() {
        local dir="$1"
        local label="$2"
        local to_apply=()

        [ -d "$dir" ] || return 0
        echo "→ Checking $label patches..."

        mapfile -d '' patches < <(find "$dir" -maxdepth 1 -name "*.patch" -print0 | sort -z)
        
        for patch in "${patches[@]}"; do
            # Extract subject using git mailinfo (the official way Git parses patches)
            # This handles MIME-decoding, folded lines, and prefix stripping automatically.
            local subject=$(git mailinfo /dev/null /dev/null < "$patch" | grep "^Subject: " | sed "s/^Subject: //")
            
            if [[ -n "${subjects_map["$subject"]}" ]]; then
                continue
            fi
            to_apply+=("$patch")
        done

        if [ ${#to_apply[@]} -gt 0 ]; then
            echo "→ Applying ${#to_apply[@]} $label patches in batch..."
            if ! git am --3way --keep-cr "${to_apply[@]}"; then
                echo "✗ Failed to apply patches from $label. Resolve conflicts and run 'git am --continue' or abort."
                exit 1
            fi
            # Update map with newly applied patches
            for p in "${to_apply[@]}"; do
                # (re-extract subject to update map, slightly redundant but safer)
                local s=$(awk '/^Subject: / { sub(/^Subject: (\[[^]]*\] )*/, ""); subj=$0; while(getline>0 && /^[ \t]/){sub(/^[ \t]*/,""); subj=subj " " $0} print subj; exit }' "$p")
                subjects_map["$s"]=1
            done
        else
            echo "  (all $label patches already applied)"
        fi
    }

    _apply_patch_dir "$PATCHES_PROTON" "proton"
    _apply_patch_dir "$PATCHES_AFFINITY" "affinity"

    touch "$STAMP_DIR/patches-applied"
    [ -d "$BUILD_DIR" ] && touch "$BUILD_DIR/.wine-post-source"
    
    echo "✓ Patches applied."
}

reset_wine() {
    if [ ! -d "$PROTON_DIR" ]; then
        echo "✗ Proton source not found."
        exit 1
    fi

    echo "WARNING: This will reset the wine submodule and discard ALL local commits and changes."
    echo "         Any unpushed work (WIP commits, patches applied on top of base) will be LOST."
    local ahead=$(git -C "$WINE_SRC" rev-list --count HEAD...$(git -C "$PROTON_DIR" ls-tree HEAD wine | awk '{print $3}') 2>/dev/null || echo "?")
    if [[ "$ahead" != "0" && "$ahead" != "?" ]]; then
        echo "         !! Wine currently has $ahead commit(s) ahead of base that will be destroyed !!"
        echo "         Save them first: git -C .proton-src/wine format-patch HEAD~${ahead}"
    fi
    read -p "Are you sure? (y/N) " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Aborted."
        return
    fi

    # Determine base hash from parent repo
    local base_hash=$(git -C "$PROTON_DIR" ls-tree HEAD wine | awk '{print $3}')
    if [ -z "$base_hash" ]; then
        echo "✗ Could not determine base hash for wine submodule."
        exit 1
    fi

    echo "→ Resetting wine to $base_hash"
    cd "$WINE_SRC"
    git reset --hard "$base_hash"
    git clean -fd

    # Revert patch folder name
    if [ -d "$PATCHES_PROTON" ]; then
        echo "→ Reverting patches/_wine to patches/wine"
        mv "$PATCHES_PROTON" "$PROTON_DIR/patches/wine"
    fi

    # Remove stamps
    rm -f "$STAMP_DIR/patches-applied"
    [ -d "$BUILD_DIR" ] && rm -f "$BUILD_DIR/.wine-post-source"
    
    echo "✓ Wine reset complete."
}

run_build() {
    local target="$1"

    [ -d "$PROTON_DIR" ] || { echo "✗ Sources missing. Run --fetch first."; exit 1; }
    [ -f "$STAMP_DIR/patches-applied" ] || { echo "✗ Patches not applied. Run --patch first."; exit 1; }

    local steamrt_image
    steamrt_image=$(make --silent -f "$PROTON_DIR/Makefile.in" "SRCDIR=$PROTON_DIR" get-steamrt-image 2>/dev/null)
    [ -n "$steamrt_image" ] || { echo "✗ Could not determine SteamRT image."; exit 1; }

    local make_target="dist"
    local sync_wine=0
    if [ "$target" = "wine" ]; then
        make_target="wine-i386-build wine-x86_64-build"
        sync_wine=1
    elif [ "$target" = "redist" ]; then
        make_target="redist"
    fi

    echo "→ Building: $make_target (inside SteamRT)"
    mkdir -p "$CCACHE_DIR"
    local CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
    mkdir -p "$CARGO_HOME_DIR"
    local RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
    local nproc=$(nproc)

    local uid gid
    uid=$(id -u)
    gid=$(id -g)

    docker run --rm --network=host --security-opt seccomp=unconfined \
        -v "$PROTON_DIR:$PROTON_DIR" \
        -v "$CCACHE_DIR:$CCACHE_DIR" \
        -v "$CARGO_HOME_DIR:$CARGO_HOME_DIR" \
        -v "$RUSTUP_HOME_DIR:$RUSTUP_HOME_DIR:ro" \
        -e HOME="$HOME" \
        -e CARGO_HOME="$CARGO_HOME_DIR" \
        -e RUSTUP_HOME="$RUSTUP_HOME_DIR" \
        -e ENABLE_CCACHE=1 \
        -e CCACHE_DIR="$CCACHE_DIR" \
        -e CCACHE_BASEDIR="$PROTON_DIR" \
        -e CFLAGS="-O2 -march=nocona -mtune=core-avx2" \
        -e CXXFLAGS="-O2 -march=nocona -mtune=core-avx2" \
        -e RUSTFLAGS="-C opt-level=3 -C target-cpu=nocona" \
        -e LDFLAGS="-fuse-ld=mold -Wl,-O1,--sort-common,--as-needed" \
        -w "$PROTON_DIR" \
        "$steamrt_image" \
        bash -c "
            # ── Arch Linux host workarounds ───────────────────────────────────────
            # SteamRT 4 is Debian-based (ID_LIKE=debian, Debian 13 trixie). The Proton
            # build system assumes certain Debian multiarch conventions that Arch doesn't
            # follow. These two fixups are applied inside the container at build time.
            # They may or may not be needed on other distros.
            #
            # (1) pkgconfig paths: on Debian, /usr/lib32 and /usr/lib64 are symlinks
            #     into the multiarch tree so pkgconfig files are found automatically.
            #     SteamRT ships them as real directories without a pkgconfig subdir,
            #     so the Proton build system can't find .pc files for 32-bit libraries.
            #     Recreate the symlinks the build expects.
            ln -sfn /usr/lib/i386-linux-gnu/pkgconfig   /usr/lib32/pkgconfig
            ln -sfn /usr/lib/x86_64-linux-gnu/pkgconfig /usr/lib64/pkgconfig

            # (2) compiler triplets: SteamRT ships Debian-triplet binaries
            #     (i686-linux-gnu-gcc). Proton's build system looks for GNU-triplet
            #     names (i686-pc-linux-gnu-gcc). On a Debian host these are aliased
            #     already; on Arch they are not, so we create wrappers in /usr/local/bin
            #     (on PATH, writable by root inside the container).
            for tool in gcc g++ ar ranlib ld strip nm objcopy objdump as pkg-config; do
                [ -f /usr/bin/i686-linux-gnu-\$tool ]   && ln -sf /usr/bin/i686-linux-gnu-\$tool   /usr/local/bin/i686-pc-linux-gnu-\$tool
                [ -f /usr/bin/x86_64-linux-gnu-\$tool ] && ln -sf /usr/bin/x86_64-linux-gnu-\$tool /usr/local/bin/x86_64-pc-linux-gnu-\$tool
            done

            # Drop from root to the calling user for the actual build so that
            # files written into the mounted host volume are owned by you.
            exec setpriv --reuid=$uid --regid=$gid --clear-groups bash -c '
                # Use host rustup cargo (1.87) over SteamRT cargo (1.68, too old for edition 2024).
                # Also expose afdko binaries (makeotfexe etc.) needed for source-han font generation.
                export PATH="$RUSTUP_HOME_DIR/toolchains/stable-x86_64-unknown-linux-gnu/bin:/usr/libexec/afdko:$PATH"

                # Pre-fetch cargo dependencies while we still have network access.
                # The Proton build runs cargo with --offline, so all deps must be
                # in CARGO_HOME before the offline build starts.
                cargo fetch --locked --manifest-path $PROTON_DIR/gst-plugins-rs/Cargo.toml

                mkdir -p build && cd build
                if [ ! -f Makefile ] || ! grep -q \"CONTAINER_ENGINE := none\" Makefile; then
                    CFLAGS=\"-O2 -march=nocona -mtune=core-avx2\"
                    CXXFLAGS=\"-O2 -march=nocona -mtune=core-avx2\"
                    RUSTFLAGS=\"-C opt-level=3 -C target-cpu=nocona\"
                    LDFLAGS=\"-fuse-ld=mold -Wl,-O1,--sort-common,--as-needed\"
                    ROOTLESS_CONTAINER=0 ../configure.sh \
                        --container-engine=none \
                        --build-name=proton-affinity \
                        --without-libpcap \
                        --without-tts
                fi
                SUBJOBS=$nproc make -j1 $make_target
            '
        " \
        2>&1 | tee "$REPO_ROOT/build.log"

    if [ "$sync_wine" -eq 1 ] && [ -d "$BUILD_DIR/dist/files/lib/wine" ]; then
        echo "→ Syncing wine build output to dist/files/"
        cp -a "$BUILD_DIR/dst-wine-i386/lib/wine/"* "$BUILD_DIR/dist/files/lib/wine/" 2>/dev/null || true
        cp -a "$BUILD_DIR/dst-wine-x86_64/lib/wine/"* "$BUILD_DIR/dist/files/lib/wine/" 2>/dev/null || true
        # bin/ contains wineserver and the wine launcher — both rebuilt by
        # the wine target but not living under lib/wine/, so sync explicitly.
        cp -a "$BUILD_DIR/dst-wine-x86_64/bin/"* "$BUILD_DIR/dist/files/bin/" 2>/dev/null || true
        echo "✓ Wine synced to dist/files/"
    fi

    echo "✓ Done. Output: $BUILD_DIR/dist"

    # Remove old SteamRT images — keep only the one this build used
    local registry
    registry=$(echo "$steamrt_image" | cut -d: -f1 | sed 's|/[^/]*$||')
    docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${registry}/" | while read -r img; do
        if [ "$img" != "$steamrt_image" ]; then
            echo "→ Removing old SteamRT image: $img"
            docker rmi "$img" || true
        fi
    done
}

make_redist() {
    [ -d "$PROTON_DIR" ] || { echo "✗ Sources missing. Run --fetch first."; exit 1; }
    [ -f "$STAMP_DIR/patches-applied" ] || { echo "✗ Patches not applied. Run --patch first."; exit 1; }

    run_build "redist"
}

# ── Entry Point ─────────────────────────────────────────────────────────────

case "$1" in
    --fetch)        fetch_sources ;;
    --patch)        apply_wine_patches ;;
    --wine-reset)   reset_wine ;;
    dist|wine)      run_build "$1" ;;
    redist)         make_redist ;;
    "")             run_build "dist" ;;
    *)              show_help; exit 1 ;;
esac
