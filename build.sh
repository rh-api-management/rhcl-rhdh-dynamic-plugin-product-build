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

# cachi2 patches packaging/.yarnrc.yml with globalFolder/npmRegistryServer before
# this task runs. rhdh-cli's 'yarn install --no-immutable' inside dist-dynamic/
# walks up: plugins/kuadrant-backend/dist-dynamic/ → plugins/kuadrant-backend/ →
# plugins/ → kuadrant-backstage-plugin/ (unpatched). Copy the patched file one
# level above the plugins so yarn finds the cachi2 config before the unpatched one.
cp .yarnrc.yml ../plugins/.yarnrc.yml

# Linux getcwd() resolves symlinks to real paths, so tools (backstage-cli,
# rhdh-cli) running with cwd=plugins/kuadrant (real path) walk up ancestors
# that never reach packaging/node_modules. Symlinking it one level up makes
# the hoisted packages findable from both real plugin paths.
ln -sf "packaging/node_modules" "../node_modules"

# Generate TypeScript declaration files (.d.ts) required by export-dynamic.
# Uses packaging/tsconfig.json (not a symlink) with preserveSymlinks:true so
# @backstage/cli extends correctly and module resolution finds packaging/node_modules/.
# outDir:"../dist-types" places .d.ts files where rhdh-cli plugin export expects them.
yarn tsc

# Build frontend first — backend imports frontend's shared permission types.
yarn workspace @kuadrant/kuadrant-backstage-plugin-frontend build
yarn workspace @kuadrant/kuadrant-backstage-plugin-backend build

# Export as RHDH dynamic plugin format (creates dist-dynamic/ in each plugin dir)
yarn workspace @kuadrant/kuadrant-backstage-plugin-frontend export-dynamic
yarn workspace @kuadrant/kuadrant-backstage-plugin-backend export-dynamic || {
  # Print rhdh-cli's hidden yarn-install.log to surface the actual yarn error
  find /var/workdir/source -name "yarn-install.log" 2>/dev/null | while IFS= read -r log; do
    printf '=== %s ===\n' "$log"
    cat "$log"
  done
  exit 1
}

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
