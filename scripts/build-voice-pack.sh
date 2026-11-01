#!/bin/sh
# Builds the voice pack from a folder FluidAudio has already downloaded and compiled into, which it
# checks as it goes. Run this only when the FluidAudio pin moves. Then publish the result as a GitHub
# release asset and put its new tag and hash in embed-voice-pack.sh.
#
#   scripts/build-voice-pack.sh <FluidAudio models folder> <output.tar.gz>
set -eu
models=$1
output=$2
here=$(cd "$(dirname "$0")" && pwd)
en=kokoro-82m-coreml/ANE-v3/6c0750dd02ef9d981fb82f147d784a3f171755ee/en
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Voice/$en/fast" "$work/Voice/$en/voices"
cp -R "$models/kokoro" "$work/Voice/kokoro"
for item in manifest.json base-index-v3.json vocab.json base decoder; do
    cp -R "$models/$en/$item" "$work/Voice/$en/$item"
done
cp -R "$models/$en"/fast/*.mlmodelc "$models/$en/fast/native-source.json" "$work/Voice/$en/fast/"
# FluidAudio always loads its default voice, Heart, even though only Michael speaks.
cp "$models/$en/voices/am_michael.bin" "$models/$en/voices/af_heart.bin" "$work/Voice/$en/voices/"
find "$work/Voice" -name '*.mlpackage' -prune -exec rm -rf {} +
find "$work/Voice" -name '.DS_Store' -delete
cp "$here/voice-pack/LICENSE.txt" "$here/voice-pack/NOTICE.txt" "$work/Voice/"

COPYFILE_DISABLE=1 tar -C "$work" -czf "$output" Voice
shasum -a 256 "$output"
