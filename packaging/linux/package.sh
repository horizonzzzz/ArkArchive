#!/usr/bin/env bash
set -euo pipefail

arch="${1:?Usage: package.sh <x64|arm64>}"
case "$arch" in
  x64) deb_arch=amd64; appimage_arch=x86_64 ;;
  arm64) deb_arch=arm64; appimage_arch=aarch64 ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
version=$(sed -n 's/^version: \([^+]*\).*/\1/p' pubspec.yaml)
[[ -n "$version" ]]
bundle="$root/build/linux/$arch/release/bundle"
test -x "$bundle/arknights_story_player"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p dist "$work/app/usr/share/applications" "$work/app/usr/share/icons/hicolor/192x192/apps" "$work/app/opt/arknights-story-player"
cp -a "$bundle/." "$work/app/opt/arknights-story-player/"
icon="$work/app/usr/share/icons/hicolor/192x192/apps/arknights_story_player.png"
cp android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png "$icon"
cat > "$work/app/usr/share/applications/com.example.arknights_story_player.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=方舟档案室
Exec=/opt/arknights-story-player/arknights_story_player
Icon=arknights_story_player
Categories=AudioVideo;Player;
Terminal=false
DESKTOP

mkdir -p "$work/app/DEBIAN"
cat > "$work/app/DEBIAN/control" <<CONTROL
Package: arknights-story-player
Version: $version
Architecture: $deb_arch
Maintainer: horizonzzzz <horizonzzzz@users.noreply.github.com>
Depends: libgtk-3-0, liblzma5, libstdc++6, libc6
Description: Unofficial Arknights story player
CONTROL
chmod 755 "$work/app/DEBIAN"
dpkg-deb --build --root-owner-group "$work/app" "dist/arknights_story_player-linux-$arch.deb"

rm -rf "$work/app/DEBIAN"
cp "$work/app/usr/share/applications/com.example.arknights_story_player.desktop" "$work/app/arknights_story_player.desktop"
sed -i 's|^Exec=.*|Exec=arknights_story_player|' "$work/app/arknights_story_player.desktop"
cp "$icon" "$work/app/arknights_story_player.png"
cat > "$work/app/AppRun" <<'APPRUN'
#!/usr/bin/env bash
set -euo pipefail
appdir="$(cd "$(dirname "$0")" && pwd)"
exec "$appdir/opt/arknights-story-player/arknights_story_player" "$@"
APPRUN
chmod +x "$work/app/AppRun"
# 提取工具后执行，避免 CI runner 对 FUSE 的依赖。
curl --fail --location --retry 3 "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$appimage_arch.AppImage" -o "$work/appimagetool"
chmod +x "$work/appimagetool"
(cd "$work" && ./appimagetool --appimage-extract >/dev/null)
ARCH="$appimage_arch" "$work/squashfs-root/AppRun" "$work/app" "$root/dist/arknights_story_player-linux-$arch.AppImage"
tar -czf "dist/arknights_story_player-linux-$arch.tar.gz" -C "$bundle" .
