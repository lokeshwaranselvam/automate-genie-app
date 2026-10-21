"""Repackage the published 1.28.0 AAR with the three validated runtime libraries.

Keep Java classes, JNI bindings, manifest and notices unchanged. This is an
offline build tool, not code included in the Flutter app.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
VERSION = "1.28.0-sface1"
GROUP = "in.homegenie.onnxruntime"
ARTIFACT = "onnxruntime-android"
UPSTREAM_SHA256 = "f351a0638696f54b35184290dbc001d66daae17281ad0b548d2c70347d53b8a9"


def package(upstream, builds, repository):
    if hashlib.sha256(upstream.read_bytes()).hexdigest() != UPSTREAM_SHA256:
        raise ValueError("Expected the verified published ONNX Runtime Android 1.28.0 AAR.")
    replacements = {}
    for abi in ABIS:
        path = builds / abi / "Release" / "libonnxruntime.so"
        data = path.read_bytes()
        if not data.startswith(b"\x7fELF"):
            raise ValueError("Not a native ELF library: " + str(path))
        expected_machine = {"arm64-v8a": 183, "armeabi-v7a": 40, "x86_64": 62}[abi]
        if data[5] != 1 or struct.unpack_from("<H", data, 18)[0] != expected_machine:
            raise ValueError("Native library architecture does not match " + abi)
        elf64 = data[4] == 2
        phoff = struct.unpack_from("<Q" if elf64 else "<I", data, 32 if elf64 else 28)[0]
        phentsize, phnum = struct.unpack_from("<HH", data, 54 if elf64 else 42)
        for index in range(phnum):
            offset = phoff + index * phentsize
            if struct.unpack_from("<I", data, offset)[0] == 1:
                alignment = struct.unpack_from("<Q" if elf64 else "<I", data,
                                               offset + (48 if elf64 else 28))[0]
                if alignment < 16384:
                    raise ValueError("Runtime LOAD segments must support 16 KiB pages: " + abi)
        if b"OrtSessionOptionsAppendExecutionProvider_Nnapi\x00" not in data:
            raise ValueError("The published Java/JNI bridge requires the NNAPI entry point: " + abi)
        replacements[f"jni/{abi}/libonnxruntime.so"] = data
    output = repository / Path(*GROUP.split(".")) / ARTIFACT / VERSION
    output.mkdir(parents=True, exist_ok=True)
    aar = output / f"{ARTIFACT}-{VERSION}.aar"
    with zipfile.ZipFile(upstream) as original, zipfile.ZipFile(
        aar, "w", compression=zipfile.ZIP_DEFLATED
    ) as target:
        expected = set(replacements)
        if not expected.issubset(original.namelist()):
            raise ValueError("The upstream AAR is missing expected runtime entries.")
        for entry in original.infolist():
            data = replacements.get(entry.filename)
            if data is None:
                data = original.read(entry)
            # The Flutter app supports these three ABIs. x86 is not a Flutter
            # release target; don't publish an incomplete runtime for it.
            if entry.filename.startswith("jni/x86/"):
                continue
            target.writestr(entry.filename, data)
    with zipfile.ZipFile(upstream) as original, zipfile.ZipFile(aar) as target:
        for name in target.namelist():
            if name not in replacements:
                if target.read(name) != original.read(name):
                    raise ValueError("Non-runtime contents changed: " + name)
    pom = output / f"{ARTIFACT}-{VERSION}.pom"
    pom.write_text(
        '<project xmlns="http://maven.apache.org/POM/4.0.0">\n'
        '  <modelVersion>4.0.0</modelVersion>\n'
        f'  <groupId>{GROUP}</groupId><artifactId>{ARTIFACT}</artifactId>\n'
        f'  <version>{VERSION}</version><packaging>aar</packaging>\n'
        '  <name>Genie SFace reduced ONNX Runtime 1.28.0</name>\n'
        '</project>\n', encoding="utf-8"
    )
    manifest = {
        "source": "https://github.com/microsoft/onnxruntime/tree/v1.28.0",
        "coordinates": f"{GROUP}:{ARTIFACT}:{VERSION}",
        "upstream_aar_sha256": UPSTREAM_SHA256,
        "aar_sha256": hashlib.sha256(aar.read_bytes()).hexdigest(),
        "model_sha256": "487a139eb85ccd5ff30aef7d0add7f12d2bb7abb90c5f08a7f481b452a660e00",
        "operators_config_sha256": hashlib.sha256(
            Path(__file__).with_name("sface-required-operators.config").read_bytes()).hexdigest(),
        "native_libraries": {name: {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
                             for name, data in replacements.items()},
        "preserved": "Published Java/JNI, manifest and notices; same model, types and CPU calculations",
    }
    (output / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(aar)
    print("SHA-256:", hashlib.sha256(aar.read_bytes()).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upstream", type=Path)
    parser.add_argument("builds", type=Path)
    parser.add_argument("repository", type=Path)
    args = parser.parse_args()
    package(args.upstream, args.builds, args.repository)
