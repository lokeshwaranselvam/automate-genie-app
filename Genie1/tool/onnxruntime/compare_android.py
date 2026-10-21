"""Compare full/reduced C API and optional Java/JNI inference on Android.

Requires numpy, adb, and NDK-compiled ../ort_inference_probe.c binaries.
Synthetic tensors test numerical compatibility, not employee-face accuracy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

import numpy as np

REMOTE = "/data/local/tmp/genie-ort128-evaluation"
PROBES = {"arm64-v8a": "probe-arm64", "armeabi-v7a": "probe-armv7", "x86_64": "probe-x86_64"}


def compare(args, abi):
    adb = [str(args.adb), "-s", args.serial]

    def run(*parts):
        completed = subprocess.run(adb + list(parts), capture_output=True, text=True, timeout=60)
        if completed.returncode:
            raise RuntimeError(f"adb failed ({completed.returncode}): {completed.stdout}\n{completed.stderr}")
        return completed

    supported = run("shell", "getprop", "ro.product.cpu.abilist").stdout.strip().split(",")
    if abi not in supported:
        raise ValueError(f"The connected device cannot execute {abi}: {supported}")
    if bool(args.java_dex) != bool(args.jni):
        raise ValueError("Supply both --java-dex and --jni to validate the published Java bridge.")

    probe = args.probes / PROBES[abi]
    full = args.full / abi / "libonnxruntime.so"
    reduced = args.builds / abi / "Release" / "libonnxruntime.so"
    for path in [probe, full, reduced, args.model]:
        if not path.is_file():
            raise FileNotFoundError(path)
    run("shell", "mkdir", "-p", REMOTE)
    for path, name in [(probe, "probe"), (full, "full.so"),
                       (reduced, "reduced.so"), (args.model, "model.onnx")]:
        run("push", str(path), REMOTE + "/" + name)
    run("shell", "chmod", "700", REMOTE + "/probe")
    modes = ["c"]
    if args.java_dex:
        modes.append("java")
        run("push", str(args.java_dex), REMOTE + "/probe.dex")
        jni = args.jni / abi / "libonnxruntime4j_jni.so"
        for variant, library in [("full", full), ("reduced", reduced)]:
            directory = f"{REMOTE}/{variant}-{abi}"
            run("shell", "mkdir", "-p", directory)
            run("push", str(library), directory + "/libonnxruntime.so")
            run("push", str(jni), directory + "/libonnxruntime4j_jni.so")
    folder = args.output / abi
    folder.mkdir(parents=True, exist_ok=True)
    tensors = [np.full((1, 3, 112, 112), value, dtype=np.float32)
               for value in [0, 127.5, 255]]
    tensors.append(np.linspace(0, 255, 3 * 112 * 112, dtype=np.float32).reshape(1, 3, 112, 112))
    tensors.extend(np.random.default_rng(seed).uniform(0, 255, (1, 3, 112, 112)).astype(np.float32)
                   for seed in [0, 1, 2026, 4242])
    keys = [mode + "-" + variant for mode in modes for variant in ["full", "reduced"]]
    results = {key: [] for key in keys}
    elapsed = {key: [] for key in keys}
    for index, tensor in enumerate(tensors):
        input_path = folder / f"input-{index}.f32"
        tensor.tofile(input_path)
        run("push", str(input_path), REMOTE + "/input.f32")
        for key in keys:
            mode, variant = key.split("-")
            started = time.perf_counter()
            if mode == "c":
                run("shell", REMOTE + "/probe", REMOTE + f"/{variant}.so",
                    REMOTE + "/model.onnx", REMOTE + "/input.f32", REMOTE + "/output.f32")
            else:
                directory = f"{REMOTE}/{variant}-{abi}"
                process = "/system/bin/app_process64" if abi != "armeabi-v7a" else "/system/bin/app_process32"
                run("shell", "env", "CLASSPATH=" + REMOTE + "/probe.dex",
                    "LD_LIBRARY_PATH=" + directory, process,
                    "-Djava.library.path=" + directory, "/system/bin", "OrtJavaProbe",
                    REMOTE + "/model.onnx", REMOTE + "/input.f32", REMOTE + "/output.f32")
            elapsed[key].append(round((time.perf_counter() - started) * 1000, 2))
            output_path = folder / f"{key}-{index}.f32"
            run("pull", REMOTE + "/output.f32", str(output_path))
            output = np.fromfile(output_path, dtype=np.float32)
            if output.shape != (128,) or not np.isfinite(output).all() or np.linalg.norm(output) == 0:
                raise ValueError(f"Invalid {key} embedding for tensor {index}")
            results[key].append(output)
        for key in keys[1:]:
            np.testing.assert_allclose(results["c-full"][-1], results[key][-1],
                                       rtol=1e-5, atol=1e-6)
    full_values = np.stack(results["c-full"])
    reduced_values = np.stack(results["c-reduced"])
    # Dart converts the float32 model output to doubles before normalization.
    full_norm = full_values.astype(np.float64)
    full_norm /= np.linalg.norm(full_norm, axis=1, keepdims=True)
    reduced_norm = reduced_values.astype(np.float64)
    reduced_norm /= np.linalg.norm(reduced_norm, axis=1, keepdims=True)
    full_scores = full_norm @ full_norm.T
    reduced_scores = reduced_norm @ reduced_norm.T
    if not np.array_equal(full_scores >= 0.5, reduced_scores >= 0.5):
        raise ValueError("Cosine match decisions differ at the existing 0.5 threshold.")
    report = {
        "abi": abi, "tensor_cases": len(tensors),
        "model_sha256": hashlib.sha256(args.model.read_bytes()).hexdigest(),
        "full_library_sha256": hashlib.sha256(full.read_bytes()).hexdigest(),
        "reduced_library_sha256": hashlib.sha256(reduced.read_bytes()).hexdigest(),
        "bit_identical_outputs": bool(np.array_equal(full_values, reduced_values)),
        "max_absolute_embedding_error": float(np.max(np.abs(full_values - reduced_values))),
        "max_cosine_score_error": float(np.max(np.abs(full_scores - reduced_scores))),
        "all_pairwise_match_decisions_equal": True,
        "java_jni_validated": "java" in modes,
        "all_bridges_bit_identical": all(np.array_equal(full_values, np.stack(results[key])) for key in keys),
        "adb_session_load_and_run_ms": elapsed,
        "limitation": "Synthetic compatibility tests; not real-face accuracy or pure inference latency.",
    }
    (folder / "comparison.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["adb", "probes", "full", "builds", "model", "output"]:
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--java-dex", type=Path, help="DEX containing OrtJavaProbe and published ORT classes")
    parser.add_argument("--jni", type=Path, help="Extracted upstream JNI libraries, grouped by ABI")
    parser.add_argument("--abi", nargs="+", choices=list(PROBES), default=["arm64-v8a", "armeabi-v7a"])
    args = parser.parse_args()
    for selected in args.abi:
        compare(args, selected)
