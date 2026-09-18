#!/bin/bash
# 一键打包 Token查询：生成 .app 和可分发的 .dmg / .pkg 安装包
# 用法：bash build.sh
set -e

VERSION="1.10"

# 项目根目录 = 本脚本所在目录。这样 clone 到任意路径都能直接跑，
# 也不会把开发机的绝对路径写进仓库。
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 产物默认输出到项目下的 dist/。想放到别处可覆盖：
#   OUT=~/Desktop bash build.sh
OUT="${OUT:-$PROJ/dist}"
mkdir -p "$OUT"

APP="$OUT/Token查询.app"
DMG="$OUT/Token查询-$VERSION.dmg"
PKG="$OUT/Token查询-$VERSION.pkg"
VOLNAME="Token查询"

cd "$PROJ"

echo "==> 编译 release"
swift build -c release --disable-sandbox

echo "==> 组装 App bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJ/.build/release/TokenMonitor" "$APP/Contents/MacOS/"
cp "$PROJ/Resources/Info.plist" "$APP/Contents/"
cp "$PROJ/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
# 必须先把扩展属性清掉：App 放在桌面/下载目录时，Finder 会写入 FinderInfo、
# 隔离标记等元数据，codesign 会以 "resource fork, Finder information, or
# similar detritus not allowed" 拒绝签名。清掉之后签名才稳定成功。
xattr -cr "$APP" 2>/dev/null || true
if codesign --force --sign - "$APP" 2>&1; then
    echo "    签名完成"
else
    echo "    签名跳过（未签名也能用，首次打开需右键 →「打开」）"
fi

echo "==> 打包 dmg"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Token查询.app"
# ditto 会连扩展属性一起复制。$APP 在桌面上，Finder/iCloud 会在 codesign 之后
# 又给它打上 com.apple.FinderInfo，带进 dmg 会让内部签名校验失败
# （"Disallowed xattr com.apple.FinderInfo"）。所以清理副本，而不是清理源。
xattr -cr "$STAGE/Token查询.app" 2>/dev/null || true
ln -s /Applications "$STAGE/Applications"

TMPDMG="/tmp/tokenmonitor-tmp.dmg"
rm -f "$TMPDMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$TMPDMG" >/dev/null

hdiutil attach "$TMPDMG" -readwrite -noverify -noautoopen >/dev/null
sleep 1

# 设置「拖拽安装」窗口布局；需要 Finder 自动化权限，失败不影响 dmg 可用
osascript >/dev/null 2>&1 <<APPLESCRIPT || echo "    （窗口布局跳过，dmg 仍可正常拖拽安装）"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 780, 540}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 120
    set text size of theViewOptions to 13
    set position of item "Token查询.app" of container window to {150, 200}
    set position of item "Applications" of container window to {430, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync

# Finder 写窗口布局时会给卷里的 .app 打上 com.apple.FinderInfo 等扩展属性，
# 这会让 ad-hoc 签名失效（挂载后 codesign --verify --strict 报
# "Disallowed xattr com.apple.FinderInfo"）。图标位置存在卷根目录的 .DS_Store 里，
# 跟这个 xattr 无关，清掉不影响拖拽布局。
xattr -cr "/Volumes/$VOLNAME/Token查询.app" 2>/dev/null || true

hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 \
  || hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true

rm -f "$DMG"
hdiutil convert "$TMPDMG" -format UDZO -o "$DMG" >/dev/null
codesign --force --sign - "$DMG" 2>/dev/null || true

rm -f "$TMPDMG"
rm -rf "$STAGE"

echo "==> 打包 pkg"
PKGROOT=$(mktemp -d)
mkdir -p "$PKGROOT/Applications"
ditto "$APP" "$PKGROOT/Applications/Token查询.app"
# 同上：清掉 ditto 带过来的扩展属性，否则装出来的 App 签名是坏的
xattr -cr "$PKGROOT/Applications/Token查询.app" 2>/dev/null || true
rm -f "$PKG"
pkgbuild --root "$PKGROOT" \
         --identifier com.hdc.tokenmonitor \
         --version "$VERSION" \
         --install-location / "$PKG" >/dev/null
rm -rf "$PKGROOT"

echo "==> 完成"
echo "    App：$APP"
echo "    DMG：$DMG"
echo "    PKG：$PKG"
