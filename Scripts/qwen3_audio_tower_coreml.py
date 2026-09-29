#!/usr/bin/env python3
"""Convert the Qwen3-ASR audio tower in an MLX checkpoint to a Core ML program for the Neural Engine.

The program encodes one 800-frame mel window exactly like
Qwen3ASRAudioEncoder.encodeSingleWindow (VendoredPackages/mlx-audio-swift):

  inputs   mel            [1, n_mels, 800] float32, zero-padded after the valid frames
           length         [1] int32, number of valid output tokens
  output   audio_features [1, 104, output_dim] float32

Conversion runs on the CPU and never touches the GPU. BF16 and MLX-quantized (2/4/8-bit affine)
audio towers are both accepted; quantized weights are dequantized before Core ML re-quantizes them.
coremltools 9.0 ships native extensions only up to Python 3.13 and is tested with torch 2.7, so
pin both. The --out path below is where the app looks for the tower before downloading it.

  uv venv /tmp/qwen-tower-venv --python 3.12
  uv pip install --python /tmp/qwen-tower-venv/bin/python 'torch==2.7.0' 'coremltools==9.0' numpy
  M="$HOME/Library/Application Support/org.axot.OpenSuperMLX/mlx-models"
  /tmp/qwen-tower-venv/bin/python Scripts/qwen3_audio_tower_coreml.py \\
      --model-dir "$M/mlx-audio/mlx-community_Qwen3-ASR-1.7B-5bit" \\
      --out "$M/coreml/qwen3_asr_audio_tower_int8.mlpackage" \\
      --check --plan --benchmark 20
"""

import argparse
import json
import math
import struct
import subprocess
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

FRAMES_PER_CHUNK = 100
TOKENS_PER_CHUNK = 13
WINDOW_FRAMES = 800
WINDOW_TOKENS = WINDOW_FRAMES // FRAMES_PER_CHUNK * TOKENS_PER_CHUNK
SAFETENSORS_DTYPES = {"F32": np.float32, "F16": np.float16, "BF16": np.uint16, "U32": np.uint32}


# MARK: - Checkpoint


def load_config(model_dir):
    config = json.loads((model_dir / "config.json").read_text())
    audio = config.get("thinker_config", config).get("audio_config") or config["audio_config"]
    quantization = config.get("quantization")
    if quantization is None and (model_dir / "quantization_config.json").exists():
        quantization = json.loads((model_dir / "quantization_config.json").read_text())
    return audio, quantization or {}


def read_audio_tower(model_dir):
    """Memory-maps only the audio tower tensors; returns (tensors, uses_mlx_layout)."""
    tensors, saw_thinker_prefix = {}, False
    for path in sorted(model_dir.glob("*.safetensors")):
        with open(path, "rb") as handle:
            header_size = struct.unpack("<Q", handle.read(8))[0]
            header = json.loads(handle.read(header_size))
        data = np.memmap(path, dtype=np.uint8, mode="r", offset=8 + header_size)
        for name, info in header.items():
            saw_thinker_prefix |= name.startswith("thinker.")
            if "audio_tower." not in name:
                continue
            start, end = info["data_offsets"]
            array = data[start:end].view(SAFETENSORS_DTYPES[info["dtype"]]).reshape(info["shape"])
            if info["dtype"] == "BF16":
                array = (array.astype(np.uint32) << 16).view(np.float32)
            tensors[name.split("audio_tower.", 1)[1]] = array
    if not tensors:
        raise SystemExit(f"no audio_tower tensors in {model_dir}")
    return tensors, not saw_thinker_prefix


def dequantize(packed, scales, biases, group_size):
    in_features = scales.shape[-1] * group_size
    bits = 32 * packed.shape[-1] // in_features
    if bits not in (2, 4, 8) or 32 * packed.shape[-1] != bits * in_features:
        raise SystemExit(f"unsupported MLX packing: {packed.shape} with group size {group_size}")
    shifts = np.arange(0, 32, bits, dtype=np.uint32)
    values = ((packed[..., None] >> shifts) & ((1 << bits) - 1)).reshape(packed.shape[0], -1)
    scales = np.repeat(scales.astype(np.float32), group_size, axis=-1)
    biases = np.repeat(biases.astype(np.float32), group_size, axis=-1)
    return values.astype(np.float32) * scales + biases


def state_dict(tower, tensors, quantization, mlx_layout):
    state = {}
    for name in tower.state_dict():
        base, leaf = name.rsplit(".", 1)
        if leaf == "weight" and f"{base}.scales" in tensors:
            layer = quantization.get(f"audio_tower.{base}") or {}
            group_size = layer.get("group_size", quantization.get("group_size", 64))
            value = dequantize(tensors[name], tensors[f"{base}.scales"], tensors[f"{base}.biases"], group_size)
        else:
            value = tensors[name].astype(np.float32)
        if base.startswith("conv2d") and leaf == "weight" and mlx_layout:
            value = value.transpose(0, 3, 1, 2)
        state[name] = torch.from_numpy(np.ascontiguousarray(value))
    return state


