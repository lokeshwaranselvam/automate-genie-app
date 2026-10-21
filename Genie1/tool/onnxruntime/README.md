# SFace-only ONNX Runtime build

This is developer tooling for ONNX Runtime **1.28.0** reduced-operator builds.
Android Gradle selects the validated `1.28.0-sface1` artifact bundled under
`android/runtime-maven`. Ordinary Flutter builds use that AAR; they do not
recompile ONNX Runtime. The first source build takes substantially longer.

Set the Gradle property `genieFullOnnxRuntime=true` to compare against the
published full runtime. Leave it unset for normal reduced-runtime builds.
The substitution matches only the plugin's verified Android version 1.28.0.

The packaged SFace INT8 block ONNX model, its weights, float input/output,
alignment, image preprocessing, threshold and enrollment flow stay unchanged.
The configuration retains the operators used by the raw model and its
BASIC/EXTENDED/ALL CPU graphs. Type reduction, further quantization, minimal
ORT-format-only loading and fast-math changes are not enabled.

## Build

Use official ONNX Runtime release `v1.28.0`, Android SDK, NDK 28.2.13676358,
CMake >=3.28, Ninja, Python and the source build's Python prerequisites.
Use a short source/build path on Windows. SDK API 24 matches the existing app.

Run `build_runtime.ps1` with the paths to those tools. Its default ABI list is
`arm64-v8a`, `armeabi-v7a`, `x86_64`. The optional dependency mirror must contain
upstream archives at their original URL paths; CMake checks their pinned hashes.
Only unused operator implementations and ONNX-ML support are excluded. The
standard ONNX loader, CPU execution provider, numerical types and exceptions
are retained. NNAPI support is also retained because the published Java/JNI
bridge links its entry point, even when the app uses only CPU inference.

## Validate before integrating

1. Preserve the existing universal APK and published Android 1.28.0 AAR.
2. Compile `../ort_inference_probe.c` with the matching NDK and Runtime C API
   header. On a test device, invoke it separately with the published and reduced
   libraries against the same model/input tensors. It writes 128 raw float32
   features to the specified output. It never accesses employee app data.
3. Compare finite embeddings and cosine match decisions.
   Synthetic probes test numerical compatibility; real face examples and device
   checks are still required for recognition-quality claims.
4. Validate ELF ABI and page alignment, JNI compatibility, and all supported ABIs.
   Compile `OrtJavaProbe.java` with the published AAR's `classes.jar` using
   `javac --release 8`. Use Android `d8 --min-api 24` to dex both the probe class
   and `classes.jar`. Extract the published `libonnxruntime4j_jni.so` into
   ABI-named folders. `compare_android.py` accepts `--java-dex` and `--jni` to
   exercise the original Java/JNI loader, session metadata, tensor creation,
   inference, output copying and disposal, in addition to its C API comparison.
   It fails if the phone does not support the requested ABI. Run x86_64 on an
   x86_64 Android emulator/device; an ARM phone cannot validate that ABI.
5. `package_runtime.py upstream.aar build-root local-maven-root` preserves the
   upstream Java classes, JNI bridge, manifest and notices, replacing only
   `jni/<abi>/libonnxruntime.so`. Its custom coordinates distinguish this artifact
   from Microsoft's published package.
6. Only after validation, select the artifact in Gradle and rebuild the universal
   APK. Compare all non-runtime code/assets, verify signing/alignment, and measure
   the actual compressed APK size. Do not claim the earlier estimate as a result.

The scripts deliberately use `/data/local/tmp/genie-ort128-evaluation` for phone
checks. They do not install an APK, log into ERP, or open employee app storage.
Comparison times include adb and session loading, so they are not camera or
pure inference benchmarks. A new model or ONNX Runtime upgrade requires a new
operator configuration and fresh compatibility tests.

## Validation recorded on 2026-10-17

The adjacent Maven artifact's `build-manifest.json` records its source/model
hashes and native library hashes. `validation.json` links those exact binaries
to eight input cases per ABI: ARM64 and ARMv7 on a physical Android 15 phone,
and x86_64 in an Android 15 emulator. All full/reduced C and published Java/JNI
outputs were bit-for-bit identical, with zero cosine score difference and the
same match decisions. The Java probe also validates session metadata and the
float-buffer output path used by Flutter. Synthetic tensors are compatibility
tests, not a new real-face accuracy benchmark.

The resulting universal release APK is **75,589,203 bytes (72.09 MiB)** versus
**95,314,095 bytes (90.90 MiB)** before this runtime replacement: **18.81 MiB**
saved. Only the three `libonnxruntime.so` entries differ. All other APK file
contents, including Dart code, Java/DEX, JNI, Flutter/ML Kit libraries, model,
resources and manifest, are byte-identical. APK signing verifies with the same
signer, and the 16 KiB zip-alignment check passes.

Android's native strip step rewrites `.shstrtab` section-name metadata. All
allocated ELF sections (executable code, data and dynamic linking information)
remain byte-identical to the device-tested libraries. `apk-validation.json`
records those source/packaged hashes and the final APK hash and size.

Sources:

- https://onnxruntime.ai/docs/build/custom.html
- https://onnxruntime.ai/docs/build/android.html
- https://github.com/microsoft/onnxruntime/tree/v1.28.0
