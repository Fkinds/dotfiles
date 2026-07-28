---
name: aube
description: |
  Use when working with the Node.js package manager `aube` (replaces pnpm/npm/yarn).
  Triggers: invocation of `aube`, `aubr`, `aubx`; presence of `aube-lock.yaml`; user mentions "aube"
  or migrating from pnpm/npm/yarn to aube; editing Dockerfiles, CI workflows, or scripts that install
  Node dependencies in this project. Skip for repos using pnpm/npm/yarn directly with no aube intent.
---

# aube — fast Node.js package manager

Site: https://aube.en.dev/ · Repo: https://github.com/endevco/aube · License: MIT

aube is a Node.js package manager (current: v1.16.0) that emphasises speed, supply-chain security,
and disk efficiency. It **reads and writes existing `pnpm-lock.yaml` / `yarn.lock` / `package-lock.json`
in place**, so a project can adopt aube without changing its lockfile format.

## Install

| Method | Command |
|---|---|
| mise (recommended) | `mise use -g aube` |
| Homebrew | `brew install endevco/tap/aube` |
| npm (global) | `npm install -g --ignore-scripts=false @endevco/aube` |
| Cargo | `cargo install aube --locked` |
| GitHub Actions | `uses: endevco/aube-action@v1` |

## Command mapping (pnpm → aube)

| pnpm | aube |
|---|---|
| `pnpm install` | `aube install` |
| `pnpm install --frozen-lockfile` | `aube ci` *(clean install, frozen lockfile — use in CI)* |
| `pnpm add <pkg>` | `aube add <pkg>` |
| `pnpm add -D <pkg>` | `aube add -D <pkg>` |
| `pnpm remove <pkg>` | `aube remove <pkg>` |
| `pnpm run <script>` | `aube run <script>` or `aubr <script>` |
| `pnpm test` | `aube test` or `aubr test` |
| `pnpm exec <bin>` | `aube exec <bin>` |
| `pnpm dlx <pkg>` | `aubx <pkg>` |
| `pnpm update [pkg]` | `aube update [pkg]` |
| `pnpm why <pkg>` | `aube why <pkg>` |
| `pnpm list` | `aube list` |

### `aubr` / `aubx`

- **`aubr <script>`** — shortcut for `aube run <script>`. Auto-installs first **only if** `package.json`
  or the lockfile changed since the last install; otherwise runs immediately.
- **`aubx <pkg>`** — shortcut for `aube dlx`, for one-off tool execution (e.g. `aubx cowsay hi`).

> Aube's auto-install means you should *not* literally translate `pnpm install && pnpm run X` into
> `aube install && aube run X` — just `aubr X` is enough.

## Lockfiles

- aube reads and writes `pnpm-lock.yaml` v9 in place. Older lockfiles: bump first with
  `npx pnpm@latest install`.
- Aube's native lockfile is `aube-lock.yaml`. Switch with `aube import` or by deleting the existing
  lockfile.
- If both aube and pnpm are used in parallel, both can write to `pnpm-lock.yaml` without conflict.

## CI usage

Recommended GitHub Actions step:

```yaml
- uses: endevco/aube-action@v1
  with:
    version: latest
    node-version: auto
    run-install: true     # runs `aube ci` after setup
```

Use `aube ci` (alias: `clean-install`) — wipes `node_modules` and installs from the locked
versions. Equivalent to `npm ci` / `pnpm install --frozen-lockfile`.

`--frozen-lockfile` is also available on `aube install`:
- `--frozen-lockfile` — error if lockfile drifts from `package.json`
- `--prefer-frozen-lockfile` — use lockfile if fresh, re-resolve when stale
- `--no-frozen-lockfile` — force re-resolution

## Docker

There is no published `endevco/aube` Docker image. Install via npm or by downloading a release
binary in your image:

```Dockerfile
FROM node:22-slim
RUN npm install -g --ignore-scripts=false @endevco/aube
# ... then `aube ci` / `aubr serve`
```

(`corepack enable pnpm` is no longer needed when aube replaces pnpm entirely.)

## Storage

aube keeps installed packages in `~/.local/share/aube/store/` (global, content-addressable) and
materialises projects under `node_modules/.aube/`. Multiple projects share the same physical files.

## Security defaults

- Trust downgrades fail at resolve
- New releases sit out a 24h cooling window
- `aube add` blocks known-malicious packages, prompts on near-zero-download installs
- Lifecycle scripts require approval (jailed builds)
- `paranoid: true` in settings turns the soft gates into hard fails

