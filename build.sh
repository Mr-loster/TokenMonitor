#!/bin/bash
# 一键打包 Token查询：生成 .app 和可分发的 .dmg / .pkg 安装包
# 用法：bash build.sh
set -e

VERSION="2.0"

# 项目根目录 = 本脚本所在目录。这样 clone 到任意路径都能直接跑，
# 也不会把开发机的绝对路径写进仓库。
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 产物默认输出到项目下的 dist/。想放到别处可覆盖：
#   OUT=~/Desktop bash build.sh
OUT="${OUT:-$PROJ/dist}"
mkdir -p "$OUT"

APPNAME="Token查询"
VOLNAME="Token查询"
DMG="$OUT/$APPNAME-$VERSION.dmg"
PKG="$OUT/$APPNAME-$VERSION.pkg"

cd "$PROJ"

echo "==> 编译 release"
swift build -c release --disable-sandbox

# ---------------------------------------------------------------------------
# 组装 + 签名一律在 /tmp 里做，**不要在项目目录里做**。
#
# 项目如果放在 iCloud 的桌面 / 文稿下（本机就是），整个路径由 FileProvider 托管
# （xattr 里能看到 com.apple.fileprovider.fpfs#P），系统会**异步**给文件重新打上
# com.apple.FinderInfo。codesign 一读到这个 xattr 就报
#
#   resource fork, Finder information, or similar detritus not allowed
#
# 而且这个错误是**在签名写完 _CodeSignature 之后**、校验阶段才报出来的，
# 所以现象很迷惑：bundle 里签名文件在，`codesign --verify` 却过不了；
# 更糟的是如果 codesign 直接失败退出，dmg / pkg 会照着**没有签名**的 bundle
# 打包出去（挂载后报 "code has no resources but signature indicates they must be present"），
# 而这一步不会有任何提示。
#
# /tmp 不在 FileProvider 管辖下，一次就签干净。
# ---------------------------------------------------------------------------
STAGE=$(mktemp -d /tmp/tokenmonitor-stage.XXXXXX)
APP="$STAGE/$APPNAME.app"

echo "==> 组装 App bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJ/.build/release/TokenMonitor" "$APP/Contents/MacOS/"
cp "$PROJ/Resources/Info.plist" "$APP/Contents/"
cp "$PROJ/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" 2>&1 || true

# 签完必须验一次。不验的话「签名没成功」会一路静默传到 dmg / pkg 里。
if codesign --verify --strict "$APP" 2>/dev/null; then
    echo "    签名校验通过"
else
    echo "    ✗ 签名校验没通过，dmg / pkg 里的 App 会被 Gatekeeper 拦下，已中止打包"
    rm -rf "$STAGE"
    exit 1
fi

echo "==> 打包 dmg"
# dmg 直接用 STAGE 当源目录（App 已经在里面），再加一个「拖到 Applications」的软链
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
    set position of item "$APPNAME.app" of container window to {150, 200}
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
xattr -cr "/Volumes/$VOLNAME/$APPNAME.app" 2>/dev/null || true

hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 \
  || hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true

rm -f "$DMG"
hdiutil convert "$TMPDMG" -format UDZO -o "$DMG" >/dev/null
codesign --force --sign - "$DMG" 2>/dev/null || true

rm -f "$TMPDMG"

echo "==> 打包 pkg"
PKGROOT=$(mktemp -d /tmp/tokenmonitor-pkg.XXXXXX)
mkdir -p "$PKGROOT/Applications"
# 同 dmg：不要资源叉 / 扩展属性，否则会多出一堆 `._xxx` 一起被装进 /Applications
ditto --norsrc --noextattr "$APP" "$PKGROOT/Applications/$APPNAME.app"
find "$PKGROOT" -name '._*' -delete 2>/dev/null || true
# 同上：清掉 ditto 带过来的扩展属性，否则装出来的 App 签名是坏的
xattr -cr "$PKGROOT/Applications/$APPNAME.app" 2>/dev/null || true
rm -f "$PKG"
# 这一步会打几条 "write: Permission denied" 出来，**不是失败**：
# 新 macOS 给每个新建文件都挂 com.apple.provenance，且删掉后立刻又会挂上，
# pkgbuild 看到扩展属性就会为它写一个 `._xxx` 伴随条目，写那玩意儿时会报这个。
# 不影响安装，App 装出来是好的。
pkgbuild --root "$PKGROOT" \
         --identifier com.hdc.tokenmonitor \
         --version "$VERSION" \
         --install-location / "$PKG" >/dev/null
rm -rf "$PKGROOT"

echo "==> 输出可直接双击运行的 .app 到 $OUT"
rm -rf "$OUT/$APPNAME.app"
ditto --norsrc --noextattr "$APP" "$OUT/$APPNAME.app"
# 桌面 / 文稿目录下 FileProvider 会很快又打上 FinderInfo，本地签名因此失效。
# 这里再清一次，让刚拿到手时是干净的。签名失效不影响双击运行（App 未被隔离）。
xattr -cr "$OUT/$APPNAME.app" 2>/dev/null || true

rm -rf "$STAGE"

echo "==> 校验 dmg 里的 App 签名"
# 这一步是兜底：签名出问题时，光看打包日志是看不出来的
if hdiutil attach "$DMG" -nobrowse -readonly >/dev/null 2>&1; then
    if codesign --verify --strict "/Volumes/$VOLNAME/$APPNAME.app" 2>/dev/null; then
        echo "    ✓ 有效"
    else
        echo "    ✗ dmg 里的 App 签名无效，分发出去首次打开会被拦"
    fi
    hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 \
      || hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
fi

echo "==> 完成"
echo "    App：$OUT/$APPNAME.app"
echo "    DMG：$DMG"
echo "    PKG：$PKG"
