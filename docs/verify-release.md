# verify-release

`scripts/verify-release.sh` is the release verifier for the Blackshield Skyrim SE mods. It
takes the FOMOD zip that `build.sh` produced (or an unpacked package tree), reads the mod
repo it was built from, and fails if the package is not fit to upload: a broken or non-ESL
plugin, versions that disagree, stray or secret files, Bethesda files, Papyrus string
escapes, name collisions with the sibling mods, or undeclared masters.

The file is a bash/Python polyglot: the first two lines make bash `exec python3` on the same
file, Python reads the second line as a no-op string. Everything else is Python 3.8+ using
only the standard library (zipfile, struct, zlib, xml.etree, re, hashlib, fnmatch, argparse,
json, subprocess for `git`). No pip packages.

## Usage

```
verify-release.sh --zip FILE | --dist DIR   [--repo DIR (default .)] [--tag vX.Y.Z]
                  [--allow-master NAME]... [--allow-large GLOB]... [--max-file-mb N (default 25)]
                  [--others PKG...] [--deny-hashes FILE] [--json FILE] [--summary FILE]
                  [--strict] [--quiet]
verify-release.sh --collisions PKG [PKG ...] [--json FILE]
verify-release.sh --version | --help
```

- `--dist DIR`: DIR must hold exactly one `*.zip` (several is an error: pick one with `--zip`),
  or be an unpacked package tree (it has `fomod/`).
- `PKG` (for `--collisions` and `--others`): a zip, an unpacked tree, or a directory of zips.
- `<zip>.sha256` next to the zip is verified when present (`PKG-SHA256`); absence is fine.
- `--tag`: compared with the other version sources after stripping a leading `v`. If the tag
  exists in the local repo and does not point at `HEAD`, that is a WARN (`VER-TAG-COMMIT`).
- `--json FILE` writes a machine-readable report; `--summary FILE` appends GitHub-flavored
  markdown (pass `$GITHUB_STEP_SUMMARY`). With `GITHUB_ACTIONS=true` every FAIL/WARN is also
  printed as an `::error::`/`::warning::` annotation.
- `--strict`: WARN findings fail the run. `--quiet`: only FAIL/WARN lines and the result.

Locally, from a mod repo: `./build.sh && ./scripts/verify-release.sh --dist dist`.

### Output

```
== 1. ESL / plugin structure
[ ok ] ESL-FLAG: ContractHunter.esp is ESL-flagged (flags 0x200)
[FAIL] ESL-RANGE 00 Core/X.esp: GLOB objectid 001000 X_Thing outside 0x800-0xFFF
[WARN] BETH-VANILLA-PATH 00 Core/Meshes/Armor/x.nif: asset under a vanilla folder: ...
[ALLOWED] MASTER-UNDECLARED 00 Core/X.esp: master Foo.esp is allowlisted
...
RESULT: FAIL (1 fail, 1 warn)
```

Findings are grouped under the six check headings. `[info]` lines are context only.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | PASS: no FAIL (WARNs allowed unless `--strict`) |
| 1 | FAIL: at least one FAIL finding, or a WARN with `--strict`; in collision mode, a duplicate name |
| 2 | usage or input error: bad arguments, missing package, a file that is not a zip, `--dist` with 0 or several zips, unreadable `--deny-hashes` |

Malformed content inside a readable package (truncated plugin, bad PEX, bad XML) never
crashes the script: it becomes a FAIL finding. A check that hits an unexpected error reports
`CHECK-ERROR` and the run fails.

## Checks

### 1. ESL / plugin structure

Every `.esp`/`.esm`/`.esl` in the package (vanilla and Creation Club names are left to check 4)
is walked like `tools/modkit/esp_check.py`: TES4 header, every GRUP and record, sizes must add
up exactly, compressed records must inflate to their declared size, subrecord sizes must fit
(the `XXXX` large-subrecord marker is handled).

| Code | Level | When |
|---|---|---|
| `ESL-FLAG` | FAIL | TES4 flag 0x200 not set |
| `PLUGIN-STRUCT` | FAIL | not a TES4 plugin, truncated, sizes do not add up, record does not inflate, bad subrecord |
| `ESL-RANGE` | FAIL | an own record (master index == number of masters) has objectid outside 0x800-0xFFF (every offender listed, capped at 25 lines plus a total), or more than 2048 own records. Applies when the ESL flag is set or the docs claim ESL (`ESL` in README.md / docs/NEXUS_FIELDS.md) |
| `PLUGIN-HEDR` | FAIL | HEDR record count != records + groups; next object id above 0xFFF (ESL) |
| `PLUGIN-HEDR` | WARN | HEDR version not 1.70/1.71 |
| `PLUGIN-FORMID` | FAIL | FormID master index greater than the number of masters |
| `OVERRIDE-CLAIM` | FAIL | the plugin overrides master records but the docs say "No vanilla records edited" / "zero overrides" / "edits no vanilla records" / "No edits to vanilla records" |

