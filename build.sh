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

# cachi2 patches packaging/.yarnrc.yml with globalFolder before this task runs.
# rhdh-cli's 'yarn install --immutable' inside dist-dynamic/ walks up:
# plugins/kuadrant-backend/dist-dynamic/ → plugins/kuadrant-backend/ →
# plugins/ → kuadrant-backstage-plugin/ (unpatched root .yarnrc.yml).
# Copy the patched file one level above plugins/ so yarn finds the cachi2
# globalFolder config before hitting the unpatched submodule root.
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

# rhdh-cli detects an existing dist-dynamic/yarn.lock and switches yarn to
# --immutable (no network, lockfile must be exact). We pre-seed a MINIMAL
# lockfile by running yarn install --no-immutable in a temp dir:
#   - resolution uses packaging/yarn.lock (all packages already resolved, no registry)
#   - fetch uses cachi2 global cache (no network)
#   - yarn prunes the 2732-entry lockfile down to only what the 6 private deps need
# The pruned lockfile is then copied to dist-dynamic/ for rhdh-cli's --immutable install.
_dist_prep=$(mktemp -d)
node --input-type=module << NODEJS_EOF
import { readFileSync, writeFileSync } from 'fs';
const pkg = JSON.parse(readFileSync('../plugins/kuadrant-backend/package.json'));
// Mirror rhdh-cli customizeForDynamicUse: move @backstage/* from deps to peerDeps,
// AND move any packages listed in --shared-package in the export-dynamic script.
// The temp package.json must have the EXACT same name/deps/peerDeps as what
// rhdh-cli writes to dist-dynamic/package.json so the workspace lockfile entry
// matches and yarn install --immutable does not see a modification.
const exportScript = pkg.scripts?.['export-dynamic'] || '';
const userShared = [...exportScript.matchAll(/--shared-package\s+([^\s!][^\s]*)/g)]
  .map(m => m[1]);
const isShared = n => n.startsWith('@backstage/') || userShared.includes(n);

const allDeps = pkg.dependencies || {};
const movedToPeer = Object.fromEntries(Object.entries(allDeps).filter(([n]) => isShared(n)));
const remainingDeps = Object.fromEntries(Object.entries(allDeps).filter(([n]) => !isShared(n)));
const allPeers = { ...(pkg.peerDependencies || {}), ...movedToPeer };
writeFileSync('${_dist_prep}/package.json',
  JSON.stringify({
    name: pkg.name + '-dynamic',
    private: true,
    dependencies: remainingDeps,
    peerDependencies: allPeers,
  }, null, 2));
NODEJS_EOF
cp yarn.lock "${_dist_prep}/yarn.lock"
cp .yarnrc.yml "${_dist_prep}/.yarnrc.yml"
(cd "${_dist_prep}" && yarn install --no-immutable)
mkdir -p ../plugins/kuadrant-backend/dist-dynamic
cp "${_dist_prep}/yarn.lock" ../plugins/kuadrant-backend/dist-dynamic/yarn.lock
rm -rf "${_dist_prep}"

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
