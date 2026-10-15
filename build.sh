#!/bin/bash
# Baut EmojiSearch12 und packt das .deb.
#   tools/fetch_deps.sh && ./build.sh
#   (oder SDK=/pfad/iPhoneOS12.4.sdk CLDR=/pfad/zu/cldr ./build.sh)
set -euo pipefail
cd "$(dirname "$0")"
SDK="${SDK:-deps/sdks/iPhoneOS12.4.sdk}"
CLDR="${CLDR:-deps/cldr}"
[ -d "$SDK" ] || { echo "SDK fehlt: tools/fetch_deps.sh ausführen oder SDK=… setzen"; exit 1; }
[ -f "$CLDR/emoji-test.txt" ] || { echo "CLDR-Daten fehlen: tools/fetch_deps.sh ausführen oder CLDR=… setzen"; exit 1; }
OUT=build; rm -rf "$OUT"; mkdir -p "$OUT"
STAGE="$OUT/stage"
DYLIB_DIR="$STAGE/Library/MobileSubstrate/DynamicLibraries"
DATA_DIR="$STAGE/Library/Application Support/EmojiSearch12"
mkdir -p "$DYLIB_DIR" "$DATA_DIR" "$STAGE/DEBIAN"

"${CC:-clang}" -target arm64-apple-ios12.0 -isysroot "$SDK" -fobjc-arc -O2 -Wall -Wno-unused-function \
  -fno-objc-msgsend-selector-stubs -dynamiclib \
  -install_name /Library/MobileSubstrate/DynamicLibraries/EmojiSearch12.dylib \
  -framework Foundation -framework UIKit -framework CoreText -framework CoreGraphics -framework QuartzCore \
  -o "$DYLIB_DIR/EmojiSearch12.dylib" src/Tweak.m
ldid -S "$DYLIB_DIR/EmojiSearch12.dylib"
cat > "$DYLIB_DIR/EmojiSearch12.plist" <<'PL'
{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }
PL

CLDR_VERSION="${CLDR_VERSION:-48.2.0}" python3 -I tools/gen_emoji_data.py "$CLDR/emoji-test.txt" \
  "$CLDR/cldr-annotations-full/package" "$CLDR/cldr-annotations-derived-full/package" "$DATA_DIR"
cp LICENSE-Unicode.txt "$DATA_DIR/LICENSE-Unicode.txt"
mkdir -p "$STAGE/Library/PreferenceLoader/Preferences"
cp prefs/EmojiSearch12.plist prefs/EmojiSearch12*.png "$STAGE/Library/PreferenceLoader/Preferences/"
cp package/DEBIAN/control "$STAGE/DEBIAN/control"
python3 -I tools/mkdeb.py "$STAGE" "$OUT"
