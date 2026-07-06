# packaging/

Konflux product build entry point for the Kuadrant RHDH dynamic plugins. A
standalone yarn workspace covering only the two plugin packages from the
`kuadrant-backstage-plugin` submodule.

## Why this exists

The submodule's root `yarn.lock` covers the entire RHDH application (~3878
packages) because it is an rhdh-local fork used for local development. The
Konflux hermetic build (cachi2 prefetch) only needs the plugin dependencies,
roughly 1000 packages.

This directory provides a minimal yarn workspace root that cachi2 can read
without pulling in the full RHDH dependency tree.

## Contents

- `package.json` — workspace root referencing the two plugin packages
- `yarn.lock` — generated lockfile covering only plugin transitive dependencies
- `.yarnrc.yml` — build-appropriate settings (x64/linux, node-modules linker)
- `plugins/kuadrant` — symlink to `../../kuadrant-backstage-plugin/plugins/kuadrant`
- `plugins/kuadrant-backend` — symlink to `../../kuadrant-backstage-plugin/plugins/kuadrant-backend`

## Keeping it in sync

When you update dependencies in either plugin's `package.json` (in the
submodule), you must also regenerate `packaging/yarn.lock` from this repo:

```bash
cd packaging
yarn install
git add yarn.lock
git commit -m "update packaging/yarn.lock"
```
