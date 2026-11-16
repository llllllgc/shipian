#!/usr/bin/env python3
"""Build the bundled converter without Homebrew or downloaded binaries."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
vendor = root / 'native/vendor/LibRaw-0.22.2'
build = root / 'build/raw_converter'
build.mkdir(parents=True, exist_ok=True)
sources = sorted(p for p in (vendor / 'src').rglob('*.cpp')
                 if not p.stem.endswith('_ph')) + [root / 'native/raw_converter.cpp']
arches = sys.argv[1:] or ['arm64', 'x86_64']
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()

def compile_one(args):
    source, arch = args
    obj = build / arch / source.relative_to(root).with_suffix('.o')
    obj.parent.mkdir(parents=True, exist_ok=True)
    if not obj.exists() or obj.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', '-w',
                        '-arch', arch, '-isysroot', sdk, '-mmacosx-version-min=10.15',
                        '-DLIBRAW_NODLL', '-DLIBRAW_NOTHREADS', '-DUSE_ZLIB',
                        '-I', str(vendor), '-c', str(source), '-o', str(obj)], check=True)
    return str(obj)

outputs = []
for arch in arches:
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(os.cpu_count() or 4, 8)) as pool:
        objects = list(pool.map(compile_one, [(source, arch) for source in sources]))
    output = build / ('shipian_raw_converter_' + arch)
    subprocess.run(['xcrun', 'clang++', '-arch', arch, '-mmacosx-version-min=10.15',
                    *objects, '-lz', '-framework', 'CoreGraphics', '-framework', 'ImageIO',
                    '-framework', 'CoreFoundation', '-o', str(output)], check=True)
    outputs.append(str(output))
subprocess.run(['xcrun', 'lipo', '-create', *outputs, '-output', str(build / 'shipian_raw_converter')], check=True)
print(build / 'shipian_raw_converter')
