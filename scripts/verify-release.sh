#!/usr/bin/env bash
"exec" "python3" "$0" "$@"
# This file is a bash/Python polyglot: bash runs the line above (exec python3 <this file>),
# Python sees it as a harmless string expression. Everything below is Python 3.8+ stdlib only.
# Canonical copy: synthalorian/.github scripts/verify-release.sh (edit there, then re-sync).

__doc__ = """verify-release: pre-release verifier for the Blackshield Skyrim SE mods.

Checks a built FOMOD release package (zip or unpacked tree) against the repo it
was built from, before it is uploaded anywhere.

Usage:
  verify-release.sh --zip FILE | --dist DIR   [--repo DIR (default .)] [--tag vX.Y.Z]
                    [--allow-master NAME]... [--allow-large GLOB]... [--max-file-mb N (default 25)]
                    [--others PKG...] [--deny-hashes FILE] [--json FILE] [--summary FILE]
                    [--strict] [--quiet]
  verify-release.sh --collisions PKG [PKG ...] [--json FILE]
  verify-release.sh --version | --help

  --dist DIR       DIR holds exactly one *.zip, or is an unpacked package tree (has fomod/).
  PKG              a zip, an unpacked package tree, or a directory of zips.
  <zip>.sha256     verified when it sits next to the zip (absence is fine).
  <repo>/.verify-release.allow
                   optional waiver file, one per line: "allow-master NAME" or
                   "allow-large GLOB"; "#" starts a comment. Waived items print as ALLOWED.
  --deny-hashes F  one sha256 per line (# comments). Any packaged file with a listed hash
                   is a hard FAIL (BETH-HASH). This script bundles NO hash list and NO
                   game data: build your own list locally from your own game install.

Checks (each finding has a stable CODE):
  1. ESL / plugin structure   ESL-FLAG PLUGIN-STRUCT ESL-RANGE PLUGIN-HEDR PLUGIN-FORMID
                              OVERRIDE-CLAIM
  2. Version consistency      VER-MISMATCH VER-CHANGELOG VER-README VER-INFO-MISSING
                              VER-UNRENDERED VER-MODULENAME VER-NEXUS-EMPTY VER-NEXUS-FIELD
                              VER-ZIPNAME VER-TAG-COMMIT
  3. Stray files / FOMOD      PKG-SHA256 ZIP-PATH ZIP-DUP ZIP-CASE-DUP ZIP-CORRUPT STRAY-VCS
                              STRAY-BUILD STRAY-OS STRAY-TEMP SECRET-NAME SECRET-CONTENT
                              STRAY-EXEC STRAY-LARGE PATH-LEAK NESTED-ARCHIVE FOMOD-MISSING
                              FOMOD-XML STRAY-TOPLEVEL FOMOD-MISSING-SOURCE FOMOD-EMPTY-FOLDER
                              STRAY-UNREFERENCED FOMOD-DEST-CONFLICT
  4. Bethesda assets          BETH-ARCHIVE BETH-CC BETH-MASTER BETH-TOOL BETH-SKSE
                              BETH-STRINGS BETH-VOICE BETH-SCRIPT BETH-SKSE-SCRIPT BETH-HASH
                              BETH-ARCHIVE-OTHER BETH-PSC-HEADER BETH-VANILLA-PATH (WARN)
  5. Papyrus / names          PEX-PARSE PAPYRUS-ESCAPE PEX-HEADER-PATH PEX-HEADER-USER
                              PEX-SRCNAME PEX-NO-PSC PSC-NO-PEX PEX-NO-SOURCES PSC-SCRIPTNAME
                              SCRIPT-PREFIX EDID-PREFIX PREFIX-COLLISION REGISTRY-UNKNOWN
                              COLLISION-<KIND> (with --others)
  6. Plugin masters           MASTER-UNDECLARED MASTER-DLC-CLAIM MASTER-SELF

Output: one line per finding, "[FAIL] CODE path: reason", "[WARN] ...", "[ ok ] CODE: detail",
grouped under the check headings, then "RESULT: PASS" or "RESULT: FAIL (N fail, M warn)".
WARNs never fail the run unless --strict. --json writes a machine-readable report,
--summary appends GitHub-flavored markdown (for $GITHUB_STEP_SUMMARY), and with
GITHUB_ACTIONS=true every FAIL/WARN is also emitted as an ::error::/::warning:: annotation.

Collision mode (--collisions) compares plugin names, script names, own-record EditorIDs,
voice folder names and SEQ names across packages and fails on any name in more than one
package. ObjectIDs are not compared (ESL slots are assigned at load time).

Exit codes: 0 PASS, 1 FAIL, 2 usage or input error (missing/unreadable package etc.).

Limitations: structure-only validation. No real Bethesda data, no hash list shipped; the
Bethesda checks work on file names and patterns only.
"""

import argparse
import collections
import fnmatch
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import codecs
import itertools
import xml.etree.ElementTree as ET
import zipfile
import zlib

TOOL_VERSION = "1.0.0"

# --------------------------------------------------------------------------------------------
# Registry: plugin stem -> script/EditorID prefix of every Blackshield mod.
# Add a new mod here (see docs/verify-release.md) so sibling-prefix collisions are caught.
# --------------------------------------------------------------------------------------------
REGISTRY = {
    "BlackshieldCompany": "BSC_",
    "BountiesOfOblivion": "BOO_",
    "ContractHunter": "CHT_",
    "SteelOath": "SOT_",
    "EmberSmithing": "EMB_",  # no scripts
    "GrayManeDebt": "GMD_",
    "TheGrayManeDebt": "GMD_",
    "BlackshieldCodex": "BCX_",
    "WarBanners": "WBN_",
    "Roadwarden": "RWD_",
    "SellswordRoster": "SSR_",
    "TurncoatContract": "TTC_",
    "LedgerOfAsh": "LOA_",
    "OathbreakersPrice": "OBP_",
    "ChampionsReforge": "CRF_",
    "BarrowIronPact": "BIP_",
}

BASE_MASTERS = ["Skyrim.esm", "Update.esm", "Dawnguard.esm", "HearthFires.esm", "Dragonborn.esm"]
DLC_MASTERS = {"update.esm", "dawnguard.esm", "hearthfires.esm", "dragonborn.esm"}
PLUGIN_EXTS = (".esp", ".esm", ".esl")
ESL_FLAG = 0x200
COMPRESSED_FLAG = 0x40000
ESL_MIN, ESL_MAX, ESL_MAX_RECORDS = 0x800, 0xFFF, 2048
PEX_MAGIC = 0xFA57C0DE
PEX_ESCAPE = re.compile(r'\\[nrt0"\\]')
# Values written by tools/modkit/papyrus/pex_normalize.py: not personal data.
PEX_NORMALIZED_NAMES = {"", "modkit", "build"}
REPORT_CAP = 25  # max individual lines per finding kind before summarizing

CHECK_TITLES = {
    1: "ESL / plugin structure",
    2: "Version consistency",
    3: "Stray files and FOMOD structure",
    4: "Bethesda assets",
    5: "Papyrus and names",
    6: "Plugin masters",
}

# --------------------------------------------------------------------------------------------
# Name lists. Names and patterns only: nothing here is (or references) game data.
# --------------------------------------------------------------------------------------------
VANILLA_ARCHIVES = ["skyrim - *.bsa", "update.bsa", "dawnguard.bsa", "dragonborn.bsa",
                    "hearthfires.bsa", "skyrim.bsa", "_resourcepack.*"]
CC_RE = re.compile(r"^cc[a-z]{2,8}sse\d{3}.*\.(bsa|ba2|esm|esl|esp)$")
VANILLA_MASTER_FILES = {"skyrim.esm", "update.esm", "dawnguard.esm", "hearthfires.esm",
                        "dragonborn.esm", "skyrim.esl"}
TOOL_PATTERNS = ["papyruscompiler.exe", "papyrusassembler.exe", "caprica*", "champollion*",
                 "pyro", "pyro.exe", "papyrus-compiler*", "creationkit*.exe",
                 "tesv_papyrus_flags.flg", "skyrim*.exe", "skyrimse.exe", "skse64_*.exe",
                 "skse64_loader*"]
SKSE_DLL_PATTERNS = ["skse64_*.dll"]
VANILLA_GAMES = r"(skyrim|update|dawnguard|hearthfires|dragonborn)"
VANILLA_STRINGS_RE = re.compile(r"(^|/)strings/" + VANILLA_GAMES + r"_[^/]*\.(strings|dlstrings|ilstrings)$")
VANILLA_VOICE_RE = re.compile(r"(^|/)sound/voice/" + VANILLA_GAMES + r"\.esm/")
VANILLA_SCRIPTS = {s.lower() for s in """
Actor ActorBase ActiveMagicEffect Activator Alias Ammo Apparatus Armor ArmorAddon Art
AssociationType Book Cell Class ColorForm CombatStyle ConstructibleObject Container Debug
DefaultObject Door EffectShader Enchantment EncounterZone EquipSlot Explosion Faction Flora
Form FormList Furniture Game GlobalVariable Hazard Idle ImageSpaceModifier ImpactDataSet
Ingredient Input Key Keyword LeveledActor LeveledItem LeveledSpell Light Location
LocationAlias LocationRefType MagicEffect Math Message MiscObject MusicType NetImmerse
ObjectReference Outfit Package Perk Potion Projectile Quest Race ReferenceAlias Scene Scroll
ScriptObject Shout SoulGem Sound SoundCategory Spell Static TalkingActivator TextureSet Topic
TopicInfo TreeObject UI Utility VisualEffect VoiceType Weapon Weather WordOfPower WorldSpace
DialogueFollowerScript defaultDisableHavokOnLoad
""".split()}
SKSE_SCRIPTS = {s.lower() for s in """
SKSE StringUtil ActorValueInfo ModEvent UICallback HeadPart SoundDescriptor ColorComponent
Camera
""".split()}
OTHER_ARCHIVE_EXTS = (".bsa", ".ba2")
VANILLA_ASSET_ROOTS = ["meshes/armor/", "meshes/weapons/", "meshes/actors/character/",
                       "meshes/architecture/", "meshes/dungeons/", "meshes/clutter/",
                       "textures/armor/", "textures/weapons/", "textures/actors/character/",
                       "textures/landscape/", "textures/clutter/", "textures/architecture/",
                       "textures/dungeons/"]
VANILLA_ASSET_RE = re.compile(r"(^|/)(" + "|".join(re.escape(r) for r in VANILLA_ASSET_ROOTS)
                              + r"|interface/[^/]+\.swf$)")

# --------------------------------------------------------------------------------------------
# Stray-file rules
# --------------------------------------------------------------------------------------------
VCS_PARTS = {".git", ".github", ".svn", ".hg"}
VCS_FILES = {".gitignore", ".gitattributes", ".gitmodules"}
BUILD_DIRS = {"build", "obj", "bin", "dist", "node_modules", "__pycache__"}
OS_JUNK = {".ds_store", "thumbs.db", "desktop.ini"}
TEMP_PATTERNS = ["*~", "*.swp", "*.swo", "*.bak", "*.tmp", "*.orig", "*.rej", "*.log",
                 "*.kate-swp", "*.pyc"]
EDITOR_DIRS = {".vscode", ".idea", "__macosx"}
SECRET_NAME_PATTERNS = [".env*", "*.pem", "*.key", "id_rsa*", "id_ed25519*", "*.p12", "*.pfx",
                        "*.kdbx", ".npmrc", ".netrc", "credentials*", "secrets*"]
