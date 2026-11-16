#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h:h}"
flutter pub get
flutter analyze
python3 tool/build_converter_macos.py
flutter test
flutter build macos --release
# Re-seal the local test bundle after Flutter updates its nested App.framework.
codesign --force --sign - --preserve-metadata=entitlements,flags,runtime 'build/macos/Build/Products/Release/拾片.app'
codesign --verify --deep --strict 'build/macos/Build/Products/Release/拾片.app'
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent 'build/macos/Build/Products/Release/拾片.app' 'dist/ShiPian-macOS.zip'
print '已生成 dist/ShiPian-macOS.zip'
