#!/usr/bin/env bash
# Build the AgentCore Runtime direct-code-deploy package (Linux arm64, Python 3.12).
# Output: dist/support-mcp-agentcore.zip   (main.py + awslabs/ + site-packages at zip root)
set -euo pipefail
cd "$(dirname "$0")"
PY=3.12
rm -rf dist/pkg && mkdir -p dist/pkg
# Install from the fully pinned lock when present (reproducible builds); fall back to the
# top-level requirements only when regenerating the lock after a dependency change.
REQ=app/requirements.lock; [ -f "$REQ" ] || REQ=app/requirements.txt
uv pip install \
  --python-platform aarch64-manylinux2014 \
  --python-version "$PY" \
  --target dist/pkg \
  --only-binary=:all: \
  -r "$REQ"
cp app/main.py dist/pkg/
cp -R app/awslabs dist/pkg/
find dist/pkg -name '__pycache__' -type d -prune -exec rm -rf {} +
( cd dist/pkg && zip -qr ../support-mcp-agentcore.zip . )
echo "built: dist/support-mcp-agentcore.zip ($(du -h dist/support-mcp-agentcore.zip | cut -f1))"