SECRET_CONTENT = [
    ("private key block", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\b(?:ghp|gho|ghu|ghs)_[A-Za-z0-9]{30,}")),
    ("GitHub fine-grained token", re.compile(rb"\bgithub_pat_[A-Za-z0-9_]{20,}")),
    ("AWS access key id", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(rb"\bxox[bp]-[A-Za-z0-9-]{10,}")),
]
EXEC_FAIL_EXTS = (".exe", ".msi", ".bat", ".cmd", ".ps1", ".sh", ".com", ".scr", ".jar")
EXEC_WARN_EXTS = (".dll",)
NESTED_EXTS = (".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".xz")
NESTED_MAGIC = [(b"PK\x03\x04", "zip"), (b"7z\xbc\xaf\x27\x1c", "7z"), (b"Rar!\x1a\x07", "rar"),
                (b"\x1f\x8b\x08", "gzip")]
TEXT_EXTS = {".txt", ".md", ".xml", ".psc", ".ini", ".json", ".yml", ".yaml", ".cfg", ".toml",
             ".html", ".htm", ".csv", ".py", ".sh", ".bat", ".cmd", ".ps1", ".log", ".rtf"}
BINARY_EXTS = {".esp", ".esm", ".esl", ".pex", ".bsa", ".ba2", ".wav", ".xwm", ".fuz", ".lip",
               ".nif", ".dds", ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tga", ".seq", ".swf",
               ".hkx", ".tri", ".bik", ".zip", ".7z", ".rar", ".gz", ".dll", ".exe"}
PATH_LEAK_RE = re.compile(
    r"(?<![\w.\-/:])(?:/home/[^/\s\"'<>]+|/Users/[^/\s\"'<>]+|/root/|/workspace/|/tmp/)"
    r"|(?<![A-Za-z0-9])[A-Za-z]:\\Users\b"
    r"|(?<![A-Za-z0-9/\\])[A-Za-z]:[\\/][\w .\-]+", re.I)
PRINTABLE_RUN = re.compile(rb"[\x20-\x7e]{6,}")

# --------------------------------------------------------------------------------------------
# Resource limits: a hostile or broken package must produce a finding, not exhaust memory.
# --------------------------------------------------------------------------------------------
MB = 1024 * 1024
CONTENT_SCAN_LIMIT = 64 * MB      # entries up to this size are read into memory; bigger ones stream
MAX_ENTRY_MB = 128                # hard per-entry cap (--max-entry-mb): bigger entries are never read
MAX_TOTAL_MB = 256                # hard cap on the summed uncompressed size read (--max-total-mb)
BOMB_RATIO = 500                  # compression ratio above which a big entry is a zip bomb...
BOMB_RATIO_MIN = 16 * MB          # ...when it also inflates to more than this
MAX_RECORD_INFLATE = 64 * MB      # largest inflated size of one compressed plugin record
MAX_PLUGIN_INFLATE = 256 * MB     # summed inflated size of all compressed records of one plugin
MAX_GRUP_DEPTH = 64               # Skyrim nests GRUPs about 5 deep; deeper is malformed
STREAM_CHUNK = 1 * MB
STREAM_OVERLAP = 4096             # bytes carried between chunks so a match can span two chunks


class InputError(Exception):
    """Unusable input (missing or unreadable package, bad arguments): exit code 2."""


class PluginError(Exception):
    """Structural problem in a plugin."""


# --------------------------------------------------------------------------------------------
# Package abstraction: a zip or an unpacked tree, as a list of entries with lazy bytes.
# --------------------------------------------------------------------------------------------
def norm_path(name):
    p = name.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p.lstrip("/")


class Entry:
    def __init__(self, name, size, opener, csize=None):
        self.name = name                # as stored (raw zip entry name / relative path)
        self.path = norm_path(name)     # forward slashes, no leading slash
        self.lower = self.path.lower()
        self.base = self.path.rsplit("/", 1)[-1]
        self.ext = os.path.splitext(self.base)[1].lower()
        self.stem = os.path.splitext(self.base)[0]
        self.size = size                # declared uncompressed size
        self.csize = csize              # compressed size (zip only)
        self._open = opener             # () -> binary file object
        self._data = None
        self.error = None
        self.blocked = None             # why the content is never read (size caps, zip bomb)
        self.bomb = False               # blocked by the compression-ratio guard: not even streamed

    def _fail(self, e):
        self.error = str(e) or e.__class__.__name__

    def data(self):
        """Whole content, for entries up to CONTENT_SCAN_LIMIT; b"" for bigger/blocked ones or on error."""
        if self._data is None:
            if self.blocked or self.size > CONTENT_SCAN_LIMIT:
                return b""
            try:
                with self._open() as f:
                    data = f.read(self.size + 1)
                if len(data) > self.size:
                    raise ValueError("entry holds more than its declared %d bytes" % self.size)
                self._data = data
            except Exception as e:  # corrupt member, CRC error, permission...
                self._fail(e)
                self._data = b""
        return self._data

    def chunks(self, force=False):
        """Stream the content in STREAM_CHUNK pieces (constant memory), reading through EOF so
        zip CRCs are verified. Blocked entries are never opened, even with force=True."""
        if self.blocked or self.bomb:
            return
        try:
            with self._open() as f:
                left = self.size
                while True:
                    c = f.read(STREAM_CHUNK)
                    if not c:
                        break
                    left -= len(c)
                    if left < 0:
                        raise ValueError("entry holds more than its declared %d bytes" % self.size)
                    yield c
        except Exception as e:
            self._fail(e)

    def release(self):
        if self.size > 8 * MB:
            self._data = None


class Package:
    def __init__(self, source, kind, entries, dirs=(), members=None):
        self.source = source
        self.kind = kind  # "zip" or "dir"
        self.entries = entries
        self.dirs = list(dirs)
        # Every member as stored, directories included: (raw name, is_dir).
        self.members = members if members is not None else (
            [(d, True) for d in self.dirs] + [(e.name, False) for e in entries])
        self.name = os.path.basename(os.path.normpath(source))
        self.label = self.name          # display name; made unique in multi-package modes
        self.realpath = os.path.realpath(source)
        self.by_lower = {}
        for e in entries:
            self.by_lower.setdefault(e.lower, e)

    def apply_limits(self, max_entry_mb=MAX_ENTRY_MB, max_total_mb=MAX_TOTAL_MB):
        """Mark entries whose content must never be read: likely zip bombs, entries above the
        per-entry cap, and entries past the aggregate cap (in archive order)."""
        max_entry = min(max_entry_mb, MAX_ENTRY_MB) * MB
        max_total = min(max_total_mb, MAX_TOTAL_MB) * MB
        total = 0
        for e in self.entries:
            if (e.csize is not None and e.size > BOMB_RATIO_MIN
                    and e.size > BOMB_RATIO * max(e.csize, 1)):
                e.blocked = "inflates %d bytes to %.1f MB (ratio above %d:1), looks like a zip bomb" % (
                    e.csize, e.size / float(MB), BOMB_RATIO)
                e.bomb = True
            elif e.size > max_entry:
                e.blocked = "%.1f MB is above the %s MB per-entry hard limit" % (e.size / float(MB), max_entry_mb)
            elif total + e.size > max_total:
                e.blocked = "the package passes the %s MB uncompressed hard limit at this entry" % max_total_mb
            else:
                total += e.size
        return self

    def find(self, path):
        return self.by_lower.get(norm_path(path).lower())

    def under(self, folder):
        f = norm_path(folder).lower().rstrip("/")
        if not f:
            return [e for e in self.entries]
        return [e for e in self.entries if e.lower.startswith(f + "/")]

    def has_dir(self, folder):
        f = norm_path(folder).lower().rstrip("/") + "/"
        return any(norm_path(d).lower().rstrip("/") + "/" == f for d in self.dirs) or bool(self.under(folder))


def open_zip(path):
    try:
        zf = zipfile.ZipFile(path)
        infos = zf.infolist()
    except (zipfile.BadZipFile, OSError, ValueError, NotImplementedError, EOFError) as e:
        raise InputError("cannot read zip %s: %s" % (path, e))
    entries, dirs, members = [], [], []
    for info in infos:
        is_dir = info.filename.endswith("/") or (info.filename.endswith("\\") and info.file_size == 0)
        members.append((info.filename, is_dir))
        if is_dir:
            dirs.append(info.filename)
            continue
        entries.append(Entry(info.filename, info.file_size, (lambda i=info: zf.open(i)), info.compress_size))
    return Package(path, "zip", entries, dirs, members)


def open_tree(path):
    entries, dirs = [], []
    for base, dnames, fnames in os.walk(path):
        dnames.sort()
        rel_base = os.path.relpath(base, path)
        for d in dnames:
            dirs.append(norm_path(os.path.join(rel_base, d).replace(os.sep, "/")) + "/")
        for f in sorted(fnames):
            full = os.path.join(base, f)
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            try:
                size = os.path.getsize(full)
            except OSError:
                size = 0
            entries.append(Entry(rel, size, (lambda p=full: open(p, "rb"))))
    return Package(path, "dir", entries, dirs)


def open_package(path, max_entry_mb=MAX_ENTRY_MB, max_total_mb=MAX_TOTAL_MB):
    if os.path.isdir(path):
        pkg = open_tree(path)
    elif os.path.isfile(path):
        pkg = open_zip(path)
    else:
        raise InputError("no such package: %s" % path)
    return pkg.apply_limits(max_entry_mb, max_total_mb)


def unique_labels(pkgs):
    """Give every package a distinct display label: the base name, plus the parent directory
    (then an index) when base names clash. Identity is always the resolved path."""
    for p in pkgs:
        p.label = p.name
    for attempt in ("parent", "index"):
        groups = collections.defaultdict(list)
        for p in pkgs:
            groups[p.label.lower()].append(p)
        clashes = [g for g in groups.values() if len(g) > 1]
        if not clashes:
            return
        for g in clashes:
            for i, p in enumerate(g, 1):
                if attempt == "parent":
                    p.label = "%s (%s)" % (p.name, os.path.basename(os.path.dirname(p.realpath)) or "/")
                else:
                    p.label = "%s #%d" % (p.label, i)


def resolve_dist(dist, zip_arg=None):
    """--dist DIR: exactly one *.zip inside, or DIR itself is an unpacked tree (has fomod/)."""
    if zip_arg:
        cand = zip_arg if os.path.exists(zip_arg) or not dist else os.path.join(dist, zip_arg)
        return cand
    if not os.path.isdir(dist):
        raise InputError("--dist %s is not a directory" % dist)
    zips = sorted(f for f in os.listdir(dist) if f.lower().endswith(".zip") and os.path.isfile(os.path.join(dist, f)))
    if len(zips) == 1:
        return os.path.join(dist, zips[0])
    if len(zips) > 1:
        raise InputError("--dist %s holds %d zips (%s); pick one with --zip" % (dist, len(zips), ", ".join(zips)))
    if any(d.lower() == "fomod" and os.path.isdir(os.path.join(dist, d)) for d in os.listdir(dist)):
        return dist
    raise InputError("--dist %s holds no *.zip and is not a package tree (no fomod/)" % dist)


def expand_pkg_args(paths):
    """A PKG is a zip, an unpacked tree, or a directory of zips. The same resolved path given
    twice (directly or through a directory) is listed once."""
    out, seen = [], set()

    def keep(path):
        real = os.path.realpath(path)
        if real not in seen:
            seen.add(real)
            out.append(path)

    for p in paths:
        if os.path.isdir(p):
            names = os.listdir(p)
            if any(n.lower() == "fomod" for n in names):
                keep(p)
                continue
            zips = sorted(os.path.join(p, n) for n in names if n.lower().endswith(".zip"))
            if not zips:
                raise InputError("%s is neither a package tree nor a directory of zips" % p)
            for z in zips:
                keep(z)
        else:
            keep(p)
    return out


# --------------------------------------------------------------------------------------------
# Findings and report
# --------------------------------------------------------------------------------------------
class Finding:
    def __init__(self, check, level, code, path, message):
        self.check, self.level, self.code, self.path, self.message = check, level, code, path, message

    def line(self):
        tag = {"FAIL": "[FAIL]", "WARN": "[WARN]", "OK": "[ ok ]", "ALLOWED": "[ALLOWED]", "INFO": "[info]"}[self.level]
        if self.level in ("OK", "INFO"):
            return "%s %s: %s" % (tag, self.code, self.message)
        where = (" " + self.path) if self.path else ""
        return "%s %s%s: %s" % (tag, self.code, where, self.message)

    def as_dict(self):
        return {"check": self.check, "level": self.level, "code": self.code,
                "path": self.path, "message": self.message}


class Report:
    def __init__(self):
        self.findings = []
        self.check = 0
        self.tables = {}  # check -> list of preformatted lines printed after the findings

    def add(self, level, code, path, message):
        self.findings.append(Finding(self.check, level, code, path or "", message))

    def fail(self, code, path, message):
        self.add("FAIL", code, path, message)

    def warn(self, code, path, message):
        self.add("WARN", code, path, message)

    def ok(self, code, message):
        self.add("OK", code, "", message)

    def info(self, code, message):
        self.add("INFO", code, "", message)

    def allowed(self, code, path, message):
        self.add("ALLOWED", code, path, message)

    def table(self, lines):
        self.tables.setdefault(self.check, []).extend(lines)

    def problems_since(self, start):
        return sum(1 for f in self.findings[start:] if f.level in ("FAIL", "WARN"))

    def count(self, level):
        return sum(1 for f in self.findings if f.level == level)

    def capped(self, level, code, items, what):
        """Report each (path, message) up to REPORT_CAP, then one summary line with the total."""
        for path, msg in items[:REPORT_CAP]:
            self.add(level, code, path, msg)
        if len(items) > REPORT_CAP:
            self.add(level, code, "", "... %d more (%d %s in total)" % (len(items) - REPORT_CAP, len(items), what))


def truncate(s, n=80):
    s = s.replace("\r", " ").replace("\n", " ")
    return s if len(s) <= n else s[: n - 3] + "..."


# --------------------------------------------------------------------------------------------
# Repo docs and waivers
# --------------------------------------------------------------------------------------------
def read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8-sig", errors="replace")
    except OSError:
        return None


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


class RepoDocs:
    def __init__(self, root):
        self.root = root
        self.readme = read_text(os.path.join(root, "README.md"))
        self.changelog = read_text(os.path.join(root, "CHANGELOG.md"))
        self.nexus_fields = read_text(os.path.join(root, "docs", "NEXUS_FIELDS.md"))
        self.nexus_page = read_text(os.path.join(root, "docs", "NEXUS_PAGE.md"))
        self.info_xml = read_bytes(os.path.join(root, "fomod", "info.xml"))  # raw: XML picks its encoding
        self.allow_masters, self.allow_large, self.waiver_errors = [], [], []
        waiver = read_text(os.path.join(root, ".verify-release.allow"))
        self.has_waiver = waiver is not None
        for no, line in enumerate((waiver or "").splitlines(), 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            key, _, value = line.partition(" ")
            value = value.strip()
            if key == "allow-master" and value:
                self.allow_masters.append(value)
            elif key == "allow-large" and value:
                self.allow_large.append(value)
            else:
                self.waiver_errors.append("line %d: %s" % (no, line))

    def docs(self):
        return [t for t in (self.readme, self.nexus_fields, self.nexus_page) if t]

    def claims_esl(self):
        return any(re.search(r"ESL", t) for t in (self.readme, self.nexus_fields) if t)

    def claims_no_overrides(self):
        pat = re.compile(r"no vanilla records edited|zero overrides|edits no vanilla records|"
                         r"no edits to vanilla records", re.I)
        return any(pat.search(t) for t in self.docs())

    def claims_base_game_only(self):
        pat = re.compile(r"Skyrim\.esm only|Skyrim\.esm is the only master|Skyrim\.esm as its only master|"
                         r"\bno DLC\b|beyond the base game|base game only", re.I)
        return any(pat.search(t) for t in self.docs())

    def declared_masters(self):
        names = set()
        for text in self.docs():
            for line in text.splitlines():
                if not re.search(r"master|require|depend", line, re.I):
                    continue
                for m in re.finditer(r"`([^`\n]+\.es[pml])`", line, re.I):
                    names.add(m.group(1).strip())
                for m in re.finditer(r"[\w\-']+\.es[pml]\b", line, re.I):
                    names.add(m.group(0))
        return names


# --------------------------------------------------------------------------------------------
# Plugin parsing (TES4/GRUP walker, same rules as tools/modkit/esp_check.py)
# --------------------------------------------------------------------------------------------
class PluginInfo:
    def __init__(self, name):
        self.name = name
        self.flags = 0
        self.esl = False
        self.masters = []
        self.version = None
        self.hedr_records = None
        self.next_id = None
        self.records = []   # (type, formid, edid or None)
        self.groups = 0
        self.error = None
        self.leaks = []     # path-leak snippets from TES4 header and record subrecord strings
        self.inflated = 0   # bytes inflated from compressed records so far

    @property
    def own(self):
        n = len(self.masters)
        return [r for r in self.records if (r[1] >> 24) == n]

    @property
    def overrides(self):
        n = len(self.masters)
        return [r for r in self.records if (r[1] >> 24) < n]

    @property
    def bad_index(self):
        n = len(self.masters)
        return [r for r in self.records if (r[1] >> 24) > n]

    def scan_strings(self, payload):
        """Collect path leaks from the printable runs of one subrecord (bounded list)."""
        if len(self.leaks) >= REPORT_CAP or len(payload) < 6:
            return
        for m in PRINTABLE_RUN.finditer(payload):
            s = m.group(0).decode("latin-1")
            if PATH_LEAK_RE.search(s):
                self.leaks.extend(path_leaks([s]))
                if len(self.leaks) >= REPORT_CAP:
                    return


def iter_subrecords(data, where):
    """Yield (type, payload). An XXXX marker gives the size of the next subrecord; a second
    XXXX in a row, or an XXXX with nothing after it, is an error. Raises on overrun."""
    i, n, big = 0, len(data), None
    while i < n:
        if i + 6 > n:
            raise PluginError("truncated subrecord header in %s" % where)
        typ, size = struct.unpack_from("<4sH", data, i)
        pending, big = big, None
        if pending is not None:
            if typ == b"XXXX":
                raise PluginError("two XXXX markers in a row in %s" % where)
            size = pending
        if i + 6 + size > n:
            raise PluginError("subrecord %s overruns %s" % (typ.decode("latin-1"), where))
        payload = data[i + 6: i + 6 + size]
        if typ == b"XXXX":
            if size != 4:
                raise PluginError("bad XXXX subrecord in %s" % where)
            big = struct.unpack("<I", payload)[0]
        else:
            yield typ.decode("latin-1"), payload
        i += 6 + size
    if big is not None:
        raise PluginError("XXXX marker at the end of %s with no subrecord after it" % where)


def zstring(b):
    return b.split(b"\0", 1)[0].decode("cp1252", errors="replace")


def parse_plugin(buf, name="plugin"):
    """Parse a plugin. Structural errors are stored in info.error (never raised)."""
    info = PluginInfo(name)
    try:
        if len(buf) < 24:
            raise PluginError("file too short for a TES4 header (%d bytes)" % len(buf))
        typ, size, flags, _fid = struct.unpack_from("<4sIII", buf, 0)
        if typ != b"TES4":
            raise PluginError("not a TES4 plugin (starts with %r)" % typ)
        if 24 + size > len(buf):
            raise PluginError("TES4 header overruns the file")
        info.flags, info.esl = flags, bool(flags & ESL_FLAG)
        hedr = None
        for t, d in iter_subrecords(buf[24: 24 + size], "TES4 header"):
            if t == "MAST":
                info.masters.append(zstring(d))
            elif t == "HEDR":
                hedr = d
            info.scan_strings(d)  # author (CNAM), description (SNAM), master names...
        if hedr is None or len(hedr) != 12:
            raise PluginError("TES4 header has no valid HEDR subrecord")
        version, info.hedr_records, info.next_id = struct.unpack("<fiI", hedr)
        info.version = round(version, 2)
        _walk(buf, 24 + size, len(buf), info)
    except PluginError as e:
        info.error = str(e)
    except (struct.error, zlib.error, ValueError) as e:
        info.error = "malformed data: %s" % e
    except Exception as e:  # defensive: any parser failure is a finding, never a traceback
        info.error = "parser error: %s: %s" % (e.__class__.__name__, e)
    return info


def inflate_record(data, rname, rid, info):
    """Inflate a compressed record body, bounded by its declared size and the plugin budget."""
    if len(data) < 4:
        raise PluginError("compressed record %s %08X too short" % (rname, rid))
    want = struct.unpack_from("<I", data, 0)[0]
    if want > MAX_RECORD_INFLATE:
        raise PluginError("compressed record %s %08X claims %d inflated bytes, above the %d MB limit"
                          % (rname, rid, want, MAX_RECORD_INFLATE // MB))
    info.inflated += want
    if info.inflated > MAX_PLUGIN_INFLATE:
        raise PluginError("compressed records inflate to more than %d MB in total" % (MAX_PLUGIN_INFLATE // MB))
    d = zlib.decompressobj()
    try:
        out = d.decompress(data[4:], want + 1)  # never more than one byte past the declared size
    except zlib.error as e:
        raise PluginError("compressed record %s %08X does not inflate: %s" % (rname, rid, e))
    if len(out) > want:
        raise PluginError("compressed record %s %08X inflates past the %d bytes its header says" % (rname, rid, want))
    if not d.eof:
        raise PluginError("compressed record %s %08X: zlib stream is truncated" % (rname, rid))
    if d.unused_data:
        raise PluginError("compressed record %s %08X has trailing bytes" % (rname, rid))
    if len(out) != want:
        raise PluginError("compressed record %s %08X inflates to %d bytes, header says %d" % (rname, rid, len(out), want))
    return out


def _walk(buf, off, end, info):
    """Iterative GRUP/record walker (no recursion, nesting bounded by MAX_GRUP_DEPTH)."""
    ends = [end]  # end offset of the file, then of every enclosing GRUP
    while True:
        cur = ends[-1]
        if off == cur:
            if len(ends) == 1:
                return
            ends.pop()
            continue
        if off + 24 > cur:
            raise PluginError("truncated record/group header at %#x" % off)
        if buf[off: off + 4] == b"GRUP":
            gsize = struct.unpack_from("<I", buf, off + 4)[0]
            if gsize < 24 or off + gsize > cur:
                raise PluginError("bad GRUP size %d at %#x" % (gsize, off))
            if len(ends) > MAX_GRUP_DEPTH:
                raise PluginError("GRUPs nested deeper than %d at %#x" % (MAX_GRUP_DEPTH, off))
            info.groups += 1
            ends.append(off + gsize)
            off += 24
            continue
        rtype, dsize, rflags, rid = struct.unpack_from("<4sIII", buf, off)
        rname = rtype.decode("latin-1")
        if not re.match(r"^[A-Z0-9_]{4}$", rname):
            raise PluginError("garbage record type %r at %#x" % (rtype, off))
        if off + 24 + dsize > cur:
            raise PluginError("record %s %08X at %#x overruns its group" % (rname, rid, off))
        data = buf[off + 24: off + 24 + dsize]
        if rflags & COMPRESSED_FLAG:
            data = inflate_record(data, rname, rid, info)
        edid = None
        for st, sd in iter_subrecords(data, "record %s %08X" % (rname, rid)):
            if st == "EDID" and edid is None:
                edid = zstring(sd)
            info.scan_strings(sd)
        info.records.append((rname, rid, edid))
        off += 24 + dsize


# --------------------------------------------------------------------------------------------
# Papyrus helpers (same logic as tools/modkit/papyrus/check_string_escapes.py)
# --------------------------------------------------------------------------------------------
def scan_psc_text(text):
    """Return (escape problems [(line, col, text)], comment text) for a .psc source.

    String literals only; comments ';', block comments ';/ /;' and doc strings '{ }' skipped.
    """
    problems, comments = [], []
    in_block = False   # ;/ ... /;
    in_doc = False     # { ... }
    for no, line in enumerate(text.splitlines(), 1):
        i, n, in_str = 0, len(line), False
        while i < n:
            c = line[i]
            two = line[i:i + 2]
            if in_block:
                comments.append(c)
                if two == "/;":
                    in_block = False
                    i += 2
                    continue
            elif in_doc:
                comments.append(c)
                if c == "}":
                    in_doc = False
            elif in_str:
                if c == "\\":
                    problems.append((no, i + 1, line.strip()))
                    i += 2
                    continue
                if c == '"':
                    in_str = False
            else:
                if two == ";/":
                    in_block = True
                    i += 2
                    continue
                if c == ";":
                    comments.append(line[i:])
                    break
                if c == "{":
                    in_doc = True
                elif c == '"':
                    in_str = True
            i += 1
        comments.append("\n")
    return problems, "".join(comments)


class PexInfo:
    def __init__(self):
        self.source = self.user = self.machine = ""
        self.strings = []
        self.error = None


def parse_pex(data):
    """Header strings and string table of a Skyrim PEX (big-endian)."""
    p = PexInfo()
    try:
        if len(data) < 16 or struct.unpack_from(">I", data, 0)[0] != PEX_MAGIC:
            raise ValueError("not a Skyrim PEX file (magic 0xFA57C0DE missing)")
        off = 16
        head = []
        for _ in range(3):  # source file name, user name, machine name
            (n,) = struct.unpack_from(">H", data, off)
            if off + 2 + n > len(data):
                raise ValueError("header string overruns the file")
            head.append(data[off + 2: off + 2 + n].decode("latin-1"))
            off += 2 + n
        p.source, p.user, p.machine = head
        (count,) = struct.unpack_from(">H", data, off)
        off += 2
        for _ in range(count):
            (n,) = struct.unpack_from(">H", data, off)
            if off + 2 + n > len(data):
                raise ValueError("string table overruns the file")
            p.strings.append(data[off + 2: off + 2 + n].decode("latin-1"))
            off += 2 + n
    except (ValueError, struct.error) as e:
        p.error = str(e)
    return p


def prefix_of(name):
    m = re.match(r"^([A-Za-z0-9]+_)", name)
    return m.group(1) if m else None


# --------------------------------------------------------------------------------------------
# FOMOD parsing
# --------------------------------------------------------------------------------------------
def local_tag(el):
    tag = el.tag if isinstance(el.tag, str) else ""
    return tag.rsplit("}", 1)[-1].lower()


class FomodSource:
    def __init__(self, kind, source, destination, context):
        self.kind = kind            # "file" or "folder"
        self.source = norm_path(source)
        self.destination = destination
        self.context = context      # ("required",) / ("plugin", group_id, group_type, plugin_id) / ("cond", id)


def parse_module_config(xml_bytes):
    """Return (sources, images, module_name). Raises ET.ParseError on bad XML."""
    root = ET.fromstring(xml_bytes)
    parent = {}
    for p in root.iter():
        for c in list(p):
            parent[c] = p
    sources, images, module_name = [], [], None
    for el in root.iter():
        tag = local_tag(el)
        if tag == "modulename" and module_name is None:
            module_name = (el.text or "").strip()
        elif tag in ("file", "folder") and "source" in el.attrib:
            ctx = ("other", id(el))
            node, group, plugin = el, None, None
            while node in parent:
                node = parent[node]
                t = local_tag(node)
                if t == "plugin" and plugin is None:
                    plugin = node
                elif t == "group" and group is None:
                    group = node
                elif t == "requiredinstallfiles":
                    ctx = ("required",)
                    break
                elif t == "pattern":
                    ctx = ("cond", id(node))
                    break
            if plugin is not None and group is not None:
                ctx = ("plugin", id(group), group.attrib.get("type", ""), id(plugin))
            # Either flag permits installation independently of option selection.
            # installIfUsable is conservative: dependencyType/defaultType may make it usable.
            if any(el.attrib.get(flag, "false").strip().lower() in ("true", "1")
                   for flag in ("alwaysInstall", "installIfUsable")):
                ctx = ("independent", id(el))
            dest = el.attrib.get("destination")
            sources.append(FomodSource(tag, el.attrib["source"], dest, ctx))
        elif tag in ("image", "moduleimage") and el.attrib.get("path"):
            images.append(el.attrib["path"])
    return sources, images, module_name


def exclusive(a, b):
    """True only if two install contexts can provably never both be active: two different
    <plugin> options of one SelectExactlyOne / SelectAtMostOne group. Conditional patterns
    are not evaluated (several can match at once), so they never count as exclusive."""
    return (a[0] == "plugin" and b[0] == "plugin" and a[1] == b[1] and a[3] != b[3]
            and a[2] in ("SelectExactlyOne", "SelectAtMostOne"))


def xml_values(data, name):
    """Text of every element whose namespace-free local name is `name` (case-insensitive).
    Comments are not elements, so a commented-out tag never counts. Raises ET.ParseError."""
    root = ET.fromstring(data)
    want = name.lower()
    return ["".join(el.itertext()).strip() for el in root.iter() if local_tag(el) == want]


# --------------------------------------------------------------------------------------------
# Verification context
# --------------------------------------------------------------------------------------------
class Context:
    def __init__(self, args, pkg, repo):
        self.args, self.pkg, self.repo = args, pkg, repo
        self.report = Report()
        self.plugins = {}         # entry path -> PluginInfo
        self.pex = {}             # entry path -> PexInfo
        self.versions = []        # (source, value)
        self.allow_masters = [m.lower() for m in (args.allow_master or []) + repo.allow_masters]
        self.allow_large = (args.allow_large or []) + repo.allow_large
        self.fomod_sources = None
        self.prefixes = set()
        self.sibling_prefixes = set()
        self.deny_hashes = set()
        self.others = []

    def own_plugins(self):
        return [(p, i) for p, i in sorted(self.plugins.items())]


def is_vanilla_plugin_name(base):
    low = base.lower()
    return low in VANILLA_MASTER_FILES or bool(CC_RE.match(low))


def load_plugin(e):
    """Parse a plugin entry; unreadable or over-limit entries become a PluginInfo with an error."""
    if e.blocked or e.size > CONTENT_SCAN_LIMIT:
        info = PluginInfo(e.base)
        info.error = "not parsed: %s" % (e.blocked or "%.1f MB is above the %d MB in-memory limit for plugins"
                                         % (e.size / float(MB), CONTENT_SCAN_LIMIT // MB))
        return info
    data = e.data()
    if e.error:
        info = PluginInfo(e.base)
        info.error = "cannot read entry: %s" % e.error
        return info
    return parse_plugin(data, e.base)


def load_plugins(ctx):
    for e in ctx.pkg.entries:
        if e.ext in PLUGIN_EXTS and not is_vanilla_plugin_name(e.base):
            ctx.plugins[e.path] = load_plugin(e)
    stems = [os.path.splitext(os.path.basename(p))[0] for p in ctx.plugins]
    reg_lower = {k.lower(): v for k, v in REGISTRY.items()}
    for s in stems:
        if s.lower() in reg_lower:
            ctx.prefixes.add(reg_lower[s.lower()])
    if not ctx.prefixes:
        counts = collections.Counter()
        for e in ctx.pkg.entries:
            if e.ext in (".psc", ".pex") and prefix_of(e.stem):
                counts[prefix_of(e.stem)] += 1
        for info in ctx.plugins.values():
            for _t, _f, edid in info.own:
                if edid and prefix_of(edid):
                    counts[prefix_of(edid)] += 1
        if counts:
            ctx.prefixes.add(counts.most_common(1)[0][0])
    own = {p.lower() for p in ctx.prefixes}
    ctx.sibling_prefixes = {p for p in set(REGISTRY.values()) if p.lower() not in own}


# --------------------------------------------------------------------------------------------
# Check 1: ESL / plugin structure
# --------------------------------------------------------------------------------------------
def check_plugins(ctx):
    r = ctx.report
    if not ctx.plugins:
        r.warn("PLUGIN-NONE", "", "no plugin (.esp/.esm/.esl) in the package")
        return
    docs_esl = ctx.repo.claims_esl()
    for path, info in ctx.own_plugins():
        if info.error and info.version is None:
            r.fail("PLUGIN-STRUCT", path, info.error)
            continue
        if info.esl:
            r.ok("ESL-FLAG", "%s is ESL-flagged (flags %#x)" % (info.name, info.flags))
        else:
            r.fail("ESL-FLAG", path, "ESL flag 0x200 is not set (TES4 flags %#x)" % info.flags)
        if info.error:
            r.fail("PLUGIN-STRUCT", path, info.error)
        else:
            r.ok("PLUGIN-STRUCT", "%s: %d records + %d groups walk cleanly to the end of the file"
                 % (info.name, len(info.records), info.groups))
        own, overrides, bad = info.own, info.overrides, info.bad_index
        if bad:
            r.capped("FAIL", "PLUGIN-FORMID", [(path, "%s %08X%s: master index %d but only %d masters"
                     % (t, fid, " (%s)" % e if e else "", fid >> 24, len(info.masters))) for t, fid, e in bad],
                     "records with a bad master index")
        if info.esl or docs_esl:
            out = [(t, fid, e) for t, fid, e in own if not ESL_MIN <= (fid & 0xFFFFFF) <= ESL_MAX]
            if out:
                r.capped("FAIL", "ESL-RANGE", [(path, "%s objectid %06X%s outside 0x800-0xFFF"
                         % (t, fid & 0xFFFFFF, " " + e if e else "")) for t, fid, e in out],
                         "own records outside the ESL range")
            if len(own) > ESL_MAX_RECORDS:
                r.fail("ESL-RANGE", path, "%d own records, an ESL holds at most %d" % (len(own), ESL_MAX_RECORDS))
            if not out and len(own) <= ESL_MAX_RECORDS:
                ids = [fid & 0xFFFFFF for _t, fid, _e in own]
                r.ok("ESL-RANGE", "%s: %d own records%s" % (info.name, len(own),
                     ", objectids %03X-%03X" % (min(ids), max(ids)) if ids else ""))
            if info.next_id is not None and info.next_id > ESL_MAX:
                r.fail("PLUGIN-HEDR", path, "HEDR next object id %#x is above 0xFFF" % info.next_id)
        if not info.error:
            want = len(info.records) + info.groups
            if info.hedr_records != want:
                r.fail("PLUGIN-HEDR", path, "HEDR record count %d, file has %d records + %d groups = %d"
                       % (info.hedr_records, len(info.records), info.groups, want))
            else:
                r.ok("PLUGIN-HEDR", "%s: HEDR v%.2f, count %d, next id %#x" % (info.name, info.version, want, info.next_id))
        if info.version not in (1.7, 1.71):
            r.warn("PLUGIN-HEDR", path, "HEDR version %s, expected 1.70 or 1.71" % info.version)
        r.info("OVERRIDES", "%s: %d overrides" % (info.name, len(overrides)))
        if overrides and ctx.repo.claims_no_overrides():
            r.capped("FAIL", "OVERRIDE-CLAIM", [(path, "docs say no vanilla records are edited, but %s %08X%s overrides a master"
                     % (t, fid, " (%s)" % e if e else "")) for t, fid, e in overrides], "overrides")


# --------------------------------------------------------------------------------------------
# Check 2: version consistency
# --------------------------------------------------------------------------------------------
VER = r"(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)"


def xml_single(r, data, name, path, what):
    """(value, ok) of the <name> element(s) of an XML document. Several elements with
    different values are a VER-XML-CONFLICT FAIL; ill-formed XML gives (None, False)."""
    try:
        vals = [v for v in xml_values(data, name) if v]
    except ET.ParseError:
        return None, False
    if len(set(vals)) > 1:
        r.fail("VER-XML-CONFLICT", path, "%s has %d <%s> elements that disagree: %s"
               % (what, len(vals), name, ", ".join(sorted(set(vals)))))
        return None, True
    return (vals[0] if vals else None), True


def check_versions(ctx):
    r, repo, pkg = ctx.report, ctx.repo, ctx.pkg
    src = []  # (label, value)

    if repo.changelog is None:
        r.warn("VER-CHANGELOG", "CHANGELOG.md", "not found in the repo")
    else:
        heading = None
        for line in repo.changelog.splitlines():
            m = re.match(r"^##\s*\[([^\]]+)\](.*)$", line)
            if m and m.group(1).strip().lower() != "unreleased":
                heading = (m.group(1).strip(), m.group(2))
                break
        if heading is None:
            r.fail("VER-CHANGELOG", "CHANGELOG.md", "no released '## [x.y.z]' section")
        else:
            if not re.match(r"^\d+\.\d+\.\d+", heading[0]):
                r.fail("VER-CHANGELOG", "CHANGELOG.md", "top section [%s] is not a x.y.z version" % heading[0])
            if not re.search(r"\d{4}-\d{2}-\d{2}", heading[1]):
                r.fail("VER-CHANGELOG", "CHANGELOG.md", "top section [%s] has no release date" % heading[0])
            src.append(("CHANGELOG.md top section", heading[0]))

    if repo.readme is None:
        r.warn("VER-README", "README.md", "not found in the repo")
    else:
        m = re.search(r"\*\*Status:\s*v?" + VER, repo.readme)
        if m:
            src.append(("README.md **Status:**", m.group(1)))
        else:
            r.warn("VER-README", "README.md", "no '**Status: vX.Y.Z' line")

    info = pkg.find("fomod/info.xml")
    if info is not None:
        before = len(r.findings)
        v, ok = xml_single(r, info.data(), "Version", info.path, "packaged info.xml")
        if not ok:
            r.fail("VER-INFO-MISSING", info.path, "packaged info.xml is not well-formed XML, so it has no <Version>")
        elif len(r.findings) > before:
            pass  # conflicting <Version> elements, reported
        elif not v:
            r.fail("VER-INFO-MISSING", info.path, "packaged info.xml has no <Version> element")
        elif "@VERSION@" in v:
            r.fail("VER-UNRENDERED", info.path, "packaged info.xml still holds the @VERSION@ placeholder")
        else:
            src.append(("package fomod/info.xml <Version>", v))
    else:
        r.fail("VER-INFO-MISSING", "fomod/info.xml", "package has no fomod/info.xml, so no version")

    mc = pkg.find("fomod/ModuleConfig.xml")
    if mc is not None:
        before = len(r.findings)
        name, ok = xml_single(r, mc.data(), "moduleName", mc.path, "packaged ModuleConfig.xml")
        if not ok:
            r.fail("VER-MODULENAME", mc.path, "ModuleConfig.xml is not well-formed XML, so it has no <moduleName>")
        elif len(r.findings) > before:
            pass  # conflicting <moduleName> elements, reported
        elif name is None:
            r.fail("VER-MODULENAME", mc.path, "no <moduleName>")
        elif "@VERSION@" in name:
            r.fail("VER-UNRENDERED", mc.path, "<moduleName> still holds the @VERSION@ placeholder")
        else:
            mv = re.search(VER, name)
            if mv:
                src.append(("package ModuleConfig.xml <moduleName>", mv.group(1)))
            else:
                r.fail("VER-MODULENAME", mc.path, "<moduleName>%s</moduleName> does not contain the version" % name)

    if repo.info_xml is not None:
        v, ok = xml_single(r, repo.info_xml, "Version", "repo:fomod/info.xml", "repo fomod/info.xml")
        if not ok:
            r.warn("VER-SOURCE", "repo:fomod/info.xml", "not well-formed XML, its <Version> is not compared")
        elif v and "@VERSION@" not in v:
            src.append(("repo fomod/info.xml <Version>", v))
        elif v:
            r.info("VER-SOURCE", "repo fomod/info.xml uses the @VERSION@ placeholder")

    if repo.nexus_fields is not None:
        found = 0
        for label, pat in (("docs/NEXUS_FIELDS.md Version:", r"^\s*Version:\s*v?" + VER),
                           ("docs/NEXUS_FIELDS.md File:", r"^\s*-?\s*File:\s*\S+?-v?" + VER + r"\.zip"),
                           ("docs/NEXUS_FIELDS.md File version:", r"^\s*-?\s*File version:\s*v?" + VER)):
            m = re.search(pat, repo.nexus_fields, re.M | re.I)
            if m:
                found += 1
                src.append((label, m.group(1)))
            elif repo.nexus_fields.strip():
                r.warn("VER-NEXUS-FIELD", "docs/NEXUS_FIELDS.md", "no '%s' line" % label.split(" ", 1)[1])
        if not found:
            r.fail("VER-NEXUS-EMPTY", "docs/NEXUS_FIELDS.md", "file is present but empty or holds no version")
    if repo.nexus_page is not None:
        m = re.search(r"\*\*Version:\*\*\s*v?" + VER, repo.nexus_page)
        if m:
            src.append(("docs/NEXUS_PAGE.md **Version:**", m.group(1)))
        else:
            r.fail("VER-NEXUS-EMPTY", "docs/NEXUS_PAGE.md", "file is present but empty or holds no '**Version:**'")

    if ctx.args.tag:
        tag = ctx.args.tag
        if tag.startswith("refs/tags/"):
            tag = tag[len("refs/tags/"):]
        src.append(("--tag %s" % tag, tag[1:] if tag[:1] in "vV" else tag))
        tag_commit = git(repo.root, "rev-parse", "-q", "--verify", "refs/tags/%s^{commit}" % tag)
        head = git(repo.root, "rev-parse", "-q", "--verify", "HEAD^{commit}")
        if tag_commit and head and tag_commit != head:
            r.warn("VER-TAG-COMMIT", tag, "tag points at %s but HEAD is %s" % (tag_commit[:12], head[:12]))
        elif tag_commit and head:
            r.ok("VER-TAG-COMMIT", "tag %s is HEAD (%s)" % (tag, head[:12]))
        else:
            r.info("VER-TAG-COMMIT", "tag %s not found locally, commit not compared" % tag)

    if pkg.kind == "zip":
        base = os.path.basename(pkg.source)
        m = re.match(r"^(.+)-v?" + VER + r"\.zip$", base, re.I)
        if m:
            src.append(("zip file name", m.group(2)))
            stems = {os.path.splitext(os.path.basename(p))[0].lower() for p in ctx.plugins}
            if stems and m.group(1).lower() not in stems:
                r.warn("VER-ZIPNAME", base, "archive name %s does not match a plugin (%s)"
                       % (m.group(1), ", ".join(sorted(stems))))
        else:
            r.fail("VER-ZIPNAME", base, "zip name is not <Name>-<x.y.z>.zip")

    ctx.versions = src
    if not src:
        r.fail("VER-MISMATCH", "", "no version found anywhere")
        return
    ref_label, ref = src[0]
    width = max(len(l) for l, _ in src)
    r.table(["    %-*s  %s" % (width, l, v) for l, v in src])
    bad = [(l, v) for l, v in src[1:] if v != ref]
    for l, v in bad:
        r.fail("VER-MISMATCH", version_source_path(l, pkg), "%s says %s but %s says %s" % (l, v, ref_label, ref))
    if not bad:
        r.ok("VER-MISMATCH", "all %d version sources agree on %s" % (len(src), ref))


def version_source_path(label, pkg):
    """File a version source label refers to (for the finding's path column)."""
    if label.startswith("package fomod/info.xml"):
        return "fomod/info.xml"
    if label.startswith("package ModuleConfig.xml"):
        return "fomod/ModuleConfig.xml"
    if label.startswith("repo fomod/info.xml"):
        return "repo:fomod/info.xml"
    if label == "zip file name":
        return os.path.basename(pkg.source)
    if label.startswith("--tag"):
        return ""
    return label.split(" ", 1)[0]


def git(root, *args):
    try:
        out = subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.decode().strip() if out.returncode == 0 else None


# --------------------------------------------------------------------------------------------
# Check 3: stray files and FOMOD structure
# --------------------------------------------------------------------------------------------
def any_match(name, patterns):
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def is_text(e, head=None):
    """Text file by extension, else by the absence of NUL bytes in the first 8 KB (`head`
    for streamed entries, else the in-memory content)."""
    if e.ext in TEXT_EXTS:
        return True
    if e.ext in BINARY_EXTS:
        return False
    if head is None:
        head = e.data()
    return b"\0" not in head[:8192]


def path_leaks(strings):
    out = []
    for s in strings:
        for m in PATH_LEAK_RE.finditer(s):
            start = max(0, m.start() - 10)
            out.append(truncate(s[start: m.end() + 30], 70))
            break
    return out


def check_sha256(ctx):
    r, pkg = ctx.report, ctx.pkg
    if pkg.kind != "zip":
        return
    side = pkg.source + ".sha256"
    if not os.path.isfile(side):
        r.info("PKG-SHA256", "no %s next to the zip (fine)" % os.path.basename(side))
        return
    text = read_text(side) or ""
    want = text.split()[0].lower() if text.split() else ""
    have = file_sha256(pkg.source)
    if want == have:
        r.ok("PKG-SHA256", "%s matches" % os.path.basename(side))
    else:
        r.fail("PKG-SHA256", os.path.basename(side), "sha256 %s does not match the zip (%s)" % (want[:16] or "(empty)", have[:16]))


def name_rules(r, raw, is_dir):
    """Name-only rules for one zip member (file or directory entry), on the raw stored name."""
    path = norm_path(raw)
    parts = [p for p in path.lower().split("/") if p]
    dirs, base = (parts, "") if is_dir else (parts[:-1], parts[-1] if parts else "")
    shown = raw if is_dir else path
    if "\\" in raw:
        r.fail("ZIP-PATH", raw, "entry name uses backslashes")
    if raw.startswith("/") or raw.startswith("\\") or re.match(r"^[A-Za-z]:", raw):
        r.fail("ZIP-PATH", raw, "absolute entry name")
    if ".." in re.split(r"[\\/]", raw):
        r.fail("ZIP-PATH", raw, "entry name contains '..' (zip-slip)")
    if VCS_PARTS & set(parts) or base in VCS_FILES:
        r.fail("STRAY-VCS", shown, "version-control %s" % ("directory" if is_dir else "file"))
    if BUILD_DIRS & set(dirs):
        r.fail("STRAY-BUILD", shown, "%s a build/output directory (%s/)"
               % ("is" if is_dir and parts[-1] in BUILD_DIRS else "inside", sorted(BUILD_DIRS & set(dirs))[0]))
    if EDITOR_DIRS & set(dirs):
        r.fail("STRAY-TEMP", shown, "editor/temp directory")
    if is_dir:
        return
    if base in OS_JUNK:
        r.fail("STRAY-OS", path, "OS metadata file")
    if not EDITOR_DIRS & set(dirs) and any_match(base, TEMP_PATTERNS):
        r.fail("STRAY-TEMP", path, "editor/temp file")
    if any_match(base, SECRET_NAME_PATTERNS):
        r.fail("SECRET-NAME", path, "secret-looking file name")


def text_encoding(head):
    """Detect Unicode BOMs/signatures and XML declarations before decoding text."""
    for bom, encoding in ((codecs.BOM_UTF32_LE, "utf-32"),
                          (codecs.BOM_UTF32_BE, "utf-32"),
                          (codecs.BOM_UTF16_LE, "utf-16"),
                          (codecs.BOM_UTF16_BE, "utf-16"),
                          (codecs.BOM_UTF8, "utf-8-sig")):
        if head.startswith(bom):
            return encoding
    for signature, encoding in ((b"<\0\0\0", "utf-32-le"), (b"\0\0\0<", "utf-32-be"),
                                (b"<\0", "utf-16-le"), (b"\0<", "utf-16-be")):
        whitespace = {ch.encode(encoding) for ch in " \t\r\n"}
        probe = head
        width = 4 if "32" in encoding else 2
        while len(probe) >= width and probe[:width] in whitespace:
            probe = probe[width:]
        if probe.startswith(signature):
            return encoding
    match = re.match(br"\s*<\?xml\b[^>]*encoding\s*=\s*['\"]([^'\"]+)['\"]", head, re.I)
    if match:
        try:
            encoding = match.group(1).decode("ascii")
            codecs.getincrementaldecoder(encoding)(errors="replace").decode(b"", final=True)
            return encoding
        except (LookupError, ValueError, TypeError):
            pass
    return "utf-8-sig"


def decoded_text(data):
    return data.decode(text_encoding(data[:8192]), errors="replace")


def scan_stream(e):
    """Scan decoded text incrementally, retaining overlap and checking CRC through EOF."""
    head, secret, leak, text = None, None, None, False
    decoder, tail, raw_tail = None, "", b""
    def scan(buf, raw):
        nonlocal secret, leak
        if secret is None:
            for label, rx in SECRET_CONTENT:
                if rx.search(raw) or rx.search(buf.encode("utf-8")):
                    secret = label
                    break
        if text and leak is None:
            hits = path_leaks(buf.splitlines())
            if hits:
                leak = hits[0]
    chunks = iter(e.chunks())
    prefix = bytearray()
    while len(prefix) < 8192:
        part = next(chunks, b"")
        if not part:
            break
        prefix.extend(part)
    for chunk in itertools.chain((bytes(prefix),), chunks):
        if head is None:
            head = chunk[:8192]
            text = is_text(e, head)
            decoder = codecs.getincrementaldecoder(text_encoding(head))(errors="replace")
        buf = tail + decoder.decode(chunk)
        scan(buf, raw_tail + chunk)
        tail, raw_tail = buf[-STREAM_OVERLAP:], chunk[-STREAM_OVERLAP:]
    if decoder is not None:
        scan(tail + decoder.decode(b"", final=True), raw_tail)
    return head or b"", secret, leak, text


def check_files(ctx):
    r, pkg = ctx.report, ctx.pkg
    check_sha256(ctx)
    max_bytes = ctx.args.max_file_mb * MB
    # Duplicates over every stored member, directory entries included.
    seen_exact = collections.Counter(raw for raw, _d in pkg.members)
    for name, n in sorted(seen_exact.items()):
        if n > 1:
            r.fail("ZIP-DUP", name, "entry appears %d times" % n)
    by_case = collections.defaultdict(set)
    for e in pkg.entries:
        by_case[e.lower].add(e.path)
    # Directory spellings: explicit directory entries against each other and against the
    # parent folders of the files ("Fomod/" next to "fomod/info.xml").
    dir_spell = collections.defaultdict(set)
    explicit = set()
    for raw, is_dir in pkg.members:
        if is_dir:
            d = norm_path(raw).rstrip("/")
            if d:
                dir_spell[d.lower()].add(d)
                explicit.add(d.lower())
    for e in pkg.entries:
        parts = e.path.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d.lower() in explicit:
                dir_spell[d.lower()].add(d)
    for low, names in sorted(list(by_case.items()) + [(k, {n + "/" for n in v}) for k, v in dir_spell.items()]):
        if len(names) > 1:
            r.fail("ZIP-CASE-DUP", sorted(names)[0], "case-insensitive duplicate of %s" % ", ".join(sorted(names)[1:]))
    leaks, secrets = [], []
    n_problems = len(r.findings)
    for raw, is_dir in pkg.members:
        name_rules(r, raw, is_dir)
    for e in pkg.entries:
        if e.ext in EXEC_FAIL_EXTS:
            r.fail("STRAY-EXEC", e.path, "executable/script file (%s)" % e.ext)
        elif e.ext in EXEC_WARN_EXTS:
            r.warn("STRAY-EXEC", e.path, "DLL in the package (SKSE plugin?), make sure it is meant to ship")
        if e.size > max_bytes:
            if any(fnmatch.fnmatch(e.lower, g.lower()) or fnmatch.fnmatch(e.base.lower(), g.lower()) for g in ctx.allow_large):
                r.allowed("STRAY-LARGE", e.path, "%.1f MB, allowlisted (content checks still run)" % (e.size / float(MB)))
            else:
                r.fail("STRAY-LARGE", e.path, "%.1f MB is above --max-file-mb %s" % (e.size / float(MB), ctx.args.max_file_mb))
        if e.ext in NESTED_EXTS:
            r.fail("NESTED-ARCHIVE", e.path, "archive inside the archive")
        if e.blocked:
            # Not waivable: the content is never read, so nothing else could be checked.
            r.fail("ZIP-BOMB", e.path, "%s; content not read" % e.blocked)
            continue
        if e.size <= CONTENT_SCAN_LIMIT:
            data = e.data()
            if e.error:
                r.fail("ZIP-CORRUPT", e.path, "cannot read entry: %s" % e.error)
                continue
            head, secret = data[:8192], None
            for label, rx in SECRET_CONTENT:
                if rx.search(data) or (is_text(e) and rx.search(decoded_text(data).encode("utf-8"))):
                    secret = label
                    break
            if e.ext in PLUGIN_EXTS:
                info = ctx.plugins.get(e.path)
                found = info.leaks if info else []
            elif e.ext == ".pex":
                p = ctx.pex.get(e.path) or parse_pex(data)
                found = path_leaks([p.source, p.user, p.machine] + p.strings)
            elif is_text(e):
                found = path_leaks(decoded_text(data).splitlines())
            else:
                found = []
        else:
            # Big (allowlisted or not) file: same content checks, streamed.
            head, secret, leak, _text = scan_stream(e)
            if e.error:
                r.fail("ZIP-CORRUPT", e.path, "cannot read entry: %s" % e.error)
                continue
            found = [leak] if leak else []
        if e.ext not in NESTED_EXTS:
            for magic, kind in NESTED_MAGIC:
                if head.startswith(magic):
                    r.fail("NESTED-ARCHIVE", e.path, "file content is a %s archive" % kind)
                    break
        if secret:
            secrets.append((e.path, "content looks like a %s (value not shown)" % secret))
        for snippet in found:
            leaks.append((e.path, "absolute path leak: %s" % snippet))
        e.release()
    r.capped("FAIL", "SECRET-CONTENT", secrets, "files with secret-looking content")
    r.capped("FAIL", "PATH-LEAK", leaks, "files with absolute paths")
    if not r.problems_since(n_problems):
        r.ok("STRAY", "%d files: no stray, temp, secret, executable, oversize or nested-archive files, no path leaks"
             % len(pkg.entries))
    check_fomod(ctx)


def check_fomod(ctx):
    r, pkg = ctx.report, ctx.pkg
    before = len(r.findings)
    info, mc = pkg.find("fomod/info.xml"), pkg.find("fomod/ModuleConfig.xml")
    if info is None:
        r.fail("FOMOD-MISSING", "fomod/info.xml", "missing")
    else:
        try:
            ET.fromstring(info.data())
        except ET.ParseError as e:
            r.fail("FOMOD-XML", info.path, "ill-formed XML: %s" % e)
    if mc is None:
        r.fail("FOMOD-MISSING", "fomod/ModuleConfig.xml", "missing")
        return
    try:
        sources, images, _name = parse_module_config(mc.data())
    except ET.ParseError as e:
        r.fail("FOMOD-XML", mc.path, "ill-formed XML: %s" % e)
        return
    ctx.fomod_sources = sources
    # Existence of every referenced source and image.
    file_sources = {s.source.lower() for s in sources if s.kind == "file"}
    folder_sources = {s.source.lower().rstrip("/") for s in sources if s.kind == "folder"}
    for s in sources:
        if s.kind == "file":
            if pkg.find(s.source) is None:
                r.fail("FOMOD-MISSING-SOURCE", s.source, "<file source> does not exist in the package")
        else:
            if not s.source.strip("/"):
                continue
            if not pkg.under(s.source):
                if pkg.has_dir(s.source):
                    r.fail("FOMOD-EMPTY-FOLDER", s.source, "<folder source> is empty")
                else:
                    r.fail("FOMOD-MISSING-SOURCE", s.source, "<folder source> does not exist in the package")
    for img in images:
        if pkg.find(img) is None:
            r.fail("FOMOD-MISSING-SOURCE", norm_path(img), "image path does not exist in the package")
    # Top level: fomod/ plus the top-level folders of the referenced sources.
    tops = {"fomod"}
    for s in sources:
        first = s.source.lower().split("/", 1)[0]
        if first:
            tops.add(first)
    root_all = any(not s.source.strip("/") for s in sources if s.kind == "folder")
    unref, bad_tops = [], set()
    for e in pkg.entries:
        parts = e.lower.split("/")
        if len(parts) == 1:
            if e.lower not in file_sources:
                r.fail("STRAY-TOPLEVEL", e.path, "loose file at the top level of the package")
            continue
        if parts[0] not in tops and not root_all:
            bad_tops.add(parts[0])
            r.fail("STRAY-TOPLEVEL", e.path, "top-level folder '%s/' is not fomod/ and not referenced by ModuleConfig.xml" % e.path.split("/", 1)[0])
            continue
        if parts[0] == "fomod" or root_all:
            continue
        covered = e.lower in file_sources or any(e.lower.startswith(f + "/") for f in folder_sources)
        if not covered:
            unref.append((e.path, "not installed by any <file>/<folder> in ModuleConfig.xml"))
    # Directory entries count too, even when nothing is stored under them.
    for raw, is_dir in pkg.members:
        first = norm_path(raw).split("/", 1)[0]
        if is_dir and first and first.lower() not in tops and first.lower() not in bad_tops and not root_all:
            bad_tops.add(first.lower())
            r.fail("STRAY-TOPLEVEL", raw, "top-level folder '%s/' is not fomod/ and not referenced by ModuleConfig.xml" % first)
    r.capped("FAIL", "STRAY-UNREFERENCED", unref, "unreferenced files")
    # Destination conflicts.
    def canonical_destination(raw):
        path = raw.replace("\\", "/")
        if path.startswith("/") or re.match(r"^[A-Za-z]:", path):
            r.fail("FOMOD-DEST-PATH", raw, "absolute install destination")
            return None
        parts = []
        for part in path.split("/"):
            part = part.rstrip(" ")
            if part == "..":
                if not parts:
                    r.fail("FOMOD-DEST-PATH", raw, "install destination escapes root")
                    return None
                parts.pop()
            elif part and part != ".":
                part = part.rstrip(". ")
                if part:
                    parts.append(part)
        return "/".join(parts).lower()

    dest = collections.defaultdict(list)  # dest lower -> [(source entry path, context)]
    for s in sources:
        if s.kind == "file":
            d = s.destination if s.destination is not None else s.source
            if not d or d.endswith(("/", "\\")):
                d = d + s.source.rsplit("/", 1)[-1]
            key = canonical_destination(d)
            if key is not None:
                dest[key].append((s.source.lower(), s.context, d))
        else:
            base = canonical_destination(s.destination if s.destination is not None else s.source)
            if base is None:
                continue
            for e in pkg.under(s.source):
                rel = e.path[len(s.source.rstrip("/")) + 1:] if s.source.strip("/") else e.path
                d = (base + "/" + rel) if base else rel
                key = canonical_destination(d)
                if key is not None:
                    dest[key].append((e.lower, s.context, d))
    conflicts = []
    for low, items in sorted(dest.items()):
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                a, b = items[i], items[j]
                if a[0] != b[0] and not exclusive(a[1], b[1]):
                    conflicts.append((items[0][2], "installed from both %s and %s" % (a[0], b[0])))
                    break
            else:
                continue
            break
    r.capped("FAIL", "FOMOD-DEST-CONFLICT", conflicts, "destination conflicts")
    if not r.problems_since(before):
        r.ok("FOMOD", "info.xml + ModuleConfig.xml well-formed, %d sources (%s) all present, every file referenced"
             % (len(sources), ", ".join(sorted({s.source for s in sources}))))


# --------------------------------------------------------------------------------------------
# Check 4: Bethesda assets (names and patterns only)
# --------------------------------------------------------------------------------------------
def load_deny_hashes(path):
    text = read_text(path)
    if text is None:
        raise InputError("cannot read --deny-hashes %s" % path)
    out = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        tok = line.split()[0].lower()
        if not re.match(r"^[0-9a-f]{64}$", tok):
            raise InputError("--deny-hashes %s: not a sha256: %s" % (path, truncate(tok, 20)))
        out.add(tok)
    return out


def check_bethesda(ctx):
    r, pkg = ctx.report, ctx.pkg
    before = len(r.findings)
    deny = ctx.deny_hashes
    for e in pkg.entries:
        low, base = e.lower, e.base.lower()
        if any_match(base, VANILLA_ARCHIVES):
            r.fail("BETH-ARCHIVE", e.path, "vanilla game archive name")
        elif CC_RE.match(base):
            r.fail("BETH-CC", e.path, "Creation Club file name")
        elif e.ext in OTHER_ARCHIVE_EXTS:
            r.warn("BETH-ARCHIVE-OTHER", e.path, "BSA/BA2 archive: confirm it holds only the mod's own content")
        if base in VANILLA_MASTER_FILES:
            r.fail("BETH-MASTER", e.path, "vanilla master file shipped")
        if any_match(base, TOOL_PATTERNS) or "pyro" in low.split("/")[:-1]:
            r.fail("BETH-TOOL", e.path, "game/compiler/tool binary")
        elif any_match(base, SKSE_DLL_PATTERNS):
            r.warn("BETH-SKSE", e.path, "SKSE runtime DLL: SKSE must be installed by the user, not bundled")
        if VANILLA_STRINGS_RE.search(low):
            r.fail("BETH-STRINGS", e.path, "vanilla strings file")
        if VANILLA_VOICE_RE.search(low):
            r.fail("BETH-VOICE", e.path, "file in a vanilla voice folder")
        if e.ext in (".psc", ".pex"):
            stem = e.stem.lower()
            if stem in VANILLA_SCRIPTS:
                r.fail("BETH-SCRIPT", e.path, "vanilla script name (base game script/class)")
            elif stem in SKSE_SCRIPTS or stem.startswith("skse"):
                r.warn("BETH-SKSE-SCRIPT", e.path, "SKSE script name: SKSE's own scripts must not be bundled")
        if e.ext == ".psc":
            _p, comments = scan_psc_text(e.data().decode("utf-8-sig", errors="replace"))
            if re.search(r"bethesda", comments, re.I):
                r.warn("BETH-PSC-HEADER", e.path, "comment mentions Bethesda: is this a vanilla source?")
        if VANILLA_ASSET_RE.search(low):
            r.warn("BETH-VANILLA-PATH", e.path, "asset under a vanilla folder: make sure it is own work")
        if deny and e.blocked:
            r.info("BETH-HASH-SKIPPED", "%s: hashing skipped: %s" % (e.path, e.blocked))
        if deny and not e.blocked:
            if e.size <= CONTENT_SCAN_LIMIT and not e.blocked:
                digest = hashlib.sha256(e.data()).hexdigest()
            else:  # big permitted entry: hash it streamed, in constant memory
                h = hashlib.sha256()
                for chunk in e.chunks():
                    h.update(chunk)
                digest = h.hexdigest()
            if not e.error and digest in deny:
                r.fail("BETH-HASH", e.path, "sha256 is on the --deny-hashes list")
        e.release()
    if not r.problems_since(before):
        r.ok("BETH", "no vanilla archives, masters, strings, voice, scripts or tool binaries%s"
             % (", %d deny hashes checked" % len(deny) if deny else " (no --deny-hashes given)"))


# --------------------------------------------------------------------------------------------
# Check 5: Papyrus and names
# --------------------------------------------------------------------------------------------
def check_papyrus(ctx):
    r, pkg = ctx.report, ctx.pkg
    before = len(r.findings)
    pex = [e for e in pkg.entries if e.ext == ".pex"]
    psc = [e for e in pkg.entries if e.ext == ".psc"]
    for e in pex:
        p = ctx.pex.get(e.path) or parse_pex(e.data())
        ctx.pex[e.path] = p
        if p.error:
            r.fail("PEX-PARSE", e.path, p.error)
            continue
        for t in p.strings:
            if PEX_ESCAPE.search(t):
                r.fail("PAPYRUS-ESCAPE", e.path, "compiled string constant holds a literal backslash escape: %r" % truncate(t, 60))
        for label, value in (("source file name", p.source), ("user name", p.user), ("machine name", p.machine)):
            if "/" in value or "\\" in value or re.match(r"^[A-Za-z]:", value):
                r.fail("PEX-HEADER-PATH", e.path, "PEX header %s holds a path: %s" % (label, truncate(value, 60)))
        for label, value in (("user name", p.user), ("machine name", p.machine)):
            if value.strip().lower() not in PEX_NORMALIZED_NAMES:
                r.warn("PEX-HEADER-USER", e.path, "PEX header %s is %r (normalize it, see pex_normalize.py)" % (label, truncate(value, 40)))
        src_base = re.split(r"[\\/]", p.source)[-1]
        if src_base.lower() != (e.stem + ".psc").lower():
            r.warn("PEX-SRCNAME", e.path, "PEX source file name %r does not match %s.psc" % (truncate(p.source, 60), e.stem))
    for e in psc:
        text = e.data().decode("utf-8-sig", errors="replace")
        problems, _c = scan_psc_text(text)
        for no, col, line in problems:
            r.fail("PAPYRUS-ESCAPE", "%s:%d:%d" % (e.path, no, col), "backslash escape in a string literal: %s" % truncate(line, 70))
        m = re.search(r"^\s*ScriptName\s+([A-Za-z0-9_:]+)", text, re.I | re.M)
        if not m:
            r.fail("PSC-SCRIPTNAME", e.path, "no ScriptName line")
        elif m.group(1).lower() != e.stem.lower():
            r.fail("PSC-SCRIPTNAME", e.path, "ScriptName %s does not match the file name %s" % (m.group(1), e.stem))
    pex_stems = {e.stem.lower(): e for e in pex}
    psc_stems = {e.stem.lower(): e for e in psc}
    if psc:
        for s, e in sorted(pex_stems.items()):
            if s not in psc_stems:
                r.fail("PEX-NO-PSC", e.path, "compiled script ships without its .psc source")
        for s, e in sorted(psc_stems.items()):
            if s not in pex_stems:
                r.warn("PSC-NO-PEX", e.path, ".psc source without a compiled .pex")
    elif pex:
        r.warn("PEX-NO-SOURCES", "", "%d .pex scripts ship but no .psc sources" % len(pex))
    # Prefixes.
    stems = sorted({os.path.splitext(os.path.basename(p))[0] for p in ctx.plugins})
    reg_lower = {k.lower() for k in REGISTRY}
    for s in stems:
        if s.lower() not in reg_lower:
            r.warn("REGISTRY-UNKNOWN", s, "plugin stem not in REGISTRY: add the mod (and its prefix) to verify-release.sh")
    own = sorted(ctx.prefixes)
    own_l = tuple(p.lower() for p in own)
    sib_l = tuple(sorted(p.lower() for p in ctx.sibling_prefixes))
    if own:
        r.info("PREFIX", "package prefix %s" % "/".join(own))

    def judge(name, path, what):
        low = name.lower()
        if own_l and low.startswith(own_l):
            return None
        hit = [p for p in sib_l if low.startswith(p)]
        if hit:
            return ("FAIL", "PREFIX-COLLISION", path, "%s %s uses the prefix %s of a sibling mod" % (what, name, hit[0].upper()))
        if own_l:
            return ("WARN", None, path, "%s %s does not start with %s" % (what, name, "/".join(own)))
        return None

    script_names = sorted({e.stem: e.path for e in pex + psc}.items(), key=lambda kv: kv[0].lower())
    script_warn = []
    for name, path in script_names:
        res = judge(name, path, "script")
        if res and res[0] == "FAIL":
            r.fail(res[1], res[2], res[3])
        elif res:
            script_warn.append((res[2], res[3]))
    r.capped("WARN", "SCRIPT-PREFIX", script_warn, "scripts without the prefix")
    edid_warn = []
    for path, info in ctx.own_plugins():
        for t, fid, edid in info.own:
            if not edid:
                continue
            res = judge(edid, path, "%s %s" % (t, "EditorID"))
            if res and res[0] == "FAIL":
                r.fail(res[1], res[2], res[3])
            elif res:
                edid_warn.append((res[2], res[3]))
    r.capped("WARN", "EDID-PREFIX", edid_warn, "EditorIDs without the prefix")
    if ctx.others:
        check_others(ctx)
    if not r.problems_since(before):
        r.ok("PAPYRUS", "%d .pex, %d .psc: parse cleanly, no escapes, names and prefixes fine" % (len(pex), len(psc)))


def check_others(ctx):
    r = ctx.report
    mine, _errors = collect_names(ctx.pkg, ctx.plugins)  # own plugin errors are reported by check 1
    others = []
    for other_path in ctx.others:
        try:
            other = open_package(other_path, ctx.args.max_entry_mb, ctx.args.max_total_mb)
        except InputError as e:
            r.fail("COLLISION-INPUT", other_path, str(e))
            continue
        if other.realpath == ctx.pkg.realpath:
            continue
        if other.kind == "zip" and ctx.pkg.kind == "zip" and file_sha256(other.source) == file_sha256(ctx.pkg.source):
            r.info("COLLISION", "%s is a byte-identical copy of the package, skipped" % other_path)
            continue
        others.append(other)
    unique_labels([ctx.pkg] + others)
    for other in others:
        theirs, errors = collect_names(other)
        for where, err in errors:
            r.fail("COLLISION-INPUT", "%s:%s" % (other.label, where),
                   "plugin does not parse, so its names cannot be compared: %s" % err)
        hits = 0
        for kind in mine:
            for low in sorted(set(mine[kind]) & set(theirs.get(kind, {}))):
                hits += 1
                disp, detail = mine[kind][low]
                odetail = theirs[kind][low][1]
                r.fail("COLLISION-" + kind.upper(), disp, "%s %s%s also in %s%s" % (
                    kind, disp, " [%s]" % detail if detail else "", other.label,
                    " [%s]" % odetail if odetail else ""))
        if not hits and not errors:
            r.ok("COLLISION", "no shared names with %s" % other.label)


# --------------------------------------------------------------------------------------------
# Check 6: plugin masters
# --------------------------------------------------------------------------------------------
def check_masters(ctx):
    r, repo = ctx.report, ctx.repo
    declared = {m.lower() for m in repo.declared_masters()}
    base = {m.lower() for m in BASE_MASTERS}
    base_only = repo.claims_base_game_only()
    for path, info in ctx.own_plugins():
        if info.version is None:
            continue
        bad = False
        for m in info.masters:
            low = m.lower()
            if low == info.name.lower():
                r.fail("MASTER-SELF", path, "lists itself as a master")
                bad = True
            elif low in DLC_MASTERS and base_only:
                r.fail("MASTER-DLC-CLAIM", path, "master %s, but the docs claim Skyrim.esm only / no DLC" % m)
                bad = True
            elif low in base or low in declared:
                continue
            elif low in ctx.allow_masters:
                r.allowed("MASTER-UNDECLARED", path, "master %s is allowlisted" % m)
            else:
                r.fail("MASTER-UNDECLARED", path, "master %s is not a base-game master and not declared in README/NEXUS docs" % m)
                bad = True
        if not bad:
            r.ok("MASTERS", "%s masters: %s" % (info.name, ", ".join(info.masters) or "(none)"))


# --------------------------------------------------------------------------------------------
# Collision mode
# --------------------------------------------------------------------------------------------
COLLISION_KINDS = ("plugin", "script", "edid", "voice", "seq")


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect_names(pkg, plugins=None):
    """Return ({kind: {lowercase name: (display name, detail)}}, [(plugin path, parse error)]).

    EditorIDs are keyed by name alone: the game resolves EditorIDs in one global namespace
    (console, Papyrus, conditions), so the same name in two record types still collides. The
    detail column lists the record type(s) the name has in that package."""
    out = {k: {} for k in COLLISION_KINDS}
    if plugins is None:
        plugins = {}
        for e in pkg.entries:
            if e.ext in PLUGIN_EXTS and not is_vanilla_plugin_name(e.base):
                plugins[e.path] = load_plugin(e)
                e.release()
    errors = [(path, info.error) for path, info in sorted(plugins.items()) if info.error]
    edid_types = {}
    for path, info in sorted(plugins.items()):
        out["plugin"][info.name.lower()] = (info.name, "")
        for t, _fid, edid in info.own:
            if edid:
                low = edid.lower()
                out["edid"].setdefault(low, (edid, ""))
                edid_types.setdefault(low, set()).add(t)
    for low, types in edid_types.items():
        out["edid"][low] = (out["edid"][low][0], "/".join(sorted(types)))
    for e in pkg.entries:
        if e.ext in (".psc", ".pex"):
            out["script"].setdefault(e.stem.lower(), (e.stem, ""))
        elif e.ext == ".seq":
            out["seq"].setdefault(e.stem.lower(), (e.stem, ""))
        # Voice folders live under Sound/Voice/<Plugin>/<VoiceType>/: the voice type itself is
        # usually a vanilla one (MaleNord...), so the folder only collides with the plugin dir.
        m = re.search(r"(?:^|/)(sound/voice/([^/]+/[^/]+))/", e.lower)
        if m:
            disp = e.path[m.start(2):m.end(2)]
            out["voice"].setdefault(m.group(2), (disp, ""))
    return out, errors


def run_collisions(args):
    paths = expand_pkg_args(args.collisions)  # one entry per resolved path
    pkgs, errors = [], []
    opened = [open_package(p, args.max_entry_mb, args.max_total_mb) for p in paths]
    unique_labels(opened)
    for pkg in opened:
        names, errs = collect_names(pkg)
        errors.extend((pkg, where, err) for where, err in errs)
        prefixes = collections.Counter()
        for n, _d in names["script"].values():
            if prefix_of(n):
                prefixes[prefix_of(n)] += 1
        for n, _d in names["edid"].values():
            if prefix_of(n):
                prefixes[prefix_of(n)] += 1
        pkgs.append((pkg, names, prefixes))
    print("verify-release %s collision check over %d packages" % (TOOL_VERSION, len(pkgs)))
    print("")
    print("== Packages")
    for pkg, names, prefixes in pkgs:
        stems = {os.path.splitext(n)[0] for n in names["plugin"]}
        reg = [REGISTRY[k] for k in REGISTRY if k.lower() in stems]
        top = ", ".join("%s%d" % (p, n) for p, n in prefixes.most_common(3)) or "-"
        print("  %-34s registry %-5s names: %s | %s" % (
            pkg.label, "/".join(sorted(set(reg))) or "?",
            ", ".join("%d %s" % (len(names[k]), k) for k in COLLISION_KINDS), "prefixes " + top))
    dupes = []
    for kind in COLLISION_KINDS:
        where = collections.defaultdict(list)
        for i, (pkg, names, _p) in enumerate(pkgs):
            for low, (disp, detail) in names[kind].items():
                where[low].append((pkg.label, disp, detail, i))
        for low, hits in sorted(where.items()):
            if len({h[3] for h in hits}) > 1:  # distinct packages, by resolved path
                dupes.append((kind, hits[0][1], hits))
    totals = {k: sum(len(n[k]) for _p, n, _x in pkgs) for k in COLLISION_KINDS}
    print("")
    print("== Collisions")
    print("  names checked: " + ", ".join("%d %s" % (totals[k], k) for k in COLLISION_KINDS))
    if dupes:
        w = max(len(d[1]) for d in dupes)
        print("  %-7s %-*s  %s" % ("kind", w, "name", "packages"))
        for kind, name, hits in dupes:
            pk = ", ".join("%s%s" % (h[0], " [%s]" % h[2] if h[2] else "") for h in hits)
            print("  %-7s %-*s  %s" % (kind, w, name, pk))
        for kind, name, hits in dupes:
            print("[FAIL] COLLISION-%s %s: in %s" % (kind.upper(), name, ", ".join(
                "%s%s" % (h[0], " [%s]" % h[2] if h[2] else "") for h in hits)))
    else:
        print("[ ok ] COLLISION: no name appears in more than one package")
    for pkg, where, err in errors:
        print("[FAIL] COLLISION-INPUT %s:%s: plugin does not parse, so its names cannot be compared: %s"
              % (pkg.label, where, err))
    per_kind = collections.Counter(d[0] for d in dupes)
    failed = bool(dupes or errors)
    print("")
    if failed:
        parts = []
        if dupes:
            parts.append("%d duplicate names: %s" % (len(dupes), ", ".join("%d %s" % (n, k) for k, n in sorted(per_kind.items()))))
        if errors:
            parts.append("%d unparsable plugins" % len(errors))
        print("RESULT: FAIL (%s)" % "; ".join(parts))
    else:
        print("RESULT: PASS")
    if args.json:
        rep = {"tool": "verify-release", "version": TOOL_VERSION, "mode": "collisions",
               "packages": [{"name": p.label, "source": p.source, "realpath": p.realpath,
                             "counts": {k: len(n[k]) for k in COLLISION_KINDS},
                             "prefixes": dict(px)} for p, n, px in pkgs],
               "duplicates": [{"kind": k, "name": nm, "packages": [h[0] for h in hits],
                               "detail": [h[2] for h in hits]} for k, nm, hits in dupes],
               "errors": [{"package": p.label, "path": w, "error": e} for p, w, e in errors],
               "result": "FAIL" if failed else "PASS"}
        write_json(args.json, rep)
    return 1 if failed else 0


# --------------------------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------------------------
def gh_escape(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=False)
        f.write("\n")


def emit(ctx, failed, n_fail, n_warn):
    r, args = ctx.report, ctx.args
    out = []
    out.append("verify-release %s" % TOOL_VERSION)
    out.append("package: %s (%s, %d files)" % (ctx.pkg.source, ctx.pkg.kind, len(ctx.pkg.entries)))
    out.append("repo:    %s" % ctx.repo.root)
    if ctx.repo.has_waiver:
        out.append("waiver:  %s" % os.path.join(ctx.repo.root, ".verify-release.allow"))
    for check in sorted(CHECK_TITLES):
        items = [f for f in r.findings if f.check == check]
        if args.quiet:
            items = [f for f in items if f.level in ("FAIL", "WARN")]
            if not items:
                continue
        out.append("")
        out.append("== %d. %s" % (check, CHECK_TITLES[check]))
        out.extend(f.line() for f in items)
        if check in r.tables and not args.quiet:
            out.append("  version sources:")
            out.extend(r.tables[check])
    out.append("")
    out.append("RESULT: FAIL (%d fail, %d warn)" % (n_fail, n_warn) if failed else
               "RESULT: PASS" + (" (%d warn)" % n_warn if n_warn else ""))
    print("\n".join(out))
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for f in r.findings:
            if f.level in ("FAIL", "WARN"):
                kind = "error" if f.level == "FAIL" or args.strict else "warning"
                print("::%s title=%s::%s" % (kind, f.code, gh_escape(("%s: " % f.path if f.path else "") + f.message)))
    if args.json:
        write_json(args.json, {
            "tool": "verify-release", "version": TOOL_VERSION, "mode": "verify",
            "package": ctx.pkg.source, "kind": ctx.pkg.kind, "repo": ctx.repo.root,
            "result": "FAIL" if failed else "PASS", "fail": n_fail, "warn": n_warn,
            "strict": bool(args.strict), "versions": [{"source": l, "value": v} for l, v in ctx.versions],
            "findings": [f.as_dict() for f in r.findings]})
    if args.summary:
        md = ["## verify-release: %s %s" % (os.path.basename(ctx.pkg.source), "PASS" if not failed else "FAIL"), ""]
        md.append("%d fail, %d warn (verify-release %s)%s" % (n_fail, n_warn, TOOL_VERSION, ", strict" if args.strict else ""))
        md.append("")
        md.append("| Check | Fail | Warn | OK |")
        md.append("|---|---|---|---|")
        for check in sorted(CHECK_TITLES):
            fs = [f for f in r.findings if f.check == check]
            md.append("| %d. %s | %d | %d | %d |" % (check, CHECK_TITLES[check], sum(f.level == "FAIL" for f in fs),
                                                   sum(f.level == "WARN" for f in fs), sum(f.level == "OK" for f in fs)))
        bad = [f for f in r.findings if f.level in ("FAIL", "WARN", "ALLOWED")]
        if bad:
            md += ["", "| Level | Code | Path | Detail |", "|---|---|---|---|"]
            for f in bad:
                md.append("| %s | `%s` | %s | %s |" % (f.level, f.code, ("`%s`" % f.path) if f.path else "",
                                                       f.message.replace("|", "\\|")))
        if ctx.versions:
            md += ["", "| Version source | Value |", "|---|---|"]
            md += ["| %s | %s |" % (l, v) for l, v in ctx.versions]
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("\n".join(md) + "\n\n")


# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------
def build_parser():
    ap = argparse.ArgumentParser(prog="verify-release.sh", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", metavar="FILE", help="release zip to verify")
    ap.add_argument("--dist", metavar="DIR", help="directory with exactly one zip, or an unpacked package tree")
    ap.add_argument("--repo", metavar="DIR", default=".", help="mod repo the package was built from (default .)")
    ap.add_argument("--tag", metavar="vX.Y.Z", help="release tag to compare (leading v stripped)")
    ap.add_argument("--allow-master", metavar="NAME", action="append", default=[], help="extra allowed master (repeatable)")
    ap.add_argument("--allow-large", metavar="GLOB", action="append", default=[], help="file allowed above --max-file-mb (repeatable)")
    ap.add_argument("--max-file-mb", metavar="N", type=float, default=25, help="largest allowed file in MB (default 25)")
    ap.add_argument("--max-entry-mb", metavar="N", type=float, default=MAX_ENTRY_MB,
                    help="hard limit per entry, never waived: bigger entries are not read (default %d)" % MAX_ENTRY_MB)
    ap.add_argument("--max-total-mb", metavar="N", type=float, default=MAX_TOTAL_MB,
                    help="hard limit on the summed uncompressed size read per package (default %d)" % MAX_TOTAL_MB)
    ap.add_argument("--others", metavar="PKG", nargs="+", default=[], help="sibling packages to check for name collisions")
    ap.add_argument("--deny-hashes", metavar="FILE", help="sha256 list of files that must never ship (none bundled)")
    ap.add_argument("--json", metavar="FILE", help="write a machine-readable report")
    ap.add_argument("--summary", metavar="FILE", help="append a markdown summary (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--strict", action="store_true", help="WARN findings fail the run")
    ap.add_argument("--quiet", action="store_true", help="print only FAIL/WARN lines and the result")
    ap.add_argument("--collisions", metavar="PKG", nargs="+", help="collision mode over these packages")
    ap.add_argument("--version", action="version", version="verify-release %s" % TOOL_VERSION)
    return ap


def main(argv=None):
    ap = build_parser()
    try:
        args = ap.parse_args(sys.argv[1:] if argv is None else argv)
    except SystemExit as e:  # --help / --version / bad arguments
        return int(e.code or 0) if isinstance(e.code, int) else 2
    try:
        return run(ap, args)
    except InputError as e:
        print("verify-release: error: %s" % e, file=sys.stderr)
        return 2
    except (OSError, MemoryError) as e:
        print("verify-release: error: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # defence in depth: never a traceback
        print("RESULT: FAIL (internal error)")
        print("verify-release: internal error, the package could not be checked: %s: %s"
              % (e.__class__.__name__, e), file=sys.stderr)
        return 2


def run(ap, args):
    if not (0 < args.max_entry_mb <= MAX_ENTRY_MB and 0 < args.max_total_mb <= MAX_TOTAL_MB):
        raise InputError("--max-entry-mb must be in (0, %d] and --max-total-mb in (0, %d]"
                         % (MAX_ENTRY_MB, MAX_TOTAL_MB))
    if args.collisions:
        return run_collisions(args)
    if not args.zip and not args.dist:
        ap.print_usage(sys.stderr)
        print("verify-release.sh: error: one of --zip, --dist or --collisions is required", file=sys.stderr)
        return 2
    if args.max_file_mb <= 0:
        raise InputError("--max-file-mb must be positive")
    source = resolve_dist(args.dist, args.zip) if args.dist else args.zip
    pkg = open_package(source, args.max_entry_mb, args.max_total_mb)
    if not os.path.isdir(args.repo):
        raise InputError("--repo %s is not a directory" % args.repo)
    repo = RepoDocs(args.repo)
    ctx = Context(args, pkg, repo)
    ctx.deny_hashes = load_deny_hashes(args.deny_hashes) if args.deny_hashes else set()
    ctx.others = expand_pkg_args(args.others) if args.others else []
    return verify(ctx)


def verify(ctx):
    r = ctx.report
    for err in ctx.repo.waiver_errors:
        r.check = 3
        r.warn("WAIVER", ".verify-release.allow", "unknown line ignored: %s" % err)
    r.check = 1
    try:
        load_plugins(ctx)
    except Exception as e:  # defensive: never a traceback on malformed input
        r.fail("CHECK-ERROR", "", "plugin loading crashed: %s: %s" % (e.__class__.__name__, e))
    for number, fn in ((1, check_plugins), (2, check_versions), (3, check_files),
                       (4, check_bethesda), (5, check_papyrus), (6, check_masters)):
        r.check = number
        try:
            fn(ctx)
        except Exception as e:  # defensive: a malformed package must become a FAIL, not a traceback
            r.fail("CHECK-ERROR", "", "check %d could not finish: %s: %s" % (number, e.__class__.__name__, e))
    n_fail, n_warn = r.count("FAIL"), r.count("WARN")
    failed = n_fail > 0 or (ctx.args.strict and n_warn > 0)
    emit(ctx, failed, n_fail, n_warn)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