## Strict / maximum-security configuration

`paranoid: true` is the single switch that bundles:

| Forced setting | Effect |
|---|---|
| `trustPolicy=no-downgrade` | reject versions with weaker publisher attestation than prior releases |
| `jailBuilds=true` | sandbox lifecycle scripts (Seatbelt / Landlock / seccomp) |
| `minimumReleaseAgeStrict=true` | hard-fail when no version satisfies the 24h age gate |
| `strictStoreIntegrity=true` | fail if packument lacks `dist.integrity` |
| `strictDepBuilds=true` | fail when deps have unapproved build scripts |
| `advisoryCheck=required` | fail-closed on OSV malware check |

Settings not covered by `paranoid` that you may also want (this repo enables them):

| Setting | Strictest | Why |
|---|---|---|
| `advisoryCheckOnInstall` | `required` | OSV check on plain reinstalls (paranoid only covers fresh resolves) |
| `advisoryCheckEveryInstall` | `true` | even frozen reinstalls hit the live OSV API |
| `advisoryBloomCheck` | `required` | bloom-filter prefilter on every install path |
| `lowDownloadThreshold` | `10000`+ | reject more long-tail/typosquat packages |
| `strictPeerDependencies` | `true` | fail install on missing/invalid peers |
| `dangerouslyAllowAllBuilds` | `false` | never auto-approve build scripts |
| `strictSsl` | `true` | never skip TLS verification |

Example `.npmrc` (project root) for maximum strict:

```
paranoid=true
advisoryCheck=required
advisoryCheckOnInstall=required
advisoryCheckEveryInstall=true
advisoryBloomCheck=required
lowDownloadThreshold=10000
blockExoticSubdeps=true
strictStoreIntegrity=true
verifyStoreIntegrity=true
strictStorePkgContentCheck=true
trustPolicy=no-downgrade
preferFrozenLockfile=true
strictPeerDependencies=true
strictSsl=true
dangerouslyAllowAllBuilds=false
```

### Approving build scripts

`strictDepBuilds=true` makes install fail when deps want to run lifecycle scripts. After
reviewing what the script does, approve packages explicitly:

```sh
aube approve-builds              # interactive picker
aube approve-builds esbuild      # approve specific package
```

Approvals are written to `aube-workspace.yaml` (or `pnpm-workspace.yaml` if present) under
the `allowBuilds:` key — **commit this file** so CI and other devs share the allowlist.

Per-package privilege widening for jailed builds (`jailBuildPermissions` in
`aube-workspace.yaml`):

```yaml
jailBuildPermissions:
  sharp:
    env: [SHARP_DIST_BASE_URL]
    read: [~/.cache/node-gyp]
    write: [~/.cache/sharp]
    network: true
```

### Configuration precedence

1. CLI flags (`--frozen-lockfile`, ...)
2. Env vars (`AUBE_PARANOID=true`, `NPM_CONFIG_*`)
3. `.npmrc` (project / user / global)
4. `aube-workspace.yaml` / `pnpm-workspace.yaml`
5. Root `package.json` (`pnpm.*` for peer rules)

### Security scanner (optional, Bun-compatible API)

```yaml
# aube-workspace.yaml
securityScanner: "@acme/bun-security-scanner"
```

Requires Node 22.6+. Runs post-resolve, pre-download. A `fatal` advisory aborts install
with exit code 48.

### CI hardening for aube itself

- **Pin `endevco/aube-action` to a commit SHA**, not `@v1`. Tags are mutable.
- Pin `version:` to an exact aube release (e.g. `1.16.0`), not `latest`.
- In Dockerfiles, install `@endevco/aube` globally **as a non-root user** (the postinstall
  fetches a platform binary and would run as root otherwise).

## Project conventions in this repo

- Frontend lives in `client/vue-workspace/sample-vue/`.
- Lockfile kept as `pnpm-lock.yaml` (aube reads/writes it in place — no migration to
  `aube-lock.yaml` so the lockfile stays diff-friendly for reviewers familiar with pnpm).
- CI installs deps via `endevco/aube-action@v1` (see `.github/actions/setup-frontend/action.yml`).
- Docker image installs aube globally via npm, then `aube install`.
- Scripts called as `aubr <script>` in `package.json` invocations.

## References

- Guide: https://aube.en.dev/guide/
- For pnpm users: https://aube.en.dev/pnpm-users
- CLI reference: https://aube.en.dev/cli/
- Lockfiles: https://aube.en.dev/package-manager/lockfiles
- Security: https://aube.en.dev/security
