#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

version="${1:?usage: release.sh <version>}"
tap="../homebrew-tap"

swift test
Scripts/bundle.sh "$version"
rm -f dist/MSGViewer.app.zip
ditto -c -k --keepParent dist/MSGViewer.app dist/MSGViewer.app.zip

git push origin main
git tag -a "v$version" -m "MSGViewer v$version"
git push origin "v$version"
gh release create "v$version" dist/MSGViewer.app.zip --title "MSGViewer v$version" --generate-notes
"$tap/bump.sh" msgviewer "$version"
