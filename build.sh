#!/bin/bash
set -euo pipefail

PLUGIN_DIR="kuadrant-backstage-plugin"

# Set up hermetic build environment (cachi2 offline package registry proxy)
if [ -f /cachi2/cachi2.env ]; then
    source /cachi2/cachi2.env
fi

cd "${PLUGIN_DIR}"

# Install only deps needed by the two kuadrant plugins.
# The submodule yarn.lock contains ~3878 packages (full RHDH dev environment).
# workspaces focus limits installation to just what the plugins require.
yarn workspaces focus \
    @kuadrant/kuadrant-backstage-plugin-frontend \
    @kuadrant/kuadrant-backstage-plugin-backend

# Build plugins (turbo resolves transitive workspace dependencies automatically)
yarn turbo run build \
    --filter='./plugins/kuadrant' \
    --filter='./plugins/kuadrant-backend'

# Export as RHDH dynamic plugin format (creates dist-dynamic/ in each plugin dir)
yarn workspace @kuadrant/kuadrant-backstage-plugin-frontend export-dynamic
yarn workspace @kuadrant/kuadrant-backstage-plugin-backend export-dynamic

cd ..

# Collect exported plugin directories into the OCI artifact output location
mkdir -p dynamic-plugins/dist
cp -r "${PLUGIN_DIR}/plugins/kuadrant/dist-dynamic" \
      dynamic-plugins/dist/kuadrant-backstage-plugin-frontend-dynamic
cp -r "${PLUGIN_DIR}/plugins/kuadrant-backend/dist-dynamic" \
      dynamic-plugins/dist/kuadrant-backstage-plugin-backend-dynamic

# Copy LICENSE into the artifact directory (Containerfile COPY can't reach ../
# since its build context is dynamic-plugins/)
cp "${PLUGIN_DIR}/LICENSE" dynamic-plugins/LICENSE
