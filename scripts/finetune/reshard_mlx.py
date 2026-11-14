#!/usr/bin/env python3
"""Reshard an MLX safetensors folder below an upload size limit, without MLX dependencies.

Oversize tensors are split on their first dimension. The manifest lets the app rebuild
ordinary MLX weights locally before loading. No model data is printed.
"""

import argparse
import hashlib
import json
import math
import shutil
import struct
from pathlib import Path

LIMIT = 290 * 1024 * 1024
DTYPE_BYTES = {"U8": 1, "I8": 1, "F16": 2, "BF16": 2, "U16": 2, "I16": 2,
               "U32": 4, "I32": 4, "F32": 4, "U64": 8, "I64": 8, "F64": 8}


def read_header(path):
    with path.open("rb") as stream:
        size = struct.unpack("<Q", stream.read(8))[0]
        return json.loads(stream.read(size)), 8 + size


def copy_range(source, target, offset, size):
    source.seek(offset)
    while size:
        block = source.read(min(size, 8 * 1024 * 1024))
        if not block:
            raise EOFError("source ended inside tensor")
        target.write(block)
        size -= len(block)


def write_shard(source, destination, tensors, metadata):
    header = {"__metadata__": metadata}
    position = 0
    for name, spec, _, size in tensors:
        header[name] = {"dtype": spec["dtype"], "shape": spec["shape"],
                        "data_offsets": [position, position + size]}
        position += size
    encoded = json.dumps(header, separators=(",", ":")).encode()
    with destination.open("wb") as target:
        target.write(struct.pack("<Q", len(encoded)))
        target.write(encoded)
        for _, _, offset, size in tensors:
            copy_range(source, target, offset, size)
    if destination.stat().st_size > LIMIT:
        raise ValueError(f"shard exceeds 290 MiB: {destination.name}")


def make_batches(header, data_start):
    batches = []
    batch = []
    used = 0
    split = {}
    for name, spec in sorted(header.items(), key=lambda item: item[1].get("data_offsets", [0])[0]):
        if name == "__metadata__":
            continue
        begin, end = spec["data_offsets"]
        size = end - begin
        pieces = [(name, spec, data_start + begin, size)]
        if size > LIMIT - 1024 * 1024:
            row_bytes = size // spec["shape"][0]
            assert row_bytes * spec["shape"][0] == size
            assert row_bytes == math.prod(spec["shape"][1:]) * DTYPE_BYTES[spec["dtype"]]
            rows_per_piece = (LIMIT - 1024 * 1024) // row_bytes
            pieces = []
            for first in range(0, spec["shape"][0], rows_per_piece):
                rows = min(rows_per_piece, spec["shape"][0] - first)
                part = f"{name}.__part{len(pieces):03d}"
                pieces.append((part, {"dtype": spec["dtype"], "shape": [rows] + spec["shape"][1:]},
                               data_start + begin + first * row_bytes, rows * row_bytes))
            split[name] = {"dtype": spec["dtype"], "shape": spec["shape"],
                           "parts": [piece[0] for piece in pieces]}
        for piece in pieces:
            if batch and used + piece[3] > LIMIT - 1024 * 1024:
                batches.append(batch)
                batch, used = [], 0
            batch.append(piece)
            used += piece[3]
    if batch:
        batches.append(batch)
    return batches, split


def write_folder(source_folder, destination, batches, split, data_start, metadata):
    source = source_folder / "model.safetensors"
    weight_map = {}
    with source.open("rb") as stream:
        for number, tensors in enumerate(batches, 1):
            filename = f"model-{number:05d}-of-{len(batches):05d}.safetensors"
            write_shard(stream, destination / filename, tensors, metadata)
            weight_map.update({name: filename for name, _, _, _ in tensors})
    (destination / "reshard-manifest.json").write_text(json.dumps({"version": 1, "split_tensors": split, "metadata": metadata},
                                                              sort_keys=True, separators=(",", ":")) + "\n")
    (destination / "model.safetensors.index.json").write_text(json.dumps({
        "metadata": {"total_size": source.stat().st_size - data_start}, "weight_map": weight_map},
        sort_keys=True, separators=(",", ":")) + "\n")
    for filename in ("config.json", "chat_template.jinja", "tokenizer.json", "tokenizer_config.json", "generation_config.json"):
        if (source_folder / filename).exists():
            shutil.copyfile(source_folder / filename, destination / filename)


def print_files(destination):
    for path in sorted(destination.iterdir()):
        if path.is_file():
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            print(f"{path.name}\t{path.stat().st_size}\t{digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    header, data_start = read_header(args.source / "model.safetensors")
    batches, split = make_batches(header, data_start)
    write_folder(args.source, args.destination, batches, split, data_start, header.get("__metadata__", {}))
    print_files(args.destination)


if __name__ == "__main__":
    main()
