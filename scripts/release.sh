#!/bin/bash
# Builds a signed DMG of DuoBar+.
#   scripts/release.sh 1.0.1             build and check, then commit and tag locally
#   scripts/release.sh 1.0.1 --publish   also push and create the GitHub Release
set -euo pipefail

IDENTITY="DuoBar+ Developer"
REPO="huglab-dev/DuoBar-Plus"
PROJECT="DuoBar.xcodeproj"
PBXPROJ="$PROJECT/project.pbxproj"

VERSION="${1:-}"
PUBLISH="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh <x.y.z> [--publish]" >&2; exit 1; }
[[ -z "$PUBLISH" || "$PUBLISH" == "--publish" ]] || { echo "Unknown option: $PUBLISH" >&2; exit 1; }

cd "$(dirname "$0")/.."
TAG="v$VERSION"
DMG_NAME="DuoBar-Plus-$VERSION.dmg" # GitHub rewrites "+" in file names
DIST="build/dist"
DERIVED="build/release"
APP="$DERIVED/Build/Products/Release/DuoBar+.app"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
[[ "$(git branch --show-current)" == "main" ]] || { echo "Releases are made from main." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists." >&2
  exit 1
fi
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || { echo "\"$IDENTITY\" not found. Run scripts/create-signing-certificate.sh first." >&2; exit 1; }
if [[ "$PUBLISH" == "--publish" ]]; then
  command -v gh >/dev/null || { echo "The GitHub CLI (gh) is required for --publish." >&2; exit 1; }
fi

COMMITTED=0
restore() { if [[ "$COMMITTED" != 1 ]]; then git checkout -q -- "$PBXPROJ"; fi; }
trap restore EXIT

BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PBXPROJ" | head -1)
BUILD=$((BUILD + 1))
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PBXPROJ"

echo "==> Building DuoBar+ $VERSION (build $BUILD)"
mkdir -p build
rm -rf "${DERIVED:?}"
xcodebuild -project "$PROJECT" -scheme DuoBar -configuration Release -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=NO clean build > build/release.log 2>&1 \
  || { tail -20 build/release.log; echo "The build failed. See build/release.log." >&2; exit 1; }

echo "==> Signing"
codesign --force --options runtime --timestamp=none \
  --entitlements DuoBar/DuoBar.entitlements --sign "$IDENTITY" "$APP"

echo "==> Checking"
BINARY="$APP/Contents/MacOS/DuoBar+"
ARCHS=$(lipo -archs "$BINARY")
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "Expected a universal app, got: $ARCHS" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
[[ "$SIGNATURE" == *"Authority=$IDENTITY"* ]] || { echo "The app is not signed by $IDENTITY." >&2; exit 1; }
[[ "$SIGNATURE" == *"runtime"* ]] || { echo "Hardened runtime is missing." >&2; exit 1; }
cmp -s LICENSE "$APP/Contents/Resources/LICENSE.txt" || { echo "LICENSE.txt in the app differs from LICENSE." >&2; exit 1; }
SHIPPED=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$SHIPPED" == "$VERSION" ]] || { echo "The app says version $SHIPPED." >&2; exit 1; }

echo "==> Creating the DMG"
mkdir -p "$DIST"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/DuoBar+.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "DuoBar+" -srcfolder "$STAGE" -format UDZO -ov "$DIST/$DMG_NAME"
rm -rf "${STAGE:?}"
hdiutil verify -quiet "$DIST/$DMG_NAME"
( cd "$DIST" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" )

git add "$PBXPROJ"
if ! git diff --cached --quiet; then git commit -q -m "Release $VERSION"; fi
git tag "$TAG"
COMMITTED=1
echo "==> Built $DIST/$DMG_NAME"
cat "$DIST/$DMG_NAME.sha256"

if [[ "$PUBLISH" == "--publish" ]]; then
  NOTES="$DIST/notes-$VERSION.md"
  cat > "$NOTES" <<NOTES_TEXT
## Install

1. Download **$DMG_NAME**, open it and drag **DuoBar+** to **Applications**.
2. Open DuoBar+. macOS blocks it the first time, because the app is signed with a self-signed certificate and is not notarized by Apple.
3. Go to **System Settings → Privacy & Security** and choose **Open Anyway** next to DuoBar+.

macOS 13 or later, Apple Silicon and Intel.
NOTES_TEXT
  git push -q origin main "$TAG"
  gh release create "$TAG" "$DIST/$DMG_NAME" "$DIST/$DMG_NAME.sha256" \
    --repo "$REPO" --title "DuoBar+ $VERSION" --notes-file "$NOTES"
fi
