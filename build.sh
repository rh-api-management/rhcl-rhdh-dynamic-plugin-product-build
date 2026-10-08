#!/bin/bash
set -euo pipefail

PLUGIN_DIR="kuadrant-backstage-plugin"

# Set up hermetic build environment (cachi2 sets YARN_GLOBAL_FOLDER to the prefetched cache)
if [ -f /cachi2/cachi2.env ]; then
	source /cachi2/cachi2.env
fi

# @swc/core 1.16+ ships "native addon carriers": on first load it materializes
# the real binary into a cache dir ($HOME/.cache by default) and refuses if that
# cache root's parent is writable by another user without the sticky bit. In the
# run-script-oci-ta runner $HOME is /opt/app-root/src (group-writable, no sticky),
# so rhdh-cli's swc-loader fails with "Failed to load native binding" when it
# builds the scalprum assets. Point the cache at a private temp dir (parent /tmp
# is sticky) so materialization is allowed.
export SWC_NATIVE_BINDING_CACHE="$(mktemp -d)"

# Build directly from the kuadrant-backstage-plugin submodule using its own
# upstream-tested yarn.lock (no regenerated/minimal lockfile to drift). The
# build-workspace/ overlay — which cachi2 prefetched from — is nothing but an
# x64/linux .yarnrc.yml plus symlinks into the submodule. Copy that .yarnrc.yml
# over the submodule's own (multi-arch) one so the build installs exactly the
# x64/linux package set that was prefetched, and so yarn picks up the cachi2
# globalFolder config that was patched into it during prefetch.
cp build-workspace/.yarnrc.yml "${PLUGIN_DIR}/.yarnrc.yml"

cd "${PLUGIN_DIR}"

# Installs into the submodule root node_modules, so tools (backstage-cli,
# rhdh-cli) running from the real plugin paths resolve the hoisted packages by
# walking up to the submodule root — no node_modules symlink juggling needed.
yarn install --immutable

# Build frontend first — backend imports frontend's shared permission types.
yarn workspace @kuadrant/kuadrant-backstage-plugin-frontend build
yarn workspace @kuadrant/kuadrant-backstage-plugin-backend build

# Pre-seed the backend's dist-dynamic/yarn.lock so rhdh-cli's internal
# `yarn install --immutable` runs offline (no network, lockfile must be exact).
# The frontend is bundled via scalprum/webpack and installs no dynamic deps, so
# only the backend needs this. We prune the submodule's full lockfile down to the
# backend's customized dynamic manifest by running a throwaway install:
#   - resolution reuses the submodule yarn.lock (everything already resolved)
#   - the submodule root resolutions must be carried along, otherwise yarn would
#     re-resolve the pinned ranges (zod, etc.) and reach for the registry
#   - fetch uses the cachi2 global cache (no network)
_dist_prep=$(mktemp -d)
node --input-type=module << NODEJS_EOF
import { readFileSync, writeFileSync } from 'fs';
const pkg = JSON.parse(readFileSync('./plugins/kuadrant-backend/package.json'));
const root = JSON.parse(readFileSync('./package.json'));
// Mirror rhdh-cli customizeForDynamicUse: move @backstage/* (and any
// --shared-package from the export-dynamic script) from deps to peerDeps so the
// temp manifest matches what rhdh-cli writes to dist-dynamic/package.json.
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
    resolutions: root.resolutions || {},
  }, null, 2));
NODEJS_EOF
cp yarn.lock "${_dist_prep}/yarn.lock"
cp .yarnrc.yml "${_dist_prep}/.yarnrc.yml"
(cd "${_dist_prep}" && yarn install --no-immutable)
mkdir -p ./plugins/kuadrant-backend/dist-dynamic
cp "${_dist_prep}/yarn.lock" ./plugins/kuadrant-backend/dist-dynamic/yarn.lock
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

cd ..

# Collect exported plugin directories into the OCI artifact output location.
mkdir -p dynamic-plugins/dist
cp -r "${PLUGIN_DIR}/plugins/kuadrant/dist-dynamic" \
	dynamic-plugins/dist/kuadrant-backstage-plugin-frontend-dynamic
cp -r "${PLUGIN_DIR}/plugins/kuadrant-backend/dist-dynamic" \
	dynamic-plugins/dist/kuadrant-backstage-plugin-backend-dynamic

# Copy LICENSE into the artifact directory (Containerfile COPY can't reach ../
# since its build context is dynamic-plugins/)
cp "${PLUGIN_DIR}/LICENSE" dynamic-plugins/LICENSE
