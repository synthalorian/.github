"""Unit tests for scripts/verify-release.sh (stdlib only).

Run: python3 -m unittest discover -s tests/verify_release

Every fixture is generated here: fake TES4 plugins, fake PEX files, FOMOD zips and
a fake repo. No game data is used; vanilla names appear only as file NAMES with
tiny placeholder bytes.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib

sys.dont_write_bytecode = True  # no __pycache__ next to scripts/verify-release.sh

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(ROOT, "scripts", "verify-release.sh")


def load_module():
    loader = importlib.machinery.SourceFileLoader("verify_release", SCRIPT)
    spec = importlib.util.spec_from_loader("verify_release", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


vr = load_module()

# ------------------------------------------------------------------------------------------
# Fixture builders
# ------------------------------------------------------------------------------------------
NAME = "WarBanners"      # a REGISTRY stem, prefix WBN_
VERSION = "0.1.0"


def sub(typ, data):
    return typ.encode() + struct.pack("<H", len(data)) + data


def zstr(s):
    return s.encode("cp1252") + b"\0"


def record(typ, formid, edid=None, flags=0, compressed=False, extra=b""):
    data = (sub("EDID", zstr(edid)) if edid else b"") + extra
    if compressed:
        flags |= 0x40000
        data = struct.pack("<I", len(data)) + zlib.compress(data)
    return typ.encode() + struct.pack("<III", len(data), flags, formid) + struct.pack("<IHH", 0, 44, 0) + data


def grup(label, body):
    return b"GRUP" + struct.pack("<I", 24 + len(body)) + label.encode() + struct.pack("<iHHI", 0, 0, 0, 0) + body


def plugin(records=None, flags=0x200, masters=("Skyrim.esm",), version=1.7, hedr_count=None,
           next_id=None, raw_extra=b""):
    """records: list of (type, objectid, edid, master_index or None, compressed)."""
    if records is None:
        records = [("GLOB", 0x800, "WBN_Enabled", None, False), ("QUST", 0x801, "WBN_MainQuest", None, True),
                   ("MISC", 0x802, "WBN_Banner", None, False)]
    by_type = {}
    for typ, oid, edid, idx, comp in records:
        idx = len(masters) if idx is None else idx
        by_type.setdefault(typ, []).append(record(typ, (idx << 24) | oid, edid, compressed=comp))
    body = b"".join(grup(t, b"".join(rs)) for t, rs in by_type.items())
    count = len(records) + len(by_type) if hedr_count is None else hedr_count
    own = [oid for _t, oid, _e, idx, _c in records if idx is None]
    nid = (max(own) + 1 if own else 0x800) if next_id is None else next_id
    head = sub("HEDR", struct.pack("<fiI", version, count, nid)) + sub("CNAM", zstr("tester"))
    for m in masters:
        head += sub("MAST", zstr(m)) + sub("DATA", b"\0" * 8)
    tes4 = b"TES4" + struct.pack("<III", len(head), flags, 0) + struct.pack("<IHH", 0, 44, 0) + head
    return tes4 + body + raw_extra


def wstr(s):
    b = s.encode("latin-1")
    return struct.pack(">H", len(b)) + b


def pex(stem, strings=None, user="modkit", machine="build", source=None):
    strings = ["GetState", "", stem, "Hello there"] if strings is None else strings
    head = struct.pack(">IBBHQ", 0xFA57C0DE, 3, 2, 1, 0)
    body = wstr(source if source is not None else stem + ".psc") + wstr(user) + wstr(machine)
    body += struct.pack(">H", len(strings)) + b"".join(wstr(s) for s in strings)
    return head + body + b"\0" * 8  # debug info flag etc. (not parsed)


def psc(stem, body='Function Hello()\n  Debug.Trace("hello")\nEndFunction\n', extends="Quest"):
    return ("ScriptName %s extends %s\n; a comment\n%s" % (stem, extends, body)).encode()


INFO_XML = """<?xml version="1.0" encoding="UTF-8"?>
<fomod>
  <Name>War Banners</Name>
  <Author>tester</Author>
  <Version>{v}</Version>
</fomod>
"""

MODULE_CONFIG = """<?xml version="1.0" encoding="UTF-8"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://qconsulting.ca/fo3/ModConfig5.0.xsd">
  <moduleName>War Banners {v}</moduleName>
  <requiredInstallFiles>
    <folder source="00 Core" destination="" />
  </requiredInstallFiles>
  <installSteps order="Explicit">
    <installStep name="Options">
      <optionalFileGroups order="Explicit">
        <group name="Extras" type="SelectAny">
          <plugins order="Explicit">
            <plugin name="Papyrus source files">
              <description>Sources.</description>
              <files>
                <folder source="10 Papyrus Sources" destination="" />
              </files>
              <typeDescriptor><type name="Optional" /></typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
  </installSteps>
</config>
"""


def good_entries(name=NAME, prefix="WBN_", version=VERSION):
    scripts = [prefix + "MainScript", prefix + "PlayerAliasScript"]
    e = {
        "00 Core/%s.esp" % name: plugin([("GLOB", 0x800, prefix + "Enabled", None, False),
                                         ("QUST", 0x801, prefix + "MainQuest", None, True),
                                         ("MISC", 0x802, prefix + "Banner", None, False)]),
        "00 Core/SEQ/%s.seq" % name: struct.pack("<I", 0x801),
        "fomod/info.xml": INFO_XML.format(v=version).encode(),
        "fomod/ModuleConfig.xml": MODULE_CONFIG.format(v=version).encode(),
    }
    for s in scripts:
        e["00 Core/Scripts/%s.pex" % s] = pex(s)
        e["10 Papyrus Sources/Source/Scripts/%s.psc" % s] = psc(s)
    return e


def slurp(path, mode="r"):
    with open(path, mode) as f:
        return f.read()


def write_zip(path, entries):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for n, data in entries.items() if isinstance(entries, dict) else entries:
            z.writestr(n, data)
    return path


README = """# War Banners

