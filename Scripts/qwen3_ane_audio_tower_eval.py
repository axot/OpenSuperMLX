#!/usr/bin/env python3
"""Compare transcription variants through the app CLI: speed, CPU time, memory, GPU utilization.

Variants:
  A  --baseline-binary, a build from before this change (Qwen3-ASR-1.7B-8bit, GPU audio tower)
  B  --binary with useNeuralEngineAudioTower=false (Qwen3-ASR-1.7B-5bit, GPU audio tower)
  C  --binary with useNeuralEngineAudioTower=true  (Qwen3-ASR-1.7B-5bit, Neural Engine audio tower)

Each run records wall and CPU time and peak process memory (/usr/bin/time -l), transcription speed
from the CLI's JSON, and the GPU time the CLI process itself used (its Metal clients'
accumulatedGPUTime in ioreg). Other processes' GPU time is measured the same way: a run starts only
after they stay below --max-other-gpu of the GPU for 5 s, and a run during which they exceed it is
discarded and repeated, because contention slows the run even though it does not inflate our own
GPU figure. Process memory excludes memory the Neural Engine maps outside the app. The toggle is
restored to its previous value afterwards.

  Scripts/qwen3_ane_audio_tower_eval.py --baseline-binary ../OpenSuperMLX/build/.../OpenSuperMLX \\
      --out /tmp/qwen-ane-eval.json jfk.wav recording1.m4a
"""

import argparse
import difflib
import json
import re
import statistics
import subprocess
import threading
import time
import unicodedata
from pathlib import Path

DEFAULT_BINARY = "build/Build/Products/Debug/OpenSuperMLX.app/Contents/MacOS/OpenSuperMLX"
TOGGLE = "useNeuralEngineAudioTower"


def gpu_ns_by_pid():
    output = subprocess.run(
        ["ioreg", "-r", "-c", "AGXDeviceUserClient", "-l", "-w0"], capture_output=True, text=True
    ).stdout
    totals = {}
    for block in output.split("+-o ")[1:]:
        creator = re.search(r'"IOUserClientCreator" = "pid (\d+),', block)
        if creator:
            pid = int(creator.group(1))
            totals[pid] = totals.get(pid, 0) + sum(map(int, re.findall(r'"accumulatedGPUTime"=(\d+)', block)))
    return totals


def process_gpu_ns(pid):
    return gpu_ns_by_pid().get(pid, 0)


def gpu_ns_used_since(before, excluding=()):
    after = gpu_ns_by_pid()
    return sum(ns - before.get(pid, 0) for pid, ns in after.items() if pid not in excluding)


def wait_for_quiet_gpu(max_other_gpu, window=5.0):
    while True:
        before = gpu_ns_by_pid()
        time.sleep(window)
        share = gpu_ns_used_since(before) / (window * 1e9)
        if share < max_other_gpu:
            return
        print(f"waiting: other processes use {share:.0%} of the GPU", flush=True)


def track_gpu(timer_pid, result, stop):
    """Follows the CLI (the child of /usr/bin/time) and keeps its latest accumulated GPU time."""
    child = None
    while not stop.is_set():
        if child is None:
            found = subprocess.run(["pgrep", "-P", str(timer_pid)], capture_output=True, text=True).stdout.split()
            child = int(found[0]) if found else None
            result["child"] = child
        if child is not None:
            result["gpu_ns"] = max(result["gpu_ns"], process_gpu_ns(child))
        stop.wait(0.5)


def parse_cli_output(stdout):
    # Model loading prints cache paths to stdout; the JSON result is the last object line.
    for line in reversed(stdout.strip().splitlines()):
        if line.startswith("{"):
            return json.loads(line)["data"]
    raise ValueError(f"no JSON result in CLI output: {stdout[-300:]}")


def cli_json(binary, *arguments):
    process = subprocess.run([binary, *arguments, "--json", "--quiet"], capture_output=True, text=True)
    if process.returncode != 0:
        raise RuntimeError(f"{' '.join(arguments)} failed: {process.stderr[-500:]}")
    return parse_cli_output(process.stdout)


