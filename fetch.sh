BUILDROOT_VERSION=2026.02

ROOT_DIR="$(pwd)"
BUILDROOT_DIR="$ROOT_DIR/buildroot-$BUILDROOT_VERSION"

patch_buildroot() {
    PATCH_STAMP="$BUILDROOT_DIR/.stm32f429-patches-applied"

    if [ -f "$PATCH_STAMP" ]; then
        echo "Buildroot patches already applied"
    else
        cd "$BUILDROOT_DIR"
        for p in "$ROOT_DIR"/patches/buildroot/*.patch; do
            echo "Applying $(basename "$p")"
            patch --batch --forward -p1 < "$p" || exit 1
        done
        touch "$PATCH_STAMP"
        cd "$ROOT_DIR"
    fi

    cp buildroot.config "$BUILDROOT_DIR/configs/stm32f429_disco_xip_defconfig"
    cp linux.config "$BUILDROOT_DIR/board/stmicroelectronics/stm32f429-disco"
    cp busybox-minimal.config "$BUILDROOT_DIR/package/busybox"
    cp uClibc-ng.config "$BUILDROOT_DIR/package/uclibc"
    LINUX_PATCH_DIR="$BUILDROOT_DIR/board/stmicroelectronics/stm32f429-disco/patches/linux"
    rm -f "$LINUX_PATCH_DIR"/0050*.patch
    rm -f "$LINUX_PATCH_DIR"/002[1-9]-*.patch
    for p in "$ROOT_DIR"/patches/linux/*.patch; do
        cp -a "$p" "$LINUX_PATCH_DIR/"
    done
    cp -a "$ROOT_DIR"/patches/musl/*.patch "$BUILDROOT_DIR/package/musl"
}

fetch_sources() {
    if [ ! -f "buildroot-$BUILDROOT_VERSION.tar.xz" ]; then
        wget https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.xz
    fi
    if [ ! -d "$BUILDROOT_DIR" ]; then
        tar xvf buildroot-$BUILDROOT_VERSION.tar.xz
    fi
}

fetch_sources
patch_buildroot
