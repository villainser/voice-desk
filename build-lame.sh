#!/bin/zsh
set -eu
cd "${0:A:h}"
repo="$PWD"
mkdir -p build/lame-rebuild
# Vendored upstream 3.100 source; builds locally with Apple's command line tools.
tar -xzf Vendor/lame-3.100.tar.gz -C build/lame-rebuild
cd build/lame-rebuild/lame-3.100
./configure --disable-shared --disable-frontend --host=aarch64-apple-darwin CFLAGS='-O2 -mmacosx-version-min=14.0'
make -j4
cp libmp3lame/.libs/libmp3lame.a "$repo"/Vendor/libmp3lame.a
cp include/lame.h "$repo"/Vendor/lame.h