# MARK: - Model (mirrors Qwen3ASRAudioEncoder)


def sinusoids(length, channels, max_timescale=10000.0):
    increment = math.log(max_timescale) / (channels // 2 - 1)
    inverse = torch.exp(-increment * torch.arange(channels // 2, dtype=torch.float32))
    scaled = torch.arange(length, dtype=torch.float32)[:, None] * inverse[None, :]
    return torch.cat([scaled.sin(), scaled.cos()], dim=1)


class Attention(nn.Module):
    def __init__(self, dim, heads):
        super().__init__()
        self.dim, self.heads, self.head_dim = dim, heads, dim // heads
        self.q_proj = nn.Linear(dim, dim)
        self.k_proj = nn.Linear(dim, dim)
        self.v_proj = nn.Linear(dim, dim)
        self.out_proj = nn.Linear(dim, dim)

    def forward(self, x, mask):
        # Static shapes only: coremltools cannot convert sizes read back from x.shape.
        def split(t):
            return t.reshape(1, WINDOW_TOKENS, self.heads, self.head_dim).transpose(1, 2)

        q, k, v = split(self.q_proj(x)), split(self.k_proj(x)), split(self.v_proj(x))
        weights = (q @ k.transpose(-1, -2) * self.head_dim**-0.5 + mask).softmax(dim=-1)
        return self.out_proj((weights @ v).transpose(1, 2).reshape(1, WINDOW_TOKENS, self.dim))


class EncoderLayer(nn.Module):
    def __init__(self, dim, heads, ffn_dim):
        super().__init__()
        self.self_attn = Attention(dim, heads)
        self.self_attn_layer_norm = nn.LayerNorm(dim)
        self.fc1 = nn.Linear(dim, ffn_dim)
        self.fc2 = nn.Linear(ffn_dim, dim)
        self.final_layer_norm = nn.LayerNorm(dim)

    def forward(self, x, mask):
        x = x + self.self_attn(self.self_attn_layer_norm(x), mask)
        return x + self.fc2(F.gelu(self.fc1(self.final_layer_norm(x))))


class AudioTower(nn.Module):
    def __init__(self, config):
        super().__init__()
        channels, dim = config["downsample_hidden_size"], config["d_model"]
        self.mel_bins = config["num_mel_bins"]
        self.conv2d1 = nn.Conv2d(1, channels, 3, stride=2, padding=1)
        self.conv2d2 = nn.Conv2d(channels, channels, 3, stride=2, padding=1)
        self.conv2d3 = nn.Conv2d(channels, channels, 3, stride=2, padding=1)
        frequencies = ((((self.mel_bins + 1) // 2) + 1) // 2 + 1) // 2
        self.conv_out = nn.Linear(channels * frequencies, dim, bias=False)
        self.layers = nn.ModuleList(
            EncoderLayer(dim, config["encoder_attention_heads"], config["encoder_ffn_dim"])
            for _ in range(config["encoder_layers"])
        )
        self.ln_post = nn.LayerNorm(dim)
        self.proj1 = nn.Linear(dim, dim)
        self.proj2 = nn.Linear(dim, config["output_dim"])
        self.register_buffer("positional_embedding", sinusoids(TOKENS_PER_CHUNK, dim), persistent=False)

    def forward(self, mel, length):
        chunks = WINDOW_FRAMES // FRAMES_PER_CHUNK
        x = mel.reshape(1, self.mel_bins, chunks, FRAMES_PER_CHUNK).permute(2, 0, 1, 3)
        x = F.gelu(self.conv2d1(x))
        x = F.gelu(self.conv2d2(x))
        x = F.gelu(self.conv2d3(x))
        x = x.permute(0, 3, 1, 2).reshape(chunks, TOKENS_PER_CHUNK, -1)
        x = (self.conv_out(x) + self.positional_embedding).reshape(1, WINDOW_TOKENS, -1)
        valid = torch.arange(WINDOW_TOKENS, dtype=torch.int32) < length
        mask = ((valid.float() - 1.0) * 1e4).reshape(1, 1, 1, WINDOW_TOKENS)
        for layer in self.layers:
            x = layer(x, mask)
        return self.proj2(F.gelu(self.proj1(self.ln_post(x))))


def valid_tokens(frames):
    def chunk_tokens(length):
        for _ in range(3):
            length = (length - 1) // 2 + 1
        return length

    remainder = frames % FRAMES_PER_CHUNK
    return frames // FRAMES_PER_CHUNK * TOKENS_PER_CHUNK + (chunk_tokens(remainder) if remainder else 0)


# MARK: - Core ML


def convert(tower, mel_bins, out_path, weights):
    import coremltools as ct

    example = (torch.zeros(1, mel_bins, WINDOW_FRAMES), torch.tensor([WINDOW_TOKENS], dtype=torch.int32))
    with torch.no_grad():
        traced = torch.jit.trace(tower.eval(), example)
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mel", shape=tuple(example[0].shape), dtype=np.float32),
            ct.TensorType(name="length", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="audio_features", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS15,
        skip_model_load=True,
    )
    if weights == "int8":
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig,
            OptimizationConfig,
            linear_quantize_weights,
        )

        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
        )
        mlmodel = linear_quantize_weights(mlmodel, config=config)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(out_path), str(out_path.parent)], check=True)
    return out_path.with_suffix(".mlmodelc")


def window_inputs(mel_bins, frames, seed=0):
    mel = np.zeros((1, mel_bins, WINDOW_FRAMES), np.float32)
    mel[:, :, :frames] = np.random.default_rng(seed).uniform(-1, 1, (1, mel_bins, frames))
    return {"mel": mel, "length": np.array([valid_tokens(frames)], np.int32)}


def check(tower, mel_bins, compiled):
    import coremltools as ct

    mlmodel = ct.models.CompiledMLModel(str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE)
    for frames in (250, 800):
        inputs = window_inputs(mel_bins, frames, seed=frames)
        tokens = int(inputs["length"][0])
        with torch.no_grad():
            reference = tower(torch.from_numpy(inputs["mel"]), torch.from_numpy(inputs["length"]))[0, :tokens].numpy()
        candidate = mlmodel.predict(inputs)["audio_features"][0, :tokens]
        cosine = (reference * candidate).sum(-1) / (
            np.linalg.norm(reference, axis=-1) * np.linalg.norm(candidate, axis=-1)
        )
        print(f"check frames={frames} tokens={tokens} worst_cosine={cosine.min():.4f} mean_cosine={cosine.mean():.4f}")


def report_plan(compiled):
    import coremltools as ct

    try:
        from coremltools.models.compute_plan import MLComputePlan

        plan = MLComputePlan.load_from_path(path=str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE)
        costs = {}
        for function in plan.model_structure.program.functions.values():
            for operation in function.block.operations:
                usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
                cost = plan.get_estimated_cost_for_mlprogram_operation(operation)
                device = type(usage.preferred_compute_device).__name__ if usage else "none"
                costs[device] = costs.get(device, 0.0) + (cost.weight if cost else 0.0)
        for device, weight in sorted(costs.items(), key=lambda item: -item[1]):
            print(f"plan {device}: {weight:.1%} of estimated cost")
    except Exception as error:
        print(f"plan unavailable ({error}); needs coremltools 8+ on macOS 14.4+")


def benchmark(mel_bins, compiled, runs):
    import coremltools as ct

    inputs = window_inputs(mel_bins, WINDOW_FRAMES)
    for units in (ct.ComputeUnit.CPU_AND_NE, ct.ComputeUnit.CPU_ONLY):
        mlmodel = ct.models.CompiledMLModel(str(compiled), compute_units=units)
        mlmodel.predict(inputs)
        start = time.perf_counter()
        for _ in range(runs):
            mlmodel.predict(inputs)
        print(f"benchmark {units.name}: {(time.perf_counter() - start) / runs * 1000:.1f} ms per 8 s window")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--model-dir", type=Path, required=True, help="MLX checkpoint with config.json and *.safetensors")
    parser.add_argument("--out", type=Path, required=True, help="output .mlpackage; the .mlmodelc is written beside it")
    parser.add_argument("--weights", choices=["int8", "fp16"], default="int8")
    parser.add_argument("--check", action="store_true", help="compare Core ML against the FP32 PyTorch tower")
    parser.add_argument("--plan", action="store_true", help="print estimated cost per compute device")
    parser.add_argument("--benchmark", type=int, default=0, metavar="N", help="time N predictions on ANE and CPU")
    args = parser.parse_args()

    config, quantization = load_config(args.model_dir)
    tensors, mlx_layout = read_audio_tower(args.model_dir)
    tower = AudioTower(config)
    tower.load_state_dict(state_dict(tower, tensors, quantization, mlx_layout))
    quantized = sum(name.endswith(".scales") for name in tensors)
    print(f"loaded audio tower: {len(tensors)} tensors, {quantized} MLX-quantized layers")

    compiled = convert(tower, config["num_mel_bins"], args.out, args.weights)
    print(f"compiled: {compiled}")
    if args.check:
        check(tower, config["num_mel_bins"], compiled)
    if args.plan:
        report_plan(compiled)
    if args.benchmark:
        benchmark(config["num_mel_bins"], compiled, args.benchmark)


if __name__ == "__main__":
    main()
