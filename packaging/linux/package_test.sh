#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/project/packaging/linux" "$work/project/android/app/src/main/res/mipmap-xxxhdpi" "$work/bin"
cp "$root/packaging/linux/package.sh" "$work/project/packaging/linux/"
cp "$root/pubspec.yaml" "$work/project/"
cp "$root/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" "$work/project/android/app/src/main/res/mipmap-xxxhdpi/"
# 不下载或执行第三方 AppImage；只校验传入目录及输出路径。
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
while [[ "$1" != -o ]]; do shift; done
cat > "$2" <<'TOOL'
#!/usr/bin/env bash
mkdir -p squashfs-root
cat > squashfs-root/AppRun <<'RUN'
#!/usr/bin/env bash
test -x "$1/AppRun"
test -f "$1/arknights_story_player.desktop"
test -f "$1/arknights_story_player.png"
grep -qx 'Exec=arknights_story_player' "$1/arknights_story_player.desktop"
test ! -d "$1/DEBIAN"
touch "$2"
RUN
chmod +x squashfs-root/AppRun
TOOL
CURL
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
for arch in x64 arm64; do
  bundle="$work/project/build/linux/$arch/release/bundle"
  mkdir -p "$bundle/data" "$bundle/lib"
  printf '#!/bin/sh\nexit 0\n' > "$bundle/arknights_story_player"
  chmod +x "$bundle/arknights_story_player"
  bash "$work/project/packaging/linux/package.sh" "$arch" >/dev/null
  deb="$work/project/dist/arknights_story_player-linux-$arch.deb"
  expected="$arch"; [[ "$arch" != x64 ]] || expected=amd64
  [[ "$(dpkg-deb -f "$deb" Architecture)" == "$expected" ]]
  dpkg-deb -x "$deb" "$work/unpacked-$arch"
  test -x "$work/unpacked-$arch/opt/arknights-story-player/arknights_story_player"
  test -f "$work/unpacked-$arch/usr/share/applications/com.example.arknights_story_player.desktop"
  test -f "$work/project/dist/arknights_story_player-linux-$arch.AppImage"
  tar -tzf "$work/project/dist/arknights_story_player-linux-$arch.tar.gz" | grep -q './arknights_story_player'
  echo "PASS: $arch packaging layout"
done
if bash "$work/project/packaging/linux/package.sh" invalid >/dev/null 2>&1; then
  echo 'FAIL: unsupported architecture accepted' >&2
  exit 1
fi
echo 'PASS: unsupported architecture rejected'
