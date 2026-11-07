#!/bin/bash
# CT-079: a manual release must publish an EXISTING tag that points at the
# exact commit being built. A missing or mis-pointed tag fails loudly — a
# manual dispatch never fabricates a tag for the wrong commit.
#
# Usage: validate_release_tag.sh <tag> <expected-commit>
set -euo pipefail

TAG="${1:-}"
EXPECTED="${2:-}"
[ -n "$TAG" ] || { echo "usage: $0 <tag> <expected-commit>" >&2; exit 2; }
[ -n "$EXPECTED" ] || { echo "usage: $0 <tag> <expected-commit>" >&2; exit 2; }

TAG_COMMIT="$(git rev-parse --verify --quiet "refs/tags/${TAG}^{commit}")" \
  || { echo "release tag 不存在：$TAG — 请先创建并推送该 tag" >&2; exit 1; }

if [ "$TAG_COMMIT" != "$EXPECTED" ]; then
  echo "release tag $TAG 指向 $TAG_COMMIT，与构建 commit $EXPECTED 不一致" >&2
  exit 1
fi

echo "release tag verified: $TAG -> $TAG_COMMIT"
