#!/usr/bin/env bash
#
# Test, build, tag, and publish a GitHub release, then update Homebrew.
#
#   ./release.sh <version>          e.g. ./release.sh 0.1.11
#
set -euo pipefail
cd "$(dirname "$0")"

version="${1:?usage: ./release.sh <version>}"
name="msgviewer"
tag="v$version"
tap="../homebrew-tap"

command -v gh >/dev/null || { echo "✗ gh not found" >&2; exit 1; }
gh auth status >/dev/null

branch="$(git symbolic-ref --quiet --short HEAD)" || { echo "✗ not on a branch" >&2; exit 1; }
[ "$branch" = main ] || { echo "✗ current branch must be main (found $branch)" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "✗ working tree must be clean" >&2; exit 1; }

git fetch origin main --tags
git push origin main

swift test
Scripts/bundle.sh "$version"
rm -f dist/MSGViewer.app.zip
ditto -c -k --keepParent dist/MSGViewer.app dist/MSGViewer.app.zip

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "MSGViewer $tag"
git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1 || git push origin "$tag"
gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" dist/MSGViewer.app.zip --title "MSGViewer $tag" --generate-notes

if [ -f "$tap/Formula/$name.rb" ] || [ -f "$tap/Casks/$name.rb" ]; then
  "$tap/bump.sh" "$name" "$version"
else
  echo "△ no Homebrew entry for $name — skipping tap bump"
fi
echo "✓ released MSGViewer $tag"
