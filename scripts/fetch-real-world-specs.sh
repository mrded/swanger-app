#!/bin/sh
# Downloads the large public spec RealWorldSpecTests loads, GitHub's REST API (MIT, 13 MB), at a
# pinned commit into .build/real-world-specs/. It's too big to keep in the repo. A file already
# there with the right checksum isn't downloaded again.
#
# To move to a newer version, change the commit, delete the file, run this once with
# SKIP_CHECKSUM=1 and put the printed checksum here.
set -eu

dir="${REAL_WORLD_SPECS:-.build/real-world-specs}"
mkdir -p "$dir"

fetch() {
  name=$1 url=$2 sha256=$3
  file="$dir/$name"
  if [ -f "$file" ] && echo "$sha256  $file" | shasum -a 256 -c --status; then
    echo "$name: up to date"
    return
  fi
  echo "$name: downloading $url"
  curl --fail --silent --show-error --location --retry 3 --output "$file.part" "$url"
  actual=$(shasum -a 256 "$file.part" | cut -d ' ' -f 1)
  if [ "$actual" != "$sha256" ] && [ -z "${SKIP_CHECKSUM:-}" ]; then
    echo "$name: checksum is $actual, expected $sha256" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
  echo "$name: $actual"
}

# https://github.com/github/rest-api-description (MIT)
fetch github.json \
  https://raw.githubusercontent.com/github/rest-api-description/755ee33b4a81d51f6f07a902cce26cbec3b822f2/descriptions/api.github.com/api.github.com.json \
  3177ad6a86ca04c57a9bef3fc24e28a339efb8eb040c6f950af3d3ed2fee7fa3
