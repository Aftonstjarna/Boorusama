#!/usr/bin/env bash
# Build an AnyLinux-style aarch64 AppImage for Boorusama.
#
# Input: build/linux/arm64/release/bundle (flutter build linux --release)
#        dist/boorusama-libs-aarch64/lib   (MODE=full collect-libs.sh)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
default_version=$(sed -n 's/^version: *//p' "$root/pubspec.yaml" | head -1)
version=${VERSION:-$default_version}
bundle=${BUNDLE:-$root/build/linux/arm64/release/bundle}
libs=${LIBS:-$root/dist/boorusama-libs-aarch64/lib}
out=${OUT:-$root/dist/Boorusama-$version-anylinux-aarch64.AppImage}
runtime=${RUNTIME:-$root/build/vendor/uruntime-appimage-aarch64}
runtime_url=${RUNTIME_URL:-https://github.com/VHSgunzo/uruntime/releases/download/v0.8.4/uruntime-appimage-aarch64}
work=$root/build/appimage
appdir=$work/AppDir

[ -x "$bundle/boorusama" ] || { echo "missing bundle: $bundle" >&2; exit 2; }
[ -d "$libs" ] || { echo "missing libs: $libs (run MODE=full ./tool/appimage/collect-libs.sh)" >&2; exit 2; }

if [ ! -f "$runtime" ]; then
  echo "==> fetching uruntime"
  mkdir -p "$(dirname "$runtime")"
  curl -fL "$runtime_url" -o "$runtime"
fi
machine=$(readelf -h "$runtime" | awk -F: '/Machine:/{gsub(/^[ \t]+/,"",$2); print $2}')
[ "$machine" = "AArch64" ] || { echo "runtime is $machine" >&2; exit 1; }

echo "==> staging AppDir ($version)"
rm -rf "$work"
mkdir -p "$appdir"
cp -a "$bundle/." "$appdir/"
cp -a "$libs/." "$appdir/lib/"
ln -sf libmpv.so.2 "$appdir/lib/libmpv.so"

# Rockchip-only MDK backend. Nothing selects it on Adreno, and its
# librockchip_mpp.so.1 dependency does not exist on SteamOS.
rm -f "$appdir/lib/libmdk-rockchip.so"

if [ -f "$root/assets/icon/icon-512x512.png" ]; then
  install -m644 "$root/assets/icon/icon-512x512.png" "$appdir/boorusama.png"
  install -Dm644 "$root/assets/icon/icon-512x512.png" \
    "$appdir/share/icons/hicolor/512x512/apps/boorusama.png"
fi

cat > "$appdir/boorusama.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Boorusama
Comment=Booru browser
Exec=boorusama
Icon=boorusama
Terminal=false
Categories=Graphics;Network;
EOF

cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
set -eu
here=$(dirname "$(readlink -f "$0")")
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="$here/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
# Gamescope's WSI layer cannot hook media_kit's offscreen Vulkan swapchains and
# shows blocking dialogs. Flutter itself renders through OpenGL.
export VK_LOADER_LAYERS_DISABLE="${VK_LOADER_LAYERS_DISABLE:-VK_LAYER_FROG_gamescope_wsi_aarch64}"
exec "$here/boorusama" "$@"
EOF
chmod +x "$appdir/AppRun"

echo "==> packing SquashFS"
mksquashfs "$appdir" "$work/payload.squashfs" \
  -comp zstd -Xcompression-level 19 -b 131072 \
  -noappend -root-owned -no-progress >/dev/null

echo "==> assembling AppImage"
mkdir -p "$(dirname "$out")"
cat "$runtime" "$work/payload.squashfs" > "$out"
chmod +x "$out"
sha256sum "$out"
ls -lh "$out"
