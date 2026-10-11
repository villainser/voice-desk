#!/bin/zsh
set -eu
cd "${0:A:h}"

destination="${1:-build/tests}"
mkdir -p "$destination"
destination="${destination:A}"
if [[ ! -f Vendor/libmp3lame.a ]]; then ./build-lame.sh; fi

sources=(Sources/*.swift)
sources=(${sources:#Sources/App.swift})
sources=(${sources:#Sources/AppModel.swift})

python3 Scripts/audit-localization.py
for suite in Tests/*Tests.swift; do
  name="${suite:t:r}"
  suite_sources=("${sources[@]}")
  if [[ "$name" == IntegrationTests ]]; then suite_sources+=(Sources/AppModel.swift); fi
  xcrun swiftc -swift-version 5 -whole-module-optimization -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$destination/module-cache" \
    -import-objc-header Vendor/lame.h -L Vendor -lmp3lame \
    "${suite_sources[@]}" "$suite" -o "$destination/$name"
  if [[ "$name" == LocalizationTests ]]; then
    "$destination/$name" "$PWD/Resources"
  elif [[ "$name" == IntegrationTests ]]; then
    "$destination/$name" --ui-test-mode
  else
    "$destination/$name"
  fi
done
