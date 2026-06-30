#!/bin/bash
set -euo pipefail

PLUGIN_DIR="kuadrant-backstage-plugin"

# Set up hermetic build environment (cachi2 offline package registry proxy)
if [ -f /cachi2/cachi2.env ]; then
    source /cachi2/cachi2.env
fi

# Use the packaging/ sub-project — its yarn.lock covers only the two plugin
# workspaces (~300 packages) rather than the full rhdh-local lockfile (~3878).
# yarn install --immutable skips the resolution step (no network calls needed).
cd "${PLUGIN_DIR}/packaging"

yarn install --immutable

# Build frontend first — backend imports frontend's shared permission types.
yarn workspace @kuadrant/kuadrant-backstage-plugin-frontend build
yarn workspace @kuadrant/kuadrant-backstage-plugin-backend build

# Export as RHDH dynamic plugin format (creates dist-dynamic/ in each plugin dir)
yarn workspace @kuadrant/kuadrant-backstage-plugin-frontend export-dynamic
yarn workspace @kuadrant/kuadrant-backstage-plugin-backend export-dynamic

cd ../..

# Collect exported plugin directories into the OCI artifact output location.
# dist-dynamic/ is created at the real plugin paths (packaging/plugins/* are symlinks).
mkdir -p dynamic-plugins/dist
cp -r "${PLUGIN_DIR}/plugins/kuadrant/dist-dynamic" \
      dynamic-plugins/dist/kuadrant-backstage-plugin-frontend-dynamic
cp -r "${PLUGIN_DIR}/plugins/kuadrant-backend/dist-dynamic" \
      dynamic-plugins/dist/kuadrant-backstage-plugin-backend-dynamic

# Copy LICENSE into the artifact directory (Containerfile COPY can't reach ../
# since its build context is dynamic-plugins/)
cp "${PLUGIN_DIR}/LICENSE" dynamic-plugins/LICENSE