The number of overrides is always printed as info.

### 2. Version consistency

Sources, all of which must agree (each mismatch is a `VER-MISMATCH` FAIL naming both values
and where they came from; the first source found is the reference, normally CHANGELOG.md):

| Source | Rule |
|---|---|
| `CHANGELOG.md` | first `## [x.y.z]` heading, skipping `[Unreleased]`; needs a `YYYY-MM-DD` date (`VER-CHANGELOG`) |
| `README.md` | `**Status: vX.Y.Z` (missing: WARN `VER-README`) |
| package `fomod/info.xml` | rendered `<Version>`; missing is `VER-INFO-MISSING`, `@VERSION@` left in is `VER-UNRENDERED` |
| package `fomod/ModuleConfig.xml` | `<moduleName>` must contain the version (`VER-MODULENAME`) |
| repo `fomod/info.xml` | `@VERSION@` placeholder accepted; a literal version must match |
| `docs/NEXUS_FIELDS.md` | `Version:`, `- File: Name-X.zip`, `- File version:` (a missing line is WARN `VER-NEXUS-FIELD`) |
| `docs/NEXUS_PAGE.md` | `- **Version:** X` |
| `--tag` | leading `v` stripped |
| zip file name | `<Name>-<x.y.z>.zip` (`VER-ZIPNAME` FAIL if not; WARN if Name is not a plugin stem) |

A NEXUS file that exists but is empty or holds no version is a FAIL (`VER-NEXUS-EMPTY`).
Missing NEXUS files are skipped. The table of sources is printed under the check.

### 3. Stray files and FOMOD structure

