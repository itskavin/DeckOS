"""Inspect a built AAB without installing or uploading it (Python stdlib only).

Run bundletool validate/dump separately and pass the dumped manifest/config.
Pass the Android NDK llvm-readelf executable to record independent ELF evidence.
"""
import argparse
import hashlib
import json
import re
import struct
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ANDROID = '{http://schemas.android.com/apk/res/android}'


def load_segments(data):
    if data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Expected little-endian ELF')
    is64 = data[4] == 2
    offset = struct.unpack_from('<Q' if is64 else '<I', data, 32 if is64 else 28)[0]
    entry_size, count = struct.unpack_from('<HH', data, 54 if is64 else 42)
    segments = []
    for i in range(count):
        start = offset + i * entry_size
        if struct.unpack_from('<I', data, start)[0] != 1:
            continue
        if is64:
            file_offset, address = struct.unpack_from('<QQ', data, start + 8)
            alignment = struct.unpack_from('<Q', data, start + 48)[0]
        else:
            file_offset, address = struct.unpack_from('<II', data, start + 4)
            alignment = struct.unpack_from('<I', data, start + 28)[0]
        segments.append(dict(offset=file_offset, virtualAddress=address, alignment=alignment))
    return is64, segments


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--readelf', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = ET.parse(args.manifest).getroot()
    app = manifest.find('application')
    sdk = manifest.find('uses-sdk')
    assert manifest.attrib['package'] == 'io.github.itskavin.deckos'
    assert int(sdk.attrib[ANDROID + 'targetSdkVersion']) >= 36
    assert app.attrib.get(ANDROID + 'debuggable', 'false') == 'false'
    assert app.attrib[ANDROID + 'allowBackup'] == 'false'
    assert app.attrib.get(ANDROID + 'usesCleartextTraffic') == 'false', 'Remote release cleartext must be denied'
    config = json.loads(args.config.read_text(encoding='utf-8-sig'))
    assert config['optimizations']['uncompressNativeLibraries']['alignment'] == 'PAGE_ALIGNMENT_16K'

    native = []
    readelf = []
    with zipfile.ZipFile(args.bundle) as archive:
        names = archive.namelist()
        forbidden = re.compile(r'(?:\.(?:jks|keystore|p12|pfx)|/key\.properties|/\.env|/auth\.json|/ai-limits(?:-secrets)?\.json|\.private\.(?:xml|png))$', re.I)
        leaked_files = [name for name in names if forbidden.search(name)]
        assert not leaked_files, 'Private configuration filename present in bundle'
        assert not any('/test/' in name or '/test_assets/' in name for name in names)
        for name in names:
            if name.endswith(('.json', '.txt', '.xml', '.properties', '.pem')):
                data = archive.read(name)
                assert not re.search(rb'-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----|sk-[A-Za-z0-9]{32,}', data), 'Possible secret in packaged text: ' + name
            if not name.startswith('base/lib/') or not name.endswith('.so'):
                continue
            data = archive.read(name)
            is64, segments = load_segments(data)
            compatible = bool(segments) and all(s['alignment'] >= 16384 and
                         s['offset'] % 16384 == s['virtualAddress'] % 16384 for s in segments)
            if is64:
                assert compatible, '64-bit ELF not 16KB compatible: ' + name
            destination = args.output / 'native' / Path(name).relative_to('base/lib')
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            result = subprocess.run([str(args.readelf), '-lW', str(destination)], check=True,
                                    capture_output=True, text=True)
            readelf.append(name + '\n' + result.stdout)
            native.append(dict(file=name, is64Bit=is64, loadSegments=segments,
                               supports16KBAlignment=compatible,
                               sha256=hashlib.sha256(data).hexdigest()))
        assert {'arm64-v8a', 'x86_64'} <= {n['file'].split('/')[2] for n in native}
        assert 'base/assets/flutter_assets/NOTICES.Z' in names
        report = dict(packageName=manifest.attrib['package'],
                      versionName=manifest.attrib[ANDROID + 'versionName'],
                      versionCode=int(manifest.attrib[ANDROID + 'versionCode']),
                      minSdk=int(sdk.attrib[ANDROID + 'minSdkVersion']),
                      targetSdk=int(sdk.attrib[ANDROID + 'targetSdkVersion']),
                      debuggable=False, allowBackup=False,
                      cleartextTraffic=app.attrib.get(ANDROID + 'usesCleartextTraffic'),
                      bundleAlignment='PAGE_ALIGNMENT_16K',
                      permissions=[p.attrib[ANDROID + 'name'] for p in manifest.findall('uses-permission')],
                      nativeLibraries=native,
                      packagedFlutterAssets=[n for n in names if n.startswith('base/assets/flutter_assets/')],
                      privateFilenameAndTextChecks='pass (heuristic, not an exhaustive security audit)',
                      manifestAndSdkChecks='pass',
                      libraryAlignmentChecks='pass',
                      runtime16KBTested=False,
                      nativeDebugMetadataFiles=[n for n in names if n.startswith('BUNDLE-METADATA/')],
                      bundleSha256=hashlib.sha256(args.bundle.read_bytes()).hexdigest())
        (args.output / 'bundle-inspection.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        (args.output / 'llvm-readelf.txt').write_text('\n'.join(readelf), encoding='utf-8')
    print(f'PASS: SDK {report["targetSdk"]}; {len(native)} native libraries, '
          f'{sum(n["is64Bit"] for n in native)} 64-bit libraries aligned for 16KB; '
          'manifest and packaged-text checks passed. Runtime testing remains separate.')


if __name__ == '__main__':
    main()
