#!/bin/sh
set -eu
task_root="$PROJECT_DIR/.."
/usr/bin/python3 "$task_root/tool/build_converter_macos.py"
task_bundle="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
mkdir -p "$task_bundle/Helpers" "$task_bundle/Resources/ThirdParty"
cp "$task_root/build/raw_converter/shipian_raw_converter" "$task_bundle/Helpers/shipian_raw_converter"
chmod +x "$task_bundle/Helpers/shipian_raw_converter"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$task_root/native/converter.entitlements" \
  "$task_bundle/Helpers/shipian_raw_converter"
/usr/bin/ditto "$task_root/native/vendor/LibRaw-0.22.2" "$task_bundle/Resources/ThirdParty/LibRaw-0.22.2"
cp "$task_root/native/THIRD_PARTY.md" "$task_bundle/Resources/ThirdParty/THIRD_PARTY.md"
