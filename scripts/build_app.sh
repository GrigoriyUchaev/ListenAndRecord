#!/bin/bash
# Собирает ListenAndRecord.app (нужны только Command Line Tools: xcode-select --install).
# whisper.cpp встраивается в приложение автоматически — ставить его отдельно не нужно.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ Сборка (release, Apple Silicon)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/ListenAndRecord.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/ListenAndRecord" "$APP/Contents/MacOS/ListenAndRecord"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Встраиваем whisper.framework (распознаватель речи с ускорением Metal).
FRAMEWORK="$(find .build -type d -path '*macos-arm64_x86_64/whisper.framework' -prune | head -n 1)"
if [ -z "$FRAMEWORK" ]; then
    echo "❌ Не найден whisper.framework в .build" >&2
    exit 1
fi
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/whisper.framework"
rm -rf "$APP/Contents/Frameworks/whisper.framework/Versions/A/Headers" \
       "$APP/Contents/Frameworks/whisper.framework/Headers" \
       "$APP/Contents/Frameworks/whisper.framework/Versions/A/Modules" \
       "$APP/Contents/Frameworks/whisper.framework/Modules"
if ! otool -l "$APP/Contents/MacOS/ListenAndRecord" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ListenAndRecord"
fi

# Подпись: по умолчанию ad-hoc. Если есть сертификат разработчика, можно указать его:
#   SIGN_IDENTITY="Apple Development: Имя (XXXXXXXXXX)" ./scripts/build_app.sh
# (тогда macOS не будет заново спрашивать разрешения после каждой пересборки).
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" "$APP"

echo "✅ Готово: $APP"
echo "   Установить:  rm -rf /Applications/ListenAndRecord.app && cp -R \"$APP\" /Applications/"