**Status: v{v}, early beta.** Test fixture.

- Plugin: `{name}.esp`, ESL-flagged, Skyrim.esm is the only master. **No vanilla records edited** (zero overrides).
"""
CHANGELOG = """# Changelog

## [Unreleased]

## [{v}] - 2026-10-01

### Added
- Everything.
"""
NEXUS_FIELDS = """# Nexus upload form

Version: {v} (early beta)

Main file:
- File: {name}-{v}.zip (FOMOD installer)
- File version: {v}

Requirements:
- DLC requirements: none (Skyrim.esm only)
"""
NEXUS_PAGE = """# Page

- **Version:** {v} (early beta)
"""


def write_repo(root, name=NAME, v=VERSION, readme=None, changelog=None, fields=None, page=None, info=None):
    os.makedirs(os.path.join(root, "docs"), exist_ok=True)
    os.makedirs(os.path.join(root, "fomod"), exist_ok=True)
    files = {
        "README.md": README.format(v=v, name=name) if readme is None else readme,
        "CHANGELOG.md": CHANGELOG.format(v=v) if changelog is None else changelog,
        "docs/NEXUS_FIELDS.md": NEXUS_FIELDS.format(v=v, name=name) if fields is None else fields,
        "docs/NEXUS_PAGE.md": NEXUS_PAGE.format(v=v) if page is None else page,
        "fomod/info.xml": INFO_XML.format(v="@VERSION@") if info is None else info,
    }
    for rel, text in files.items():
        with open(os.path.join(root, rel), "w", encoding="utf-8") as f:
            f.write(text)
    return root


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="vr-test-")
        self.repo = write_repo(os.path.join(self.tmp, "repo"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def zip(self, entries=None, name=None, mutate=None):
        entries = good_entries() if entries is None else entries
        if mutate:
            mutate(entries)
        path = os.path.join(self.tmp, name or "%s-%s.zip" % (NAME, VERSION))
        return write_zip(path, entries)

    def run_vr(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = vr.main(list(argv))
        self.out, self.err = out.getvalue(), err.getvalue()
        return code

    def verify(self, entries=None, *extra, **kw):
        z = self.zip(entries, name=kw.get("name"), mutate=kw.get("mutate"))
        return self.run_vr("--zip", z, "--repo", kw.get("repo", self.repo), *extra)

    def assertFinding(self, level, code, text=None):
        tag = {"FAIL": "[FAIL]", "WARN": "[WARN]", "ALLOWED": "[ALLOWED]", "OK": "[ ok ]"}[level]
        lines = [l for l in self.out.splitlines() if l.startswith(tag + " " + code + " ") or l.startswith(tag + " " + code + ":")]
        self.assertTrue(lines, "no %s %s in output:\n%s" % (level, code, self.out))
        if text:
            self.assertTrue(any(text in l for l in lines), "%r not in %s lines:\n%s" % (text, code, "\n".join(lines)))

    def assertFails(self, code, text=None):
        self.assertFinding("FAIL", code, text)
        self.assertIn("RESULT: FAIL", self.out)

    def assertNoFinding(self, code):
        self.assertNotRegex(self.out, r"\[(FAIL|WARN)\] %s\b" % code)


# ------------------------------------------------------------------------------------------
# Good package
# ------------------------------------------------------------------------------------------
class GoodPackage(Base):
    def test_good_package_passes(self):
        self.assertEqual(self.verify(), 0, self.out)
        self.assertIn("RESULT: PASS", self.out)
        self.assertNotIn("[FAIL]", self.out)
        self.assertNotIn("[WARN]", self.out)
        for code in ("ESL-FLAG", "PLUGIN-STRUCT", "ESL-RANGE", "PLUGIN-HEDR", "VER-MISMATCH", "MASTERS"):
            self.assertFinding("OK", code)
        for n in range(1, 7):
            self.assertIn("== %d. " % n, self.out)

    def test_unpacked_tree_and_dist(self):
        tree = os.path.join(self.tmp, "tree")
        for n, data in good_entries().items():
            p = os.path.join(tree, n)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
        self.assertEqual(self.run_vr("--dist", tree, "--repo", self.repo), 0, self.out)
        dist = os.path.join(self.tmp, "dist")
        os.makedirs(dist)
        write_zip(os.path.join(dist, "%s-%s.zip" % (NAME, VERSION)), good_entries())
        self.assertEqual(self.run_vr("--dist", dist, "--repo", self.repo), 0, self.out)
        write_zip(os.path.join(dist, "Other-0.1.0.zip"), good_entries())
        self.assertEqual(self.run_vr("--dist", dist, "--repo", self.repo), 2)
        self.assertIn("pick one with --zip", self.err)
        empty = os.path.join(self.tmp, "empty")
        os.makedirs(empty)
        self.assertEqual(self.run_vr("--dist", empty, "--repo", self.repo), 2)

    def test_json_and_summary(self):
        js, md = os.path.join(self.tmp, "r.json"), os.path.join(self.tmp, "s.md")
        self.assertEqual(self.verify(None, "--json", js, "--summary", md), 0)
        rep = json.loads(slurp(js))
        self.assertEqual(rep["result"], "PASS")
        self.assertTrue(any(f["code"] == "ESL-FLAG" for f in rep["findings"]))
        self.assertIn("## verify-release:", slurp(md))

    def test_sha256_sidecar(self):
        import hashlib
        z = self.zip()
        with open(z + ".sha256", "w") as f:
            f.write(hashlib.sha256(slurp(z, "rb")).hexdigest() + "  x.zip\n")
        self.assertEqual(self.run_vr("--zip", z, "--repo", self.repo), 0)
        self.assertFinding("OK", "PKG-SHA256")
        with open(z + ".sha256", "w") as f:
            f.write("0" * 64 + "  x.zip\n")
        self.assertEqual(self.run_vr("--zip", z, "--repo", self.repo), 1)
        self.assertFails("PKG-SHA256")

    def test_github_annotations(self):
        old = os.environ.get("GITHUB_ACTIONS")
        os.environ["GITHUB_ACTIONS"] = "true"
        try:
            self.verify(None, mutate=lambda e: e.__setitem__("00 Core/.DS_Store", b"x"))
        finally:
            if old is None:
                del os.environ["GITHUB_ACTIONS"]
            else:
                os.environ["GITHUB_ACTIONS"] = old
        self.assertIn("::error title=STRAY-OS::", self.out)

    def test_quiet(self):
        self.assertEqual(self.verify(None, "--quiet"), 0)
        self.assertNotIn("[ ok ]", self.out)
        self.assertIn("RESULT: PASS", self.out)


# ------------------------------------------------------------------------------------------
# 1. ESL / plugin structure
# ------------------------------------------------------------------------------------------
def with_plugin(data):
    return lambda e: e.__setitem__("00 Core/%s.esp" % NAME, data)


class PluginChecks(Base):
    def test_missing_esl_flag(self):
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(flags=0))), 1)
        self.assertFails("ESL-FLAG")

    def test_formid_above_fff(self):
        recs = [("GLOB", 0x800, "WBN_A", None, False), ("GLOB", 0x1000, "WBN_B", None, False)]
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(recs, next_id=0x801))), 1)
        self.assertFails("ESL-RANGE", "001000")

    def test_formid_below_800_reports_every_record(self):
        recs = [("GLOB", 0x10, "WBN_A", None, False), ("MISC", 0x7FF, "WBN_B", None, False),
                ("MISC", 0x800, "WBN_C", None, False)]
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(recs))), 1)
        self.assertFails("ESL-RANGE", "000010 WBN_A")
        self.assertFinding("FAIL", "ESL-RANGE", "0007FF WBN_B")

    def test_range_checked_when_docs_claim_esl_even_without_flag(self):
        recs = [("GLOB", 0x10, "WBN_A", None, False)]
        self.verify(None, mutate=with_plugin(plugin(recs, flags=0)))
        self.assertFails("ESL-RANGE")

    def test_next_object_id_above_fff(self):
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(next_id=0x1000))), 1)
        self.assertFails("PLUGIN-HEDR", "next object id")

    def test_bad_record_count(self):
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(hedr_count=99))), 1)
        self.assertFails("PLUGIN-HEDR", "HEDR record count 99")

    def test_hedr_version_is_warn(self):
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(version=0.94))), 0)
        self.assertFinding("WARN", "PLUGIN-HEDR", "0.94")

    def test_truncated_plugin(self):
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin()[:-7])), 1)
        self.assertFails("PLUGIN-STRUCT")
        self.assertNotIn("Traceback", self.out + self.err)

    def test_garbage_plugin(self):
        self.assertEqual(self.verify(None, mutate=with_plugin(b"not a plugin at all, nope")), 1)
        self.assertFails("PLUGIN-STRUCT", "not a TES4 plugin")

    def test_bad_compressed_record(self):
        good = plugin([("GLOB", 0x800, "WBN_A", None, False)])
        bad = bytearray(plugin([("QUST", 0x800, "WBN_A", None, True)]))
        bad[-3] ^= 0xFF  # corrupt the zlib stream
        self.assertEqual(self.verify(None, mutate=with_plugin(bytes(bad))), 1)
        self.assertFails("PLUGIN-STRUCT")
        info = vr.parse_plugin(good)
        self.assertIsNone(info.error)

    def test_compressed_record_and_xxxx_parse(self):
        big = b"x" * 70000
        rec_data = sub("EDID", zstr("WBN_Big")) + b"XXXX" + struct.pack("<H", 4) + struct.pack("<I", len(big)) + b"DATA" + struct.pack("<H", 0) + big
        rec = b"BOOK" + struct.pack("<III", len(rec_data), 0, (1 << 24) | 0x800) + struct.pack("<IHH", 0, 44, 0) + rec_data
        body = grup("BOOK", rec)
        head = sub("HEDR", struct.pack("<fiI", 1.7, 2, 0x801)) + sub("MAST", zstr("Skyrim.esm")) + sub("DATA", b"\0" * 8)
        data = b"TES4" + struct.pack("<III", len(head), 0x200, 0) + struct.pack("<IHH", 0, 44, 0) + head + body
        info = vr.parse_plugin(data)
        self.assertIsNone(info.error)
        self.assertEqual(info.records[0][2], "WBN_Big")
        info = vr.parse_plugin(plugin([("QUST", 0x800, "WBN_Q", None, True)]))
        self.assertIsNone(info.error)
        self.assertEqual(info.records[0][2], "WBN_Q")

    def test_override_claim_and_bad_master_index(self):
        recs = [("GLOB", 0x800, "WBN_A", None, False), ("NPC_", 0x13BBF, "SomeVanillaNpc", 0, False)]
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(recs))), 1)
        self.assertFails("OVERRIDE-CLAIM")
        self.assertIn("1 overrides", self.out)
        recs = [("GLOB", 0x800, "WBN_A", None, False), ("GLOB", 0x801, "WBN_B", 5, False)]
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(recs))), 1)
        self.assertFails("PLUGIN-FORMID")


# ------------------------------------------------------------------------------------------
# 2. Version consistency
# ------------------------------------------------------------------------------------------
class VersionChecks(Base):
    def test_changelog_mismatch(self):
        write_repo(self.repo, changelog=CHANGELOG.format(v="0.2.0"))
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-MISMATCH", "CHANGELOG.md top section says 0.2.0")

    def test_changelog_needs_date(self):
        write_repo(self.repo, changelog="# Changelog\n\n## [0.1.0]\n")
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-CHANGELOG", "no release date")

    def test_readme_mismatch(self):
        write_repo(self.repo, readme=README.format(v="0.0.9", name=NAME))
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-MISMATCH", "says 0.0.9")

    def test_info_xml_mismatch(self):
        self.assertEqual(self.verify(None, mutate=lambda e: e.__setitem__("fomod/info.xml", INFO_XML.format(v="0.1.1").encode())), 1)
        self.assertFails("VER-MISMATCH", "info.xml <Version> says 0.1.1")

    def test_info_xml_missing_version(self):
        self.assertEqual(self.verify(None, mutate=lambda e: e.__setitem__("fomod/info.xml", b"<fomod><Name>x</Name></fomod>")), 1)
        self.assertFails("VER-INFO-MISSING")

    def test_module_name_mismatch(self):
        self.assertEqual(self.verify(None, mutate=lambda e: e.__setitem__("fomod/ModuleConfig.xml", MODULE_CONFIG.format(v="0.1.7").encode())), 1)
        self.assertFails("VER-MISMATCH", "<moduleName> says 0.1.7")

    def test_repo_info_xml_mismatch(self):
        write_repo(self.repo, info=INFO_XML.format(v="0.0.1"))
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-MISMATCH", "repo fomod/info.xml")

    def test_nexus_mismatch(self):
        write_repo(self.repo, fields=NEXUS_FIELDS.format(v="0.1.0", name=NAME).replace("File version: 0.1.0", "File version: 0.0.5"))
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-MISMATCH", "File version: says 0.0.5")
        write_repo(self.repo, page=NEXUS_PAGE.format(v="1.0.0"))
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-MISMATCH", "NEXUS_PAGE.md **Version:** says 1.0.0")

    def test_empty_nexus_file(self):
        write_repo(self.repo, fields="")
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-NEXUS-EMPTY", "NEXUS_FIELDS")
        write_repo(self.repo, page="# nothing here\n")
        self.assertEqual(self.verify(), 1)
        self.assertFails("VER-NEXUS-EMPTY", "NEXUS_PAGE")

    def test_tag_mismatch(self):
        self.assertEqual(self.verify(None, "--tag", "v0.1.0"), 0, self.out)
        self.assertEqual(self.verify(None, "--tag", "v0.3.0"), 1)
        self.assertFails("VER-MISMATCH", "--tag v0.3.0 says 0.3.0")

    def test_tag_commit_differs_from_head(self):
        if not shutil.which("git"):
            self.skipTest("git not available")
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        run = lambda *a: subprocess.run(["git", "-C", self.repo] + list(a), check=True, env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run("init", "-q")
        run("add", "-A")
        run("commit", "-q", "-m", "one")
        run("tag", "v0.1.0")
        run("commit", "-q", "--allow-empty", "-m", "two")
        self.assertEqual(self.verify(None, "--tag", "v0.1.0"), 0, self.out)
        self.assertFinding("WARN", "VER-TAG-COMMIT")

    def test_zip_name_mismatch(self):
        self.assertEqual(self.verify(name="%s-0.1.9.zip" % NAME), 1)
        self.assertFails("VER-MISMATCH", "zip file name says 0.1.9")
        self.assertEqual(self.verify(name="release.zip"), 1)
        self.assertFails("VER-ZIPNAME")


# ------------------------------------------------------------------------------------------
# 3. Stray files and FOMOD structure
# ------------------------------------------------------------------------------------------
def add(path, data=b"x"):
    return lambda e: e.__setitem__(path, data)


class StrayChecks(Base):
    def test_git_entry(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/.git/config")), 1)
        self.assertFails("STRAY-VCS")
        self.assertEqual(self.verify(None, mutate=add("00 Core/.gitignore")), 1)
        self.assertFails("STRAY-VCS")

    def test_ds_store(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/.DS_Store")), 1)
        self.assertFails("STRAY-OS")

    def test_temp_and_build_files(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.psc~")), 1)
        self.assertFails("STRAY-TEMP")
        self.assertEqual(self.verify(None, mutate=add("00 Core/obj/x.dat")), 1)
        self.assertFails("STRAY-BUILD")

    def test_secret_file(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/.env")), 1)
        self.assertFails("SECRET-NAME")
        self.assertEqual(self.verify(None, mutate=add("00 Core/id_rsa")), 1)
        self.assertFails("SECRET-NAME")

    def test_secret_content_not_printed(self):
        token = "ghp_" + "Ab3" * 12
        self.assertEqual(self.verify(None, mutate=add("00 Core/notes.txt", ("token = %s\n" % token).encode())), 1)
        self.assertFails("SECRET-CONTENT", "GitHub token")
        self.assertNotIn(token, self.out)
        key = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nAAAA\n"
        self.assertEqual(self.verify(None, mutate=add("00 Core/notes.txt", key.encode())), 1)
        self.assertFails("SECRET-CONTENT", "private key")

    def test_executables(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/install.bat")), 1)
        self.assertFails("STRAY-EXEC")
        self.assertEqual(self.verify(None, mutate=add("00 Core/SKSE/Plugins/thing.dll")), 0)
        self.assertFinding("WARN", "STRAY-EXEC")

    def test_abs_path_leak(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/readme.txt", b"built in /home/alice/mods/x\n")), 1)
        self.assertFails("PATH-LEAK", "/home/alice")
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex",
                                                     pex("WBN_MainScript", ["x", "C:\\Users\\bob\\Desktop\\a.txt"]))), 1)
        self.assertFails("PATH-LEAK", "C:\\Users")
        self.assertEqual(self.verify(None, mutate=add("00 Core/readme.txt", b"see https://example.com/a/b and Data\\Scripts\\x.pex\n")), 0, self.out)

    def test_abs_path_leak_in_plugin_string(self):
        recs = [("GLOB", 0x800, "WBN_A", None, False)]
        data = plugin(recs)
        info = vr.parse_plugin(data)
        self.assertIsNone(info.error)
        leaky = bytearray(plugin([("BOOK", 0x800, "D:\\Work\\Skyrim\\x", None, False)]))
        self.assertEqual(self.verify(None, mutate=with_plugin(bytes(leaky))), 1)
        self.assertFails("PATH-LEAK")

    def test_nested_archive(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as z:
            z.writestr("a.txt", "a")
        self.assertEqual(self.verify(None, mutate=add("00 Core/extra.zip", inner.getvalue())), 1)
        self.assertFails("NESTED-ARCHIVE")
        self.assertEqual(self.verify(None, mutate=add("00 Core/extra.dat", inner.getvalue())), 1)
        self.assertFails("NESTED-ARCHIVE", "zip archive")

    def test_zip_slip_and_backslash(self):
        e = list(good_entries().items()) + [("00 Core/../../evil.txt", b"x")]
        self.assertEqual(self.verify(e), 1)
        self.assertFails("ZIP-PATH", "zip-slip")
        e = list(good_entries().items()) + [("00 Core\\Scripts\\x.txt", b"x")]
        self.assertEqual(self.verify(e), 1)
        self.assertFails("ZIP-PATH", "backslashes")

    def test_duplicate_case_names(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/wbn_mainscript.PEX", pex("wbn_mainscript"))), 1)
        self.assertFails("ZIP-CASE-DUP")

    def test_duplicate_entries(self):
        e = list(good_entries().items()) + [("00 Core/SEQ/%s.seq" % NAME, b"\0\0\0\0")]
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            self.assertEqual(self.verify(e), 1)
        self.assertFails("ZIP-DUP")

    def test_oversize_and_allowlist(self):
        big = add("00 Core/Sound/big.wav", b"\0" * (300 * 1024))
        self.assertEqual(self.verify(None, "--max-file-mb", "0.1", mutate=big), 1)
        self.assertFails("STRAY-LARGE")
        self.assertEqual(self.verify(None, "--max-file-mb", "0.1", "--allow-large", "*/big.wav", mutate=big), 0, self.out)
        self.assertFinding("ALLOWED", "STRAY-LARGE")
        with open(os.path.join(self.repo, ".verify-release.allow"), "w") as f:
            f.write("# waivers\nallow-large 00 Core/Sound/*.wav\n")
        self.assertEqual(self.verify(None, "--max-file-mb", "0.1", mutate=big), 0, self.out)
        self.assertFinding("ALLOWED", "STRAY-LARGE")

    def test_unreferenced_file(self):
        mc = MODULE_CONFIG.format(v=VERSION).replace(
            '<folder source="00 Core" destination="" />',
            '<folder source="00 Core" destination="" />\n    <file source="20 Extras/a.txt" destination="a.txt" />')
        def m(e):
            e["fomod/ModuleConfig.xml"] = mc.encode()
            e["20 Extras/a.txt"] = b"a"
            e["20 Extras/b.txt"] = b"b"
        self.assertEqual(self.verify(None, mutate=m), 1)
        self.assertFails("STRAY-UNREFERENCED", "20 Extras/b.txt")
        self.assertNotIn("20 Extras/a.txt: not installed", self.out)

    def test_missing_referenced_file(self):
        self.assertEqual(self.verify(None, mutate=lambda e: [e.pop(k) for k in list(e) if k.startswith("10 Papyrus")]), 1)
        self.assertFails("FOMOD-MISSING-SOURCE", "10 Papyrus Sources")
        mc = MODULE_CONFIG.format(v=VERSION).replace("<moduleName>", '<moduleImage path="fomod/images/logo.png" /><moduleName>')
        self.assertEqual(self.verify(None, mutate=add("fomod/ModuleConfig.xml", mc.encode())), 1)
        self.assertFails("FOMOD-MISSING-SOURCE", "fomod/images/logo.png")

    def test_unexpected_toplevel(self):
        self.assertEqual(self.verify(None, mutate=add("99 Junk/x.txt")), 1)
        self.assertFails("STRAY-TOPLEVEL", "99 Junk")
        self.assertEqual(self.verify(None, mutate=add("readme.txt")), 1)
        self.assertFails("STRAY-TOPLEVEL", "loose file")

    def test_missing_or_bad_fomod(self):
        self.assertEqual(self.verify(None, mutate=lambda e: e.pop("fomod/ModuleConfig.xml")), 1)
        self.assertFails("FOMOD-MISSING")
        self.assertEqual(self.verify(None, mutate=add("fomod/ModuleConfig.xml", b"<config><moduleName>x")), 1)
        self.assertFails("FOMOD-XML")
        self.assertNotIn("Traceback", self.out + self.err)

    def test_destination_conflict(self):
        mc = MODULE_CONFIG.format(v=VERSION).replace(
            '<folder source="10 Papyrus Sources" destination="" />',
            '<folder source="10 Papyrus Sources" destination="" />\n'
            '                <file source="20 Alt/WBN_MainScript.pex" destination="Scripts/WBN_MainScript.pex" />')
        def m(e):
            e["fomod/ModuleConfig.xml"] = mc.encode()
            e["20 Alt/WBN_MainScript.pex"] = pex("WBN_MainScript")
        self.assertEqual(self.verify(None, mutate=m), 1)
        self.assertFails("FOMOD-DEST-CONFLICT", "Scripts/WBN_MainScript.pex")


# ------------------------------------------------------------------------------------------
# 4. Bethesda assets
# ------------------------------------------------------------------------------------------
class BethesdaChecks(Base):
    def test_vanilla_bsa_name(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Skyrim - Textures0.bsa", b"")), 1)
        self.assertFails("BETH-ARCHIVE")

    def test_creation_club_name(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/ccxyzsse001-thing.esl", b"")), 1)
        self.assertFails("BETH-CC")

    def test_vanilla_master_file(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Skyrim.esm", b"")), 1)
        self.assertFails("BETH-MASTER")

    def test_papyrus_compiler(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Tools/PapyrusCompiler.exe", b"")), 1)
        self.assertFails("BETH-TOOL")

    def test_vanilla_strings_and_voice(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Strings/Skyrim_English.STRINGS", b"")), 1)
        self.assertFails("BETH-STRINGS")
        self.assertEqual(self.verify(None, mutate=add("00 Core/Sound/Voice/Skyrim.esm/MaleNord/x.fuz", b"")), 1)
        self.assertFails("BETH-VOICE")

    def test_vanilla_psc_name(self):
        def m(e):
            e["10 Papyrus Sources/Source/Scripts/Actor.psc"] = b"; placeholder\n"
            e["00 Core/Scripts/Actor.pex"] = pex("Actor")
        self.assertEqual(self.verify(None, mutate=m), 1)
        self.assertFails("BETH-SCRIPT")

    def test_skse_script_is_warn(self):
        def m(e):
            e["10 Papyrus Sources/Source/Scripts/StringUtil.psc"] = b"ScriptName StringUtil Hidden\n"
        self.verify(None, mutate=m)
        self.assertFinding("WARN", "BETH-SKSE-SCRIPT")

    def test_heuristic_mesh_path_is_warn_only(self):
        mesh = add("00 Core/Meshes/Armor/Iron/cuirass.nif", b"\0\0")
        self.assertEqual(self.verify(None, mutate=mesh), 0, self.out)
        self.assertFinding("WARN", "BETH-VANILLA-PATH")
        self.assertIn("RESULT: PASS (1 warn)", self.out)
        self.assertEqual(self.verify(None, "--strict", mutate=mesh), 1)
        self.assertIn("RESULT: FAIL (0 fail, 1 warn)", self.out)
        self.assertEqual(self.verify(None, mutate=add("00 Core/Meshes/WarBanners/banner.nif", b"\0")), 0)

    def test_other_bsa_and_bethesda_comment_warn(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/WarBanners.bsa", b"BSA\0")), 0)
        self.assertFinding("WARN", "BETH-ARCHIVE-OTHER")
        src = psc("WBN_MainScript", body="; Copyright Bethesda Softworks\n")
        self.assertEqual(self.verify(None, mutate=add("10 Papyrus Sources/Source/Scripts/WBN_MainScript.psc", src)), 0)
        self.assertFinding("WARN", "BETH-PSC-HEADER")

    def test_deny_hashes(self):
        import hashlib
        entries = good_entries()
        h = hashlib.sha256(entries["00 Core/SEQ/%s.seq" % NAME]).hexdigest()
        deny = os.path.join(self.tmp, "deny.txt")
        with open(deny, "w") as f:
            f.write("# my own install\n%s\n" % h)
        self.assertEqual(self.verify(entries, "--deny-hashes", deny), 1)
        self.assertFails("BETH-HASH")
        with open(deny, "w") as f:
            f.write("nothex\n")
        self.assertEqual(self.verify(entries, "--deny-hashes", deny), 2)

    def test_help_says_no_hash_list(self):
        self.assertEqual(self.run_vr("--help"), 0)
        self.assertIn("bundles NO hash list", self.out)


# ------------------------------------------------------------------------------------------
# 5. Papyrus
# ------------------------------------------------------------------------------------------
class PapyrusChecks(Base):
    def test_pex_backslash_escape_regression(self):
        # Contract Hunter 0.1.3: a string constant held backslash + n instead of a line feed.
        bad = pex("WBN_MainScript", ["GetState", "Standing with the holds:\\nWhiterun 50"])
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", bad)), 1)
        self.assertFails("PAPYRUS-ESCAPE", "WBN_MainScript.pex")
        ok = pex("WBN_MainScript", ["GetState", "Standing with the holds:\nWhiterun 50"])
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", ok)), 0, self.out)

    def test_psc_escape_skips_comments(self):
        body = 'Function F()\n  Debug.MessageBox("one\\ntwo")\nEndFunction\n'
        self.assertEqual(self.verify(None, mutate=add("10 Papyrus Sources/Source/Scripts/WBN_MainScript.psc", psc("WBN_MainScript", body))), 1)
        self.assertFails("PAPYRUS-ESCAPE", "WBN_MainScript.psc:4:")
        body = '; "a\\n" in a comment\n;/ "b\\n"\n /;\n{ doc "c\\n" }\nFunction F()\nEndFunction\n'
        self.assertEqual(self.verify(None, mutate=add("10 Papyrus Sources/Source/Scripts/WBN_MainScript.psc", psc("WBN_MainScript", body))), 0, self.out)

    def test_pex_without_psc(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_ExtraScript.pex", pex("WBN_ExtraScript"))), 1)
        self.assertFails("PEX-NO-PSC", "WBN_ExtraScript.pex")

    def test_psc_without_pex_and_no_sources(self):
        self.assertEqual(self.verify(None, mutate=add("10 Papyrus Sources/Source/Scripts/WBN_Extra.psc", psc("WBN_Extra"))), 0)
        self.assertFinding("WARN", "PSC-NO-PEX")
        mc = MODULE_CONFIG.format(v=VERSION).replace('<folder source="10 Papyrus Sources" destination="" />', "")
        def m(e):
            for k in list(e):
                if k.startswith("10 Papyrus"):
                    del e[k]
            e["fomod/ModuleConfig.xml"] = mc.encode()
        self.assertEqual(self.verify(None, mutate=m), 0, self.out)
        self.assertFinding("WARN", "PEX-NO-SOURCES")

    def test_bad_pex(self):
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", b"\xde\xc0\x57\xfa garbage")), 1)
        self.assertFails("PEX-PARSE")
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", pex("WBN_MainScript")[:30])), 1)
        self.assertFails("PEX-PARSE")

    def test_pex_header(self):
        p = pex("WBN_MainScript", user="alice", machine="ALICE-PC")
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", p)), 0)
        self.assertFinding("WARN", "PEX-HEADER-USER", "alice")
        p = pex("WBN_MainScript", source="C:\\Mods\\src\\WBN_MainScript.psc")
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", p)), 1)
        self.assertFails("PEX-HEADER-PATH")
        p = pex("WBN_MainScript", source="Other.psc")
        self.assertEqual(self.verify(None, mutate=add("00 Core/Scripts/WBN_MainScript.pex", p)), 0)
        self.assertFinding("WARN", "PEX-SRCNAME")

    def test_scriptname_must_match(self):
        self.assertEqual(self.verify(None, mutate=add("10 Papyrus Sources/Source/Scripts/WBN_MainScript.psc", psc("WBN_Other"))), 1)
        self.assertFails("PSC-SCRIPTNAME")

    def test_sibling_prefix_collision(self):
        def m(e):
            e["00 Core/Scripts/CHT_HunterScript.pex"] = pex("CHT_HunterScript")
            e["10 Papyrus Sources/Source/Scripts/CHT_HunterScript.psc"] = psc("CHT_HunterScript")
        self.assertEqual(self.verify(None, mutate=m), 1)
        self.assertFails("PREFIX-COLLISION", "CHT_HunterScript")
        recs = [("GLOB", 0x800, "WBN_A", None, False), ("GLOB", 0x801, "BSC_Stolen", None, False)]
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(recs))), 1)
        self.assertFails("PREFIX-COLLISION", "BSC_Stolen")

    def test_unprefixed_is_warn(self):
        recs = [("GLOB", 0x800, "WBN_A", None, False), ("GLOB", 0x801, "MyGlobal", None, False)]
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(recs))), 0)
        self.assertFinding("WARN", "EDID-PREFIX", "MyGlobal")

    def test_unknown_plugin_stem(self):
        entries = good_entries(name="NewMod", prefix="NEW_")
        z = write_zip(os.path.join(self.tmp, "NewMod-0.1.0.zip"), entries)
        write_repo(self.repo, name="NewMod")
        self.assertEqual(self.run_vr("--zip", z, "--repo", self.repo), 0, self.out)
        self.assertFinding("WARN", "REGISTRY-UNKNOWN")
        self.assertIn("package prefix NEW_", self.out)

    def test_others_collision(self):
        other = write_zip(os.path.join(self.tmp, "Roadwarden-0.1.0.zip"), good_entries(name="Roadwarden", prefix="WBN_"))
        self.assertEqual(self.verify(None, "--others", other), 1)
        self.assertFails("COLLISION-SCRIPT")
        clean = write_zip(os.path.join(self.tmp, "Roadwarden-0.1.0.zip"), good_entries(name="Roadwarden", prefix="RWD_"))
        self.assertEqual(self.verify(None, "--others", clean), 0, self.out)


# ------------------------------------------------------------------------------------------
# 6. Masters
# ------------------------------------------------------------------------------------------
class MasterChecks(Base):
    def test_unknown_master(self):
        p = plugin(masters=("Skyrim.esm", "Unknown.esp"))
        self.assertEqual(self.verify(None, mutate=with_plugin(p)), 1)
        self.assertFails("MASTER-UNDECLARED", "Unknown.esp")
        self.assertEqual(self.verify(None, "--allow-master", "Unknown.esp", mutate=with_plugin(p)), 0, self.out)
        self.assertFinding("ALLOWED", "MASTER-UNDECLARED")
        with open(os.path.join(self.repo, ".verify-release.allow"), "w") as f:
            f.write("allow-master unknown.esp  # vendored\n")
        self.assertEqual(self.verify(None, mutate=with_plugin(p)), 0, self.out)

    def test_master_declared_in_docs(self):
        readme = README.format(v=VERSION, name=NAME).replace("Skyrim.esm is the only master.", "Masters: Skyrim.esm, OtherMod.esp.")
        write_repo(self.repo, readme=readme)
        self.assertEqual(self.verify(None, mutate=with_plugin(plugin(masters=("Skyrim.esm", "OtherMod.esp")))), 0, self.out)

    def test_dlc_master_vs_claim(self):
        p = plugin(masters=("Skyrim.esm", "Dawnguard.esm"))
        self.assertEqual(self.verify(None, mutate=with_plugin(p)), 1)
        self.assertFails("MASTER-DLC-CLAIM", "Dawnguard.esm")

    def test_self_master(self):
        p = plugin(masters=("Skyrim.esm", "%s.esp" % NAME))
        self.assertEqual(self.verify(None, mutate=with_plugin(p)), 1)
        self.assertFails("MASTER-SELF")


# ------------------------------------------------------------------------------------------
# Collision mode
# ------------------------------------------------------------------------------------------
class CollisionMode(Base):
    def test_duplicates(self):
        a = write_zip(os.path.join(self.tmp, "WarBanners-0.1.0.zip"), good_entries())
        b_entries = good_entries(name="Roadwarden", prefix="RWD_")
        b_entries["00 Core/Scripts/WBN_MainScript.pex"] = pex("WBN_MainScript")
        b_entries["00 Core/Roadwarden.esp"] = plugin([("GLOB", 0x800, "RWD_A", None, False),
                                                      ("GLOB", 0x801, "WBN_Enabled", None, False)])
        b = write_zip(os.path.join(self.tmp, "Roadwarden-0.1.0.zip"), b_entries)
        js = os.path.join(self.tmp, "c.json")
        self.assertEqual(self.run_vr("--collisions", a, b, "--json", js), 1)
        self.assertIn("[FAIL] COLLISION-SCRIPT WBN_MainScript", self.out)
        self.assertIn("[FAIL] COLLISION-EDID WBN_Enabled", self.out)
        self.assertIn("RESULT: FAIL", self.out)
        rep = json.loads(slurp(js))
        self.assertEqual({d["kind"] for d in rep["duplicates"]}, {"script", "edid"})

    def test_clean_pair_and_directory_of_zips(self):
        d = os.path.join(self.tmp, "all")
        os.makedirs(d)
        write_zip(os.path.join(d, "WarBanners-0.1.0.zip"), good_entries())
        write_zip(os.path.join(d, "Roadwarden-0.1.0.zip"), good_entries(name="Roadwarden", prefix="RWD_"))
        self.assertEqual(self.run_vr("--collisions", d), 0, self.out)
        self.assertIn("RESULT: PASS", self.out)
        self.assertIn("2 plugin", self.out)

    def test_voice_types_under_different_plugins_do_not_collide(self):
        a_e = good_entries()
        a_e["00 Core/Sound/Voice/WarBanners.esp/MaleNord/a.wav"] = b"RIFF"
        b_e = good_entries(name="Roadwarden", prefix="RWD_")
        b_e["00 Core/Sound/Voice/Roadwarden.esp/MaleNord/b.wav"] = b"RIFF"
        a = write_zip(os.path.join(self.tmp, "a.zip"), a_e)
        b = write_zip(os.path.join(self.tmp, "b.zip"), b_e)
        self.assertEqual(self.run_vr("--collisions", a, b), 0, self.out)


# ------------------------------------------------------------------------------------------
# Bad input and invocation
# ------------------------------------------------------------------------------------------
class Invocation(Base):
    def test_bad_zip_exit_2_no_traceback(self):
        bad = os.path.join(self.tmp, "%s-%s.zip" % (NAME, VERSION))
        with open(bad, "wb") as f:
            f.write(b"this is not a zip")
        self.assertEqual(self.run_vr("--zip", bad, "--repo", self.repo), 2)
        self.assertIn("cannot read zip", self.err)
        r = subprocess.run(["bash", SCRIPT, "--zip", bad, "--repo", self.repo], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(r.returncode, 2)
        self.assertNotIn(b"Traceback", r.stdout + r.stderr)

    def test_missing_args_and_paths(self):
        self.assertEqual(self.run_vr(), 2)
        self.assertEqual(self.run_vr("--zip", os.path.join(self.tmp, "nope.zip")), 2)
        self.assertEqual(self.run_vr("--bogus"), 2)

    def test_polyglot_version(self):
        r = subprocess.run(["bash", SCRIPT, "--version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout.decode(), r"^verify-release \d+\.\d+\.\d+")

    def test_subprocess_good_fixture_format(self):
        z = self.zip()
        r = subprocess.run(["bash", SCRIPT, "--zip", z, "--repo", self.repo], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=dict(os.environ, GITHUB_ACTIONS=""))
        out = r.stdout.decode()
        self.assertEqual(r.returncode, 0, out + r.stderr.decode())
        lines = out.splitlines()
        self.assertEqual(lines[-1], "RESULT: PASS")
        for l in lines:
            if l.startswith("["):
                self.assertRegex(l, r"^\[(FAIL|WARN| ok |info|ALLOWED)\] [A-Z0-9-]+( |:)")
        headings = [l for l in lines if l.startswith("== ")]
        self.assertEqual([h.split(".")[0] for h in headings], ["== %d" % i for i in range(1, 7)])

    def test_subprocess_failing_fixture(self):
        z = self.zip(mutate=with_plugin(plugin(flags=0)))
        r = subprocess.run([SCRIPT, "--zip", z, "--repo", self.repo], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(r.returncode, 1)
        self.assertRegex(r.stdout.decode(), r"\[FAIL\] ESL-FLAG 00 Core/WarBanners\.esp: ")
        self.assertRegex(r.stdout.decode(), r"RESULT: FAIL \(\d+ fail, \d+ warn\)")


if __name__ == "__main__":
    unittest.main()
