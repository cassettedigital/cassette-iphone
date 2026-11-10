#!/bin/sh
# Tag the commit a shipped build was made from as cassette-ios-<version>-<build>: the app's About > Source code
# opens that tag (BUG-889), so every build that goes to anyone, TestFlight included, needs one. The version and
# build are the ones the app shows in About (MARKETING_VERSION and CURRENT_PROJECT_VERSION at archive time).
#
#   BuildTools/tag-shipped-build.sh <version> <build> [commit]     then: git push origin cassette-ios-<version>-<build>
set -eu
if [ $# -lt 2 ]; then
  echo "usage: $0 <version> <build> [commit]" >&2
  exit 2
fi
version="$1"
build="$2"
commit="${3:-HEAD}"
tag="cassette-ios-$version-$build"
git tag -a "$tag" -m "Cassette for iPhone $version ($build)" "$commit"
echo "tagged $tag at $(git rev-parse --short "$commit"); push it with: git push origin $tag"