| Code | Level | When |
|---|---|---|
| `PKG-SHA256` | FAIL | `<zip>.sha256` does not match |
| `ZIP-PATH` | FAIL | entry name absolute, with a drive letter, with backslashes, or with `..` (zip-slip) |
| `ZIP-DUP` / `ZIP-CASE-DUP` | FAIL | duplicate zip entry / names that differ only in case |
| `ZIP-BOMB` | FAIL | entry exceeds the 128 MiB per-entry or 256 MiB aggregate uncompressed cap, or exceeds 500:1 compression above 16 MiB; content is skipped |
| `ZIP-CORRUPT` | FAIL | an entry cannot be read (CRC error etc.) |
| `STRAY-VCS` | FAIL | `.git/`, `.github/`, `.svn/`, `.hg/`, `.gitignore`, `.gitattributes`, `.gitmodules` |
| `STRAY-BUILD` | FAIL | inside `build/ obj/ bin/ dist/ node_modules/ __pycache__/` |
| `STRAY-OS` | FAIL | `.DS_Store`, `Thumbs.db`, `desktop.ini` |
| `STRAY-TEMP` | FAIL | `*~ *.swp *.swo *.bak *.tmp *.orig *.rej *.log *.kate-swp *.pyc`, `.vscode/`, `.idea/`, `__MACOSX/` |
| `SECRET-NAME` | FAIL | `.env*`, `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `*.p12`, `*.pfx`, `*.kdbx`, `.npmrc`, `.netrc`, `credentials*`, `secrets*` |
| `SECRET-CONTENT` | FAIL | a private key block or a `ghp_`/`gho_`/`github_pat_`/`AKIA`/`xoxb-`/`xoxp-` token anywhere in a file (the value is never printed) |
| `STRAY-EXEC` | FAIL / WARN | `.exe .msi .bat .cmd .ps1 .sh .com .scr .jar` fail; `.dll` warns |
| `STRAY-LARGE` | FAIL | file above `--max-file-mb` (default 25) unless allowlisted (`--allow-large`, waiver file): then `ALLOWED` |
| `PATH-LEAK` | FAIL | `/home/<x>`, `/Users/<x>`, `/root/`, `/workspace/`, `/tmp/`, `C:\Users`, drive-letter paths in text files, XML, .psc, plugin subrecord strings and PEX strings (snippet shown, truncated) |
| `NESTED-ARCHIVE` | FAIL | `.zip .7z .rar .tar .gz .tgz .bz2 .xz`, or zip/7z/rar/gzip magic bytes in any other file |
| `FOMOD-MISSING` / `FOMOD-XML` | FAIL | `fomod/info.xml` or `fomod/ModuleConfig.xml` missing or ill-formed |
| `STRAY-TOPLEVEL` | FAIL | a top-level entry other than `fomod/` and the top-level folders referenced by `<file source>`/`<folder source>`, or a loose top-level file |
| `FOMOD-MISSING-SOURCE` | FAIL | a `<file source>`, `<folder source>`, `<image path>` or `<moduleImage path>` that does not exist |
| `FOMOD-EMPTY-FOLDER` | FAIL | a referenced folder exists only as an empty directory |
| `STRAY-UNREFERENCED` | FAIL | a shipped file outside `fomod/` that no `<file>`/`<folder>` installs |
| `FOMOD-DEST-PATH` | FAIL | absolute install destination or a destination traversing outside the install root |
| `FOMOD-DEST-CONFLICT` | FAIL | two different source files install to the same destination path (only different plugin options within the same `SelectExactlyOne`/`SelectAtMostOne` group without `alwaysInstall` or `installIfUsable` are treated as exclusive) |

ModuleConfig.xml is walked with `iter()` over every element, namespaces ignored, sources
compared case-insensitively with backslashes treated as `/`.

### 4. Bethesda assets

Names and patterns only. The script ships no game data and no hash list.

| Code | Level | When |
|---|---|---|
| `BETH-ARCHIVE` | FAIL | `Skyrim - *.bsa`, `Update.bsa`, `Dawnguard.bsa`, `Dragonborn.bsa`, `HearthFires.bsa`, `Skyrim.bsa`, `_ResourcePack.*` |
| `BETH-CC` | FAIL | Creation Club names (`^cc[a-z]{2,8}sse\d{3}` with .bsa/.ba2/.esm/.esl/.esp) |
| `BETH-MASTER` | FAIL | `Skyrim.esm`, `Update.esm`, `Dawnguard.esm`, `HearthFires.esm`, `Dragonborn.esm`, `Skyrim.esl` shipped as files |
| `BETH-TOOL` | FAIL | `PapyrusCompiler.exe`, `PapyrusAssembler.exe`, `Caprica*`, `Champollion*`, `pyro`, `papyrus-compiler*`, `CreationKit*.exe`, `TESV_Papyrus_Flags.flg`, `Skyrim*.exe`, `SkyrimSE.exe`, SKSE loader/exe |
| `BETH-SKSE` | WARN | `skse64_*.dll` |
| `BETH-STRINGS` | FAIL | `Strings/<Skyrim, Update, Dawnguard, HearthFires or Dragonborn>_*` with `.STRINGS`, `.DLSTRINGS` or `.ILSTRINGS` |
| `BETH-VOICE` | FAIL | anything in `Sound/Voice/<vanilla master>.esm/` |
| `BETH-SCRIPT` | FAIL | a .psc/.pex named like a base-game script or class (Actor, Quest, ObjectReference, Debug, ... see `VANILLA_SCRIPTS`) |
| `BETH-SKSE-SCRIPT` | WARN | SKSE script names (SKSE, StringUtil, ActorValueInfo, ModEvent, ..., `SKSE*`) |
| `BETH-HASH` | FAIL | a file whose sha256 is in `--deny-hashes FILE` |
| `BETH-ARCHIVE-OTHER` | WARN | any other .bsa/.ba2: confirm it holds own content |
| `BETH-PSC-HEADER` | WARN | a .psc comment mentions Bethesda |
| `BETH-VANILLA-PATH` | WARN | files under well-known vanilla roots (`Meshes/Armor/`, `Meshes/Weapons/`, `Meshes/Actors/Character/`, `Meshes/Architecture/`, `Meshes/Dungeons/`, `Meshes/Clutter/`, the same `Textures/` roots plus `Textures/Landscape/`, `Interface/*.swf`) |

`--deny-hashes FILE`: one sha256 per line, `#` comments. Build it yourself from files in your
own game install (for example `sha256sum Data/Scripts/*.pex`), keep it local, never commit it.

### 5. Papyrus and names

| Code | Level | When |
|---|---|---|
| `PEX-PARSE` | FAIL | not a PEX (big-endian magic 0xFA57C0DE) or the header/string table overruns |
| `PAPYRUS-ESCAPE` | FAIL | a PEX string-table constant matches `\\[nrt0"\\]`, or a .psc string literal holds a backslash (comments `;`, block comments `;/ /;` and doc strings `{ }` skipped), same logic as `tools/modkit/papyrus/check_string_escapes.py`. Papyrus does not expand escapes; the player sees a literal `\n` (Contract Hunter 0.1.3) |
| `PEX-HEADER-PATH` | FAIL | PEX header source/user/machine name holds a path separator or an absolute path |
| `PEX-HEADER-USER` | WARN | PEX user or machine name set to something else than the values `pex_normalize.py` writes (`modkit`/`build`) or empty |
| `PEX-SRCNAME` | WARN | PEX source file name is not `<pex stem>.psc` |
| `PEX-NO-PSC` | FAIL | sources ship but a .pex has no matching .psc (case-insensitive) |
| `PSC-NO-PEX` | WARN | a .psc without a .pex |
| `PEX-NO-SOURCES` | WARN | .pex files ship and no .psc at all |
| `PSC-SCRIPTNAME` | FAIL | `ScriptName X` missing or different from the file stem |
| `SCRIPT-PREFIX` / `EDID-PREFIX` | WARN | a script or own-record EditorID without the package prefix |
| `PREFIX-COLLISION` | FAIL | a script or own-record EditorID with a sibling mod's prefix |
| `REGISTRY-UNKNOWN` | WARN | the plugin stem is not in `REGISTRY` (prefix falls back to the most common `^[A-Za-z0-9]+_`) |
| `COLLISION-<KIND>` | FAIL | with `--others`: a plugin, script, EditorID, voice folder or SEQ name shared with another package |

### 6. Plugin masters

Allowed: `Skyrim.esm`, `Update.esm`, `Dawnguard.esm`, `HearthFires.esm`, `Dragonborn.esm`
(case-insensitive), plus masters declared in the docs (any `*.esp/*.esm/*.esl` name on a line
of README.md, docs/NEXUS_FIELDS.md or docs/NEXUS_PAGE.md that mentions master/require/depend),
plus `--allow-master` and the waiver file. The masters are listed in the ok line.

| Code | Level | When |
|---|---|---|
| `MASTER-UNDECLARED` | FAIL | any other master (`ALLOWED` if allowlisted) |
| `MASTER-DLC-CLAIM` | FAIL | Update/Dawnguard/HearthFires/Dragonborn used while the docs claim "Skyrim.esm only", "Skyrim.esm is the only master", "no DLC" or base game only |
| `MASTER-SELF` | FAIL | a plugin lists itself as a master |

## Waiver file

Optional `<repo>/.verify-release.allow`:

```
# vendored compatibility master, see README
allow-master SomeOtherMod.esp
# narrated intro, deliberately large
allow-large 00 Core/Sound/Voice/*/Intro*.wav
```

Text scans decode UTF-8 (including BOM), UTF-16/32 with BOM or XML root signatures (including leading whitespace), and encodings declared
in XML prologs. Streamed scans use incremental decoders, including across chunk boundaries.
Destinations are compared case-insensitively after resolving dot segments and repeated
or mixed separators and stripping trailing dots/spaces from every component (Windows aliases). Absolute destinations and traversal outside the install root fail.
Drive-root paths such as `C:\private.txt` and `C:/private.txt` are detected in text, plugin strings and PEX strings.
Compressed plugin records with trailing bytes after the zlib stream fail `PLUGIN-STRUCT`.

Hard resource limits cannot be waived. Blocked entries are never opened for deny-hash
scanning; `BETH-HASH-SKIPPED` notes the skip alongside the existing resource-limit failure. Files over 64 MiB within those limits are streamed
for archive magic, secrets, path leaks and CRC integrity; a size waiver only waives
`STRAY-LARGE`. Compressed plugin records are bounded to 64 MiB each and 256 MiB total;
GRUP depth is bounded to 64. Plugins over the content parsing limit fail `PLUGIN-STRUCT`.
`--max-entry-mb` and `--max-total-mb` can lower the entry and aggregate budgets.

`allow-large` globs match the package path or the file name, case-insensitively. Waived items
print as `[ALLOWED]`; unknown lines are a WARN (`WAIVER`).

## Collision mode

```
verify-release.sh --collisions dist-a/ModA-1.0.0.zip dist-b/ dir-with-zips/ [--json out.json]
```

Per package it collects plugin file names, script names (.psc/.pex stems), EditorIDs of own
records (all record types: GLOB, QUST, ...), voice folders (`Sound/Voice/<Plugin>/<VoiceType>`:
vanilla voice types under different plugin folders do not collide) and SEQ names, all
case-insensitive. It prints a per-package summary (registry prefix, counts per kind, most
common prefixes), a table of every name found in more than one package (kind, name,
packages), and `RESULT: PASS` (exit 0) or `RESULT: FAIL` (exit 1). ObjectIDs are not compared:
ESL slots are assigned at load time, so two ESLs may use the same 0x800-0xFFF ids.

EditorIDs intentionally use name-only collision keys across all record types: console,
Papyrus and condition lookups share a global namespace. Reports show the record type(s)
for each package, including cross-type collisions.

In verify mode, `--others PKG...` runs the same comparison between the package and each
other package (a package identical to the one being verified is skipped).

## Distribution

The canonical copies live in this repo (synthalorian/.github):

| Here | Copied to each mod repo as |
|---|---|
| `scripts/verify-release.sh` | `scripts/verify-release.sh` |
| `templates/scripts-README.md` | `scripts/README.md` |
| `templates/verify-release.yml` | `.github/workflows/verify-release.yml` |

The per-repo workflow builds the package with `DIST_DIR="$RUNNER_TEMP/dist" ./build.sh` (as the
reusable mod-ci workflow does), runs the verifier with `--summary "$GITHUB_STEP_SUMMARY"`
(and `--tag "$GITHUB_REF_NAME"` on tag pushes), then a non-fatal drift step downloads the
canonical script from `raw.githubusercontent.com/synthalorian/.github/main/scripts/verify-release.sh`
and warns when the repo copy differs (a 404 is only a notice). Edit the canonical copy here,
let `verify-release-selftest.yml` run the unit tests, then re-sync the mod repos.

`scripts/verify-release.sh` is a bash/Python polyglot (line 2 execs `python3 "$0"`), so `bash -n`
cannot parse it. The `Shell script syntax` step in `ci.yml` detects the marker on line 2 and
parses the file as Python instead; copy that handling if a mod repo lints `*.sh` files with `bash -n`.

Tests: `python3 -m unittest discover -s tests/verify_release` (stdlib only, every fixture is
generated: fake TES4 plugins, fake PEX files, FOMOD zips and a fake repo).

## Adding a new mod to REGISTRY

1. Pick a unique 3-letter prefix plus `_` that no other mod uses and that is not a prefix of
   another one (check `REGISTRY` in `scripts/verify-release.sh`).
2. Add `"<PluginStem>": "<PREFIX>_",` to `REGISTRY` (the plugin stem is the .esp name without
   extension, as in `build.sh`'s `NAME`). Add old or alternate stems too if the plugin was renamed.
3. Run the unit tests, then `--collisions` over all release zips to make sure no names clash.
4. Re-sync `scripts/verify-release.sh` to every mod repo, so each one knows about the new
   sibling prefix.

Until then the new mod gets a `REGISTRY-UNKNOWN` WARN and its prefix is guessed from the most
common `XXX_` prefix in its scripts and EditorIDs.

## Limitations

- Structure-only validation. It walks the plugin and PEX formats far enough to check sizes,
  FormIDs, EditorIDs and strings; it does not resolve links, check record contents, or check
  that scripts compile. That is the job of the build (Mutagen validator, Papyrus compiler).
- No real Bethesda data is used or shipped. The Bethesda check knows file names and patterns
  only; vanilla content under a non-vanilla name is caught only through `--deny-hashes`, and
  no hash list is shipped with the script.
- The vanilla-path and Bethesda-comment checks are heuristics and only WARN.
- Docs claims (ESL, no overrides, Skyrim.esm only, declared masters) are matched with simple
  regular expressions on README.md and docs/NEXUS_*.md.
- FOMOD destination conflicts exempt only different plugin options in the same
  `SelectExactlyOne`/`SelectAtMostOne` group when neither install has `alwaysInstall`
  or `installIfUsable` enabled (both default to false; values are whitespace-collapsed and `true`/`1` are accepted case-insensitively). Usability dependencies and their
  default types are conservatively treated as potentially usable. Conditional patterns may overlap and are
  checked for conflicts; flag dependencies are not evaluated.
