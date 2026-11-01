#!/bin/sh
# Xcode runs this to put Michael's voice in the app. The pack is too big for the repo, so it's a release
# asset, checked against the hash here and cached between builds. Needs `gh` signed in the first time.
set -eu
tag=voice-pack-1
file=voice-pack.tar.gz
hash=e17ba562491a1645defa1c3ed4eec43447d1501e684ff1664bab0ccc0f7a5735
cache="$HOME/Library/Caches/app.totality/voice-pack/$hash"

if [ ! -d "$cache/Voice" ]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    gh release download "$tag" --repo mckayclemens08/totality --pattern "$file" --dir "$work"
    echo "$hash  $work/$file" | shasum -a 256 --check --status || {
        echo "error: the voice pack doesn't match its hash" >&2
        exit 1
    }
    tar -xzf "$work/$file" -C "$work"
    mkdir -p "$cache"
    mv "$work/Voice" "$cache/Voice"
fi

rsync -a --delete "$cache/Voice" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"
