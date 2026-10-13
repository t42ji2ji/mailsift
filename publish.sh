#!/bin/zsh
# 上線一個新版本：改版號（app 和官網）、commit、tag、push，從乾淨的副本做公證過的 DMG，發 GitHub Release，部署官網。
#   ./publish.sh 0.2.4 notes.md
# notes.md 是 release 說明（中英文）。只發已經 commit 的東西：工作目錄裡沒 commit 的改動不會進 DMG。
set -e
cd "${0:A:h}"
VERSION=$1 NOTES=${2:A}
[ -n "$VERSION" ] && [ -f "$NOTES" ] || { echo "usage: ./publish.sh <version> <notes.md>"; exit 1 }
git fetch -q && [ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] || { echo "main 跟 origin 不同步，先 pull／push"; exit 1 }

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" Resources/Info.plist
sed -i '' -E "s|<span class=\"ver\">v[^<]*<|<span class=\"ver\">v$VERSION<|g" site/index.html
git add Resources/Info.plist site/index.html
git commit -q -m "MailSift $VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag v$VERSION
git push -q origin main v$VERSION

# 在 tag 的乾淨副本裡做 release
W=$(mktemp -d)/mailsift
git worktree add -q $W v$VERSION
trap "git worktree remove --force $W" EXIT
$W/release.sh
gh release create v$VERSION $W/build/MailSift-$VERSION.dmg --title "MailSift $VERSION" --notes-file $NOTES

# 官網：Cloudflare Pages 專案 mailsift（下載鈕連 releases/latest，只有版號要更新）
cp -R $W/site $W/../site
CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_AC_ID npx wrangler pages deploy $W/../site --project-name mailsift --branch main --commit-dirty=true
