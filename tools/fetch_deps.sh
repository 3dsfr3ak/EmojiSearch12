#!/bin/bash
# Lädt iOS-SDK und Emoji-/CLDR-Daten nach ./deps
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p deps/cldr
if [ ! -d deps/sdks/iPhoneOS12.4.sdk ]; then
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git deps/sdks
  git -C deps/sdks sparse-checkout set iPhoneOS12.4.sdk
fi
CLDR_VERSION="${CLDR_VERSION:-48.2.0}"
for p in cldr-annotations-full cldr-annotations-derived-full; do
  if [ ! -d "deps/cldr/$p" ]; then
    mkdir -p "deps/cldr/$p"
    curl -sfL "https://registry.npmjs.org/$p/-/$p-$CLDR_VERSION.tgz" | tar xz -C "deps/cldr/$p"
  fi
done
[ -f deps/cldr/emoji-test.txt ] || curl -sfLo deps/cldr/emoji-test.txt https://unicode.org/Public/emoji/latest/emoji-test.txt
echo "deps bereit"
