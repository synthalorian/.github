"""Generated regression fixtures for the first independent review."""
from test_verify_release import (Base, vr, good_entries, plugin, grup, sub, zstr,
                                 write_zip, VERSION, pex)
import os
import struct
import zipfile
import zlib
from unittest import mock


class ReviewRegressions(Base):
    def test_entry_and_total_caps_never_open_blocked_members(self):
        def forbidden():
            self.fail('blocked entry was opened')
        for sizes in ([129 * vr.MB], [128 * vr.MB] * 3):
            entries = [vr.Entry('00 Core/%d.bin' % i, n, forbidden) for i, n in enumerate(sizes)]
            pkg = vr.Package(self.tmp, 'dir', entries).apply_limits()
            self.assertTrue(entries[-1].blocked)
            self.assertEqual(entries[-1].data(), b'')
            self.assertEqual(list(entries[-1].chunks()), [])
            self.assertEqual(list(entries[-1].chunks(force=True)), [])
            ctx = mock.Mock(pkg=vr.Package(self.tmp, "dir", [e for e in entries if e.blocked]), report=vr.Report(), deny_hashes={'0' * 64})
            vr.check_bethesda(ctx)
            self.assertTrue(any(f.code == 'BETH-HASH-SKIPPED' for f in ctx.report.findings))

    def test_generated_zip_compression_bomb(self):
        e = good_entries()
        e['00 Core/bomb.txt'] = b'A' * (17 * vr.MB)
        self.assertEqual(self.verify(e, '--allow-large', '*'), 1)
        self.assertFails('ZIP-BOMB')

    def test_bounded_record_inflate_declared_and_actual_overflow(self):
        for want, content in ((vr.MAX_RECORD_INFLATE + 1, b'x'), (8, b'x' * 100000)):
            payload = struct.pack('<I', want) + zlib.compress(content)
            rec = b'GLOB' + struct.pack('<III', len(payload), 0x40000, 0x01000800) + b'\0' * 8 + payload
            info = vr.parse_plugin(plugin(records=[], raw_extra=rec))
            self.assertIsNotNone(info.error)
            self.assertIn('compressed record', info.error)

    def test_malformed_collision_and_others_fail(self):
        e = good_entries(name='Roadwarden', prefix='RWD_')
        e['00 Core/Roadwarden.esp'] = b'TES4'
        other = self.zip(e, name='other.zip')
        self.assertEqual(self.run_vr('--collisions', other), 1)
        self.assertFails('COLLISION-INPUT')
        self.assertEqual(self.verify(None, '--others', other), 1)
        self.assertFails('COLLISION-INPUT')

    def test_deep_groups_fail_without_recursion(self):
        body = b''
        for _ in range(1100):
            body = grup('GLOB', body)
        e = good_entries()
        e['00 Core/WarBanners.esp'] = plugin(records=[], raw_extra=body)
        z = self.zip(e)
        self.assertEqual(self.run_vr('--collisions', z), 1)
        self.assertFails('COLLISION-INPUT')
        self.assertNotIn('Traceback', self.out + self.err)

    def test_unexpected_main_exception_is_exit_two(self):
        with mock.patch.object(vr, 'run', side_effect=RuntimeError('generated failure')):
            self.assertEqual(self.run_vr('--collisions', self.tmp), 2)
        self.assertIn('FAIL', self.out)
        self.assertNotIn('Traceback', self.err)

    def test_matching_basenames_remain_distinct_packages(self):
        paths = []
        for folder in ('a', 'b'):
            os.makedirs(os.path.join(self.tmp, folder))
            paths.append(write_zip(os.path.join(self.tmp, folder, 'release.zip'), good_entries()))
        self.assertEqual(self.run_vr('--collisions', *paths), 1)
        self.assertFails('COLLISION-SCRIPT')
        self.assertIn('release.zip (a)', self.out)
        self.assertIn('release.zip (b)', self.out)
        self.assertEqual(self.run_vr('--collisions', paths[0], paths[0]), 0)

    def test_conditional_patterns_and_same_option_conflict(self):
        for wrap in ('<conditionalFileInstalls><patterns>{}</patterns></conditionalFileInstalls>',
                     '<group type="SelectExactlyOne"><plugins><plugin><files>{}</files></plugin></plugins></group>'):
            files = ['<file source="00 Core/%s.txt" destination="same.txt" />' % x for x in ('a', 'b')]
            if 'patterns' in wrap:
                files = ['<pattern><dependencies operator="And"/><files>%s</files></pattern>' % f for f in files]
            e = good_entries()
            e.update({'00 Core/a.txt': b'a', '00 Core/b.txt': b'b'})
            e['fomod/ModuleConfig.xml'] = e['fomod/ModuleConfig.xml'].replace(b'</config>', (wrap.format(''.join(files)) + '</config>').encode())
            self.assertEqual(self.verify(e), 1)
            self.assertFails('FOMOD-DEST-CONFLICT')

    def test_large_waiver_keeps_stream_scans_and_crc(self):
        # Lower the scan threshold to exercise exactly the same streaming path with tiny fixtures.
        e = good_entries()
        e['00 Core/large.txt'] = b'PK\x03\x04 /tmp/private\n' + b'x' * 4096 + b' ghp_' + b'A' * 40
        with mock.patch.object(vr, 'CONTENT_SCAN_LIMIT', 2048):
            self.assertEqual(self.verify(e, '--max-file-mb', '.001', '--allow-large', '*.txt'), 1)
        for code in ('NESTED-ARCHIVE', 'PATH-LEAK', 'SECRET-CONTENT'):
            self.assertFails(code)
        self.assertFinding('ALLOWED', 'STRAY-LARGE')
        path = os.path.join(self.tmp, 'crc.zip')
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_STORED) as z:
            for name, data in e.items():
                z.writestr(name, data)
        with zipfile.ZipFile(path) as z:
            info = z.getinfo('00 Core/large.txt')
            offset = info.header_offset + 30 + len(info.filename.encode()) + len(info.extra)
        with open(path, 'r+b') as f:
            f.seek(offset + 3000)
            f.write(b'!')
        with mock.patch.object(vr, 'CONTENT_SCAN_LIMIT', 2048):
            self.assertEqual(self.run_vr('--zip', path, '--repo', self.repo, '--allow-large', '*'), 1)
        self.assertFails('ZIP-CORRUPT')

    def test_actual_65_mib_waived_file_is_streamed(self):
        path = self.zip()
        with zipfile.ZipFile(path, 'a', zipfile.ZIP_STORED) as z:
            with z.open('00 Core/large.txt', 'w') as f:
                f.write(b'PK\x03\x04 /tmp/private\n')
                for _ in range(65):
                    f.write(b'x' * vr.MB)
        self.assertEqual(self.run_vr('--zip', path, '--repo', self.repo,
                                     '--allow-large', '*.txt'), 1)
        self.assertFinding('ALLOWED', 'STRAY-LARGE')
        self.assertFails('NESTED-ARCHIVE')
        self.assertFails('PATH-LEAK')
        self.assertNoFinding('ZIP-BOMB')

    def test_resource_caps_cannot_be_disabled(self):
        for option, value in (('--max-entry-mb', '129'), ('--max-total-mb', '257'),
                              ('--max-entry-mb', 'nan'), ('--max-total-mb', 'inf')):
            self.assertEqual(self.run_vr('--collisions', self.tmp, option, value), 2)

    def test_raw_directory_names_are_validated(self):
        for name, code in (('../escape/', 'ZIP-PATH'), ('/absolute/', 'ZIP-PATH'),
                           ('00 Core\\bad\\', 'ZIP-PATH'), ('.git/', 'STRAY-VCS'),
                           ('unexpected/', 'STRAY-TOPLEVEL')):
            e = good_entries()
            e[name] = b''
            self.assertEqual(self.verify(e), 1)
            self.assertFails(code)

    def test_xml_comments_namespaces_and_conflicts(self):
        for tag, path, missing in (('Version', 'fomod/info.xml', 'VER-INFO-MISSING'),
                                   ('moduleName', 'fomod/ModuleConfig.xml', 'VER-MODULENAME')):
            e = good_entries()
            value = VERSION if tag == 'Version' else 'War Banners ' + VERSION
            e[path] = ('<root><!-- <%s>%s</%s> --></root>' % (tag, value, tag)).encode()
            self.assertEqual(self.verify(e), 1)
            self.assertFails(missing)
            e[path] = ('<root xmlns:n="urn:test"><n:%s>%s</n:%s></root>' % (tag, value, tag)).encode()
            self.verify(e)
            self.assertNoFinding(missing)
            self.assertNoFinding('VER-MISMATCH')
            e[path] = ('<root><%s>%s</%s><%s>9.9.9</%s></root>' % (tag, value, tag, tag, tag)).encode()
            self.verify(e)
            self.assertFails('VER-XML-CONFLICT')

    def test_dangling_and_consecutive_xxxx(self):
        marker = b'XXXX' + struct.pack('<HI', 4, 4)
        for payload in (marker, marker + marker):
            with self.assertRaises(vr.PluginError):
                list(vr.iter_subrecords(payload, 'generated'))

    def test_header_author_and_description_path_leaks(self):
        for tag in ('CNAM', 'SNAM'):
            buf = plugin()
            size = struct.unpack_from('<I', buf, 4)[0]
            extra = sub(tag, zstr('/tmp/private'))
            buf = buf[:4] + struct.pack('<I', size + len(extra)) + buf[8:24 + size] + extra + buf[24 + size:]
            e = good_entries()
            e['00 Core/WarBanners.esp'] = buf
            self.assertEqual(self.verify(e), 1)
            self.assertFails('PATH-LEAK')

    def test_edid_global_namespace_reports_types(self):
        paths = []
        for i, typ in enumerate(('GLOB', 'QUST')):
            e = good_entries(name=('WarBanners', 'Roadwarden')[i], prefix=('WBN_', 'RWD_')[i])
            e['00 Core/%s.esp' % ('WarBanners', 'Roadwarden')[i]] = plugin(records=[(typ, 0x800, 'SharedName', None, False)])
            paths.append(self.zip(e, name='%d.zip' % i))
        self.assertEqual(self.run_vr('--collisions', *paths), 1)
        self.assertFails('COLLISION-EDID')
        self.assertIn('[GLOB]', self.out)
        self.assertIn('[QUST]', self.out)

    def test_exclusive_options_install_flags_and_defaults(self):
        for kind in ('file', 'folder'):
            for flags in ('', 'alwaysInstall="true"', 'installIfUsable="true"',
                          'alwaysInstall="false" installIfUsable="false"'):
                for descriptor in ('', '<typeDescriptor><dependencyType><defaultType name="Required"/></dependencyType></typeDescriptor>'):
                    with self.subTest(kind=kind, flags=flags, descriptor=descriptor):
                        e = good_entries()
                        options = []
                        for name in ('a', 'b'):
                            source = '00 Core/%s' % name
                            e[source + '/same.txt' if kind == 'folder' else source] = b'fixture'
                            options.append('<plugin name="%s"><files><%s source="%s" destination="Scripts/same.txt" %s/></files>%s</plugin>' % (name, kind, source, flags, descriptor))
                        xml = '<group type="SelectExactlyOne"><plugins>%s</plugins></group>' % ''.join(options)
                        e['fomod/ModuleConfig.xml'] = e['fomod/ModuleConfig.xml'].replace(b'</config>', (xml + '</config>').encode())
                        self.verify(e)
                        if flags in ('alwaysInstall="true"', 'installIfUsable="true"'):
                            self.assertFails('FOMOD-DEST-CONFLICT')
                        else:
                            self.assertNoFinding('FOMOD-DEST-CONFLICT')

    def test_destination_aliases_and_invalid_paths(self):
        for kind in ('file', 'folder'):
            for destination in ('Scripts/./same.txt', 'Scripts/sub/../same.txt',
                                'SCRIPTS//same.txt', 'Scripts\\.\\same.txt',
                                '../outside', '/absolute', 'C:\\absolute', 'Scripts/../../outside'):
                with self.subTest(kind=kind, destination=destination):
                    e = good_entries()
                    files = []
                    for name, dest in (('a', destination), ('b', 'Scripts/same.txt')):
                        source = '00 Core/' + name
                        e[source + '/leaf.txt' if kind == 'folder' else source] = b'fixture'
                        files.append('<%s source="%s" destination="%s"/>' % (kind, source, dest))
                    e['fomod/ModuleConfig.xml'] = e['fomod/ModuleConfig.xml'].replace(b'</config>', ('<requiredInstallFiles>' + ''.join(files) + '</requiredInstallFiles></config>').encode())
                    self.assertEqual(self.verify(e), 1)
                    self.assertFails('FOMOD-DEST-PATH' if destination in ('../outside', '/absolute', 'C:\\absolute', 'Scripts/../../outside') else 'FOMOD-DEST-CONFLICT')

    def test_encoded_xml_secret_and_path_scans(self):
        for encoding in ('utf-8', 'utf-8-sig', 'utf-16', 'utf-16-le', 'utf-16-be',
                         'utf-32', 'utf-32-le', 'utf-32-be', 'iso-8859-1'):
            for streamed in (False, True):
                with self.subTest(encoding=encoding, streamed=streamed):
                    e = good_entries()
                    text = '<?xml version="1.0" encoding="%s"?><fixture>%s ghp_%s /workspace/private</fixture>' % (encoding, 'x' * 8300, 'A' * 40)
                    e['00 Core/encoded.xml'] = text.encode(encoding)
                    with mock.patch.object(vr, 'CONTENT_SCAN_LIMIT', 128 if streamed else 64 * vr.MB), mock.patch.object(vr, 'STREAM_CHUNK', 17):
                        self.assertEqual(self.verify(e), 1)
                    self.assertFails('SECRET-CONTENT')
                    self.assertFails('PATH-LEAK')

    def test_compressed_record_trailing_bytes(self):
        content = sub('EDID', zstr('WBN_Test'))
        payload = struct.pack('<I', len(content)) + zlib.compress(content) + b'trailing'
        rec = b'GLOB' + struct.pack('<III', len(payload), 0x40000, 0x01000800) + b'\0' * 8 + payload
        e = good_entries()
        e['00 Core/WarBanners.esp'] = plugin(records=[], raw_extra=rec)
        self.assertEqual(self.verify(e), 1)
        self.assertFails('PLUGIN-STRUCT', 'trailing bytes')

    def test_bomless_utf16_root_scans(self):
        for encoding in ('utf-16-le', 'utf-16-be'):
            for whitespace in ('', ' \t\r\n'):
                for streamed in (False, True):
                    with self.subTest(encoding=encoding, whitespace=whitespace, streamed=streamed):
                        e = good_entries()
                        text = whitespace + '<fomod><Version>' + VERSION + '</Version><Description>' + 'x' * 8300 + ' /tmp/private ghp_' + 'A' * 40 + '</Description></fomod>'
                        e['00 Core/encoded.xml' if streamed else 'fomod/info.xml'] = text.encode(encoding)
                        with mock.patch.object(vr, 'CONTENT_SCAN_LIMIT', 8192 if streamed else 64 * vr.MB), mock.patch.object(vr, 'STREAM_CHUNK', 17):
                            self.assertEqual(self.verify(e), 1)
                        self.assertFails('PATH-LEAK')
                        self.assertFails('SECRET-CONTENT')
                        self.assertNoFinding('VER-INFO-MISSING')

    def test_install_boolean_whitespace(self):
        for kind in ('file', 'folder'):
            for flag in ('alwaysInstall', 'installIfUsable'):
                for value in (' true ', ' 1 ', '&#x9;TrUe&#xA;', '&#xD;1&#x9;'):
                    with self.subTest(kind=kind, flag=flag, value=value):
                        e = good_entries()
                        options = []
                        for name in ('a', 'b'):
                            source = '00 Core/' + name
                            e[source + '/leaf.txt' if kind == 'folder' else source] = b'fixture'
                            options.append('<plugin><files><%s source="%s" destination="same.txt" %s="%s"/></files></plugin>' % (kind, source, flag, value))
                        xml = '<group type="SelectExactlyOne"><plugins>' + ''.join(options) + '</plugins></group>'
                        e['fomod/ModuleConfig.xml'] = e['fomod/ModuleConfig.xml'].replace(b'</config>', (xml + '</config>').encode())
                        self.assertEqual(self.verify(e), 1)
                        self.assertFails('FOMOD-DEST-CONFLICT')

    def test_windows_trailing_destination_aliases(self):
        for kind in ('file', 'folder'):
            for destination in ('Scripts/same.txt.', 'Scripts/same.txt ', 'SCRIPTS. /same.txt', 'Scripts/same.txt. . '):
                with self.subTest(kind=kind, destination=destination):
                    e = good_entries()
                    files = []
                    for name, dest in (('a', destination), ('b', 'Scripts/same.txt')):
                        source = '00 Core/' + name
                        e[source + '/leaf.txt' if kind == 'folder' else source] = b'fixture'
                        files.append('<%s source="%s" destination="%s"/>' % (kind, source, dest))
                    e['fomod/ModuleConfig.xml'] = e['fomod/ModuleConfig.xml'].replace(b'</config>', ('<requiredInstallFiles>' + ''.join(files) + '</requiredInstallFiles></config>').encode())
                    self.assertEqual(self.verify(e), 1)
                    self.assertFails('FOMOD-DEST-CONFLICT')

    def test_drive_root_path_strings(self):
        for path in ('C:\\private.txt', 'C:/private.txt'):
            for kind in ('text', 'plugin', 'pex'):
                with self.subTest(path=path, kind=kind):
                    e = good_entries()
                    if kind == 'text':
                        e['00 Core/readme.txt'] = ('built in ' + path).encode()
                    elif kind == 'plugin':
                        e['00 Core/WarBanners.esp'] = plugin([('BOOK', 0x800, path, None, False)])
                    else:
                        e['00 Core/Scripts/WBN_MainScript.pex'] = pex('WBN_MainScript', [path])
                    self.assertEqual(self.verify(e), 1)
                    self.assertFails('PATH-LEAK')
        e = good_entries()
        e['00 Core/readme.txt'] = b'https://example.com/a/b Data/Scripts/a.pex topic:/word abcC:/word'
        self.assertEqual(self.verify(e), 0, self.out)
