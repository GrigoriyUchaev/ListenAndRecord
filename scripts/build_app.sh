#!/bin/bash
# Собирает ListenAndRecord.app (нужны только Command Line Tools: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ Сборка (release, Apple Silicon)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/ListenAndRecord.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ListenAndRecord" "$APP/Contents/MacOS/ListenAndRecord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Подпись: по умолчанию ad-hoc. Если есть сертификат разработчика, можно указать его:
#   SIGN_IDENTITY="Apple Development: Имя (XXXXXXXXXX)" ./scripts/build_app.sh
# (тогда macOS не будет заново спрашивать разрешения после каждой пересборки).
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"

echo "✅ Готово: $APP"
echo "   Установить:  cp -R \"$APP\" /Applications/"