def run_cli(binary, command, audio):
    arguments = ["/usr/bin/time", "-l", binary, command, str(audio), "--json", "--quiet"]
    if command == "transcribe":
        arguments.append("--no-correction")

    before = gpu_ns_by_pid()
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    gpu, stop = {"gpu_ns": 0, "child": None}, threading.Event()
    tracker = threading.Thread(target=track_gpu, args=(process.pid, gpu, stop))
    tracker.start()
    stdout, stderr = process.communicate()
    stop.set()
    tracker.join()
    other_gpu_ns = gpu_ns_used_since(before, excluding={process.pid, gpu["child"]})
    if process.returncode != 0:
        raise RuntimeError(f"{command} failed for {audio}: {stderr[-500:]}")

    data = parse_cli_output(stdout)
    real, user, system = map(float, re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", stderr).groups())
    peak = int(re.search(r"(\d+)\s+peak memory footprint", stderr).group(1))
    return {
        "text": data["text"],
        "model": data["model"],
        "audio_encoder": data.get("audio_encoder", "gpu"),
        "audio_seconds": data["audio_duration_s"],
        "transcription_seconds": data["processing_time_s"],
        "wall_seconds": real,
        "cpu_seconds": user + system,
        "gpu_seconds": gpu["gpu_ns"] / 1e9,
        "other_gpu_seconds": other_gpu_ns / 1e9,
        "peak_footprint_mb": peak / 2**20,
    }


def run_clean(binary, command, audio, max_other_gpu, attempts=5):
    for _ in range(attempts):
        wait_for_quiet_gpu(max_other_gpu)
        run = run_cli(binary, command, audio)
        share = run["other_gpu_seconds"] / run["wall_seconds"]
        if share < max_other_gpu:
            return run
        print(f"discarded {Path(audio).name}: other processes used {share:.0%} of the GPU during the run", flush=True)
    raise RuntimeError(f"the GPU never stayed quiet while transcribing {audio}")


def normalize(text):
    text = unicodedata.normalize("NFKC", text).lower()
    return "".join(c for c in text if unicodedata.category(c)[0] in "LN")


def agreement(lhs, rhs):
    return difflib.SequenceMatcher(None, normalize(lhs), normalize(rhs), autojunk=False).ratio()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("audio", nargs="+", type=Path)
    parser.add_argument("--baseline-binary", required=True, help="CLI built before this change (variant A)")
    parser.add_argument("--binary", default=DEFAULT_BINARY, help="CLI with this change (variants B and C)")
    parser.add_argument("--command", choices=["stream-simulate", "transcribe"], default="stream-simulate")
    parser.add_argument("--out", type=Path, help="write per-run results as JSON")
    parser.add_argument("--max-other-gpu", type=float, default=0.25,
                        help="largest GPU share other processes may use before and during a run")
    args = parser.parse_args()

    variants = {
        "A": (args.baseline_binary, None, "gpu"),
        "B": (args.binary, "false", "gpu"),
        "C": (args.binary, "true", "neural_engine"),
    }
    previous = cli_json(args.binary, "config", "get", TOGGLE)["value"]
    results = {name: [] for name in variants}
    try:
        for name, (binary, toggle, expected_encoder) in variants.items():
            if toggle is not None:
                cli_json(binary, "config", "set", TOGGLE, toggle)
            run_clean(binary, args.command, args.audio[0], args.max_other_gpu)
            for audio in args.audio:
                run = run_clean(binary, args.command, audio, args.max_other_gpu)
                if run["audio_encoder"] != expected_encoder:
                    raise RuntimeError(f"variant {name} used the {run['audio_encoder']} audio encoder")
                run["audio"] = str(audio)
                results[name].append(run)
                print(
                    f"{name} {audio.name}: speed={run['audio_seconds'] / run['transcription_seconds']:.1f}x "
                    f"cpu={run['cpu_seconds']:.1f}s gpu={run['gpu_seconds']:.1f}s "
                    f"other_gpu={run['other_gpu_seconds']:.2f}s peak={run['peak_footprint_mb']:.0f}MB",
                    flush=True,
                )
    finally:
        cli_json(args.binary, "config", "set", TOGGLE, str(previous).lower())

    print(f"\n{'variant':8} {'model':36} {'encoder':14} {'speed':>7} {'cpu s':>7} {'gpu s':>7} {'gpu %':>6} {'peak MB':>8}")
    for name, runs in results.items():
        audio_seconds = sum(run["audio_seconds"] for run in runs)
        gpu_seconds = sum(run["gpu_seconds"] for run in runs)
        wall_seconds = sum(run["wall_seconds"] for run in runs)
        print(
            f"{name:8} {runs[0]['model']:36} {runs[0]['audio_encoder']:14} "
            f"{audio_seconds / sum(run['transcription_seconds'] for run in runs):6.1f}x "
            f"{sum(run['cpu_seconds'] for run in runs):7.1f} {gpu_seconds:7.1f} "
            f"{gpu_seconds / wall_seconds:6.0%} {max(run['peak_footprint_mb'] for run in runs):8.0f}"
        )
    for lhs, rhs in (("A", "B"), ("B", "C")):
        score = statistics.fmean(agreement(a["text"], b["text"]) for a, b in zip(results[lhs], results[rhs]))
        print(f"text agreement {lhs} vs {rhs}: {score:.1%}")
    if args.out:
        args.out.write_text(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
