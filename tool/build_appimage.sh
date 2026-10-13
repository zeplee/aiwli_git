#!/usr/bin/env bash
# Package the Flutter Linux bundle into an AppImage.
#
# Recipe borrowed from Kelivo's tool/build_appimage.sh (battle-tested in
# their release CI): bundle → AppDir/usr/bin, lib/ → usr/lib with a symlink
# back so both linuxdeploy's ELF scan and Flutter's $ORIGIN/lib resolution
# work; linuxdeploy scans every ELF in the AppDir; appimagetool packs the
# type-2 image. APPIMAGE_EXTRACT_AND_RUN avoids needing FUSE in CI.
#
# Usage: bash tool/build_appimage.sh <flutter-bundle-dir> <version> <name-base>
#   e.g. bash tool/build_appimage.sh build/linux/x64/release/bundle 1.5.26 aiwli-git-linux
#   → ./aiwli-git-linux-x86_64.AppImage
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <flutter-bundle-dir> <version> <name-base>" >&2
  exit 1
fi
bundle_dir="$(realpath "$1")"
version="$2"
base="$3"
arch="$(uname -m)"
case "$arch" in
  x86_64|aarch64) ;;
  *) echo "Unsupported AppImage architecture: $arch" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$PWD/${base}-${arch}.AppImage"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
app_dir="$work_dir/AppDir"

mkdir -p "$app_dir/usr/bin"
cp -a "$bundle_dir/." "$app_dir/usr/bin/"
# linuxdeploy expects libraries in usr/lib; Flutter also resolves lib/libapp.so
# relative to its executable. Keep that path without duplicating the libraries.
mv "$app_dir/usr/bin/lib" "$app_dir/usr/lib"
ln -s ../lib "$app_dir/usr/bin/lib"

cat > "$work_dir/aiwli-git.desktop" <<'DESKTOP'
[Desktop Entry]
Name=AiwliGit
Exec=gitdeck
Icon=aiwli-git
Type=Application
Categories=Development;
DESKTOP
# 256px icon from the macOS asset catalog (single source of truth).
cp "$repo_root/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png" \
  "$work_dir/aiwli-git.png"

curl -fL --retry 3 -o "$work_dir/linuxdeploy.AppImage" \
  "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${arch}.AppImage"
curl -fL --retry 3 -o "$work_dir/appimagetool.AppImage" \
  "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage"
chmod +x "$work_dir/"*.AppImage

# Run the packaging tools without requiring a FUSE mount in CI. Preserve the
# release binaries produced by Flutter instead of stripping them again.
export APPIMAGE_EXTRACT_AND_RUN=1
export NO_STRIP=1
export ARCH="$arch"
export VERSION="$version"

"$work_dir/linuxdeploy.AppImage" --appdir "$app_dir" \
  --desktop-file "$work_dir/aiwli-git.desktop" \
  --icon-file "$work_dir/aiwli-git.png"

"$work_dir/appimagetool.AppImage" "$app_dir" "$output"
echo "Created $output"
