# scripts/

`verify-release.sh` checks a built release package before it is uploaded. It is a single
file (bash wrapper + Python 3.8+ standard library, no pip packages) and runs in CI through
`.github/workflows/verify-release.yml` on every push to main, pull request and `v*` tag.

It checks, against this repo's docs:

1. the plugin: ESL flag, a clean TES4/GRUP walk, every own FormID in 0x800-0xFFF, HEDR counts
2. that CHANGELOG, README status, the packaged `fomod/info.xml` and `<moduleName>`,
   `docs/NEXUS_*.md`, the tag and the zip name all carry the same version
3. no stray files (VCS, temp, OS junk, secrets, executables, nested archives, absolute paths)
   and a consistent FOMOD (every source present, every shipped file installed by something)
4. no Bethesda files (vanilla archives, masters, strings, voice, scripts, tool binaries)
5. Papyrus: PEX files parse, no literal backslash escapes in strings, sources match, script
   and EditorID prefixes do not collide with the sibling mods
6. masters are base game or declared in the README / Nexus docs

## Run it locally

```
./build.sh && ./scripts/verify-release.sh --dist dist
```

Useful options: `--tag v1.2.3`, `--strict` (warnings fail too), `--quiet`, `--json report.json`,
`--others ../other-mod/dist` (name collisions with another mod), `--help` for the rest.
Waivers go in `.verify-release.allow` at the repo root (`allow-master NAME`, `allow-large GLOB`).

Exit codes: `0` pass, `1` at least one FAIL (or a WARN with `--strict`), `2` usage or input
error (no zip, unreadable zip, bad arguments).

## Do not edit here

This file and `verify-release.sh` are identical copies of the canonical ones in
[synthalorian/.github](https://github.com/synthalorian/.github) (`templates/scripts-README.md`,
`scripts/verify-release.sh`). Edit them there, then re-sync every mod repo. The CI drift step
warns when the copy here differs from the canonical script. Full documentation:
`docs/verify-release.md` in synthalorian/.github.
