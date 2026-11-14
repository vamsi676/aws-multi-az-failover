#!/usr/bin/env bash
# Build the CodeDeploy bundle: dist/taskboard-<version>.zip
# Dependencies are vendored for Linux x86_64 / CPython 3.11, so instances never run pip.
#
# Usage: scripts/build_app.sh [version]        (default: short git SHA)
#        PYTHON=/path/to/python scripts/build_app.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
DIST_DIR="${ROOT_DIR}/dist"
PYTHON="${PYTHON:-python3}"

VERSION="${1:-$(git -C "$ROOT_DIR" rev-parse --short HEAD)}"
if ! git -C "$ROOT_DIR" diff --quiet -- app 2>/dev/null && [[ $# -eq 0 ]]; then
  VERSION="${VERSION}-dirty"
fi

STAGE="${DIST_DIR}/bundle"
ZIP="${DIST_DIR}/taskboard-${VERSION}.zip"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"

cp "${APP_DIR}/appspec.yml" "$STAGE/"
cp -R "${APP_DIR}/taskboard" "${APP_DIR}/codedeploy" "${APP_DIR}/config" "$STAGE/"
echo "$VERSION" > "${STAGE}/VERSION"
chmod +x "$STAGE"/codedeploy/*.sh

"$PYTHON" -m pip install --quiet --disable-pip-version-check \
  --target "${STAGE}/vendor" \
  --platform manylinux2014_x86_64 \
  --python-version 3.11 \
  --implementation cp \
  --only-binary=:all: \
  -r "${APP_DIR}/requirements.txt"

find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$STAGE" -name '*.pyc' -delete

(cd "$STAGE" && zip -qr -X "$ZIP" .)
rm -rf "$STAGE"

echo "$ZIP"
