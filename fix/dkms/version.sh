#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Print the package version, derived from the nearest v* git tag:
#   at tag v1.1.0               -> 1.1.0
#   3 commits after v1.1.0      -> 1.1.0+3.gabc1234
#   uncommitted changes         -> ... + ".dirty"
#   no v* tag / no git checkout -> 0.0.0+g<hash> / 0.0.0+unknown
# $VERSION, if set, wins.
set -euo pipefail

if [[ -n ${VERSION:-} ]]; then
    echo "$VERSION"
    exit 0
fi
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
if ! git -C "$HERE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "0.0.0+unknown"
    exit 0
fi
if desc=$(git -C "$HERE" describe --tags --match 'v[0-9]*' --abbrev=7 2>/dev/null); then
    # v1.1.0 or v1.1.0-3-gabc1234
    version=$(sed -E 's/^v//; s/-([0-9]+)-(g[0-9a-f]+)$/+\1.\2/' <<<"$desc")
else
    version="0.0.0+g$(git -C "$HERE" rev-parse --short=7 HEAD)"
fi
if [[ -n $(git -C "$HERE" status --porcelain --untracked-files=no -- .) ]]; then
    version+=".dirty"
fi
echo "$version"
