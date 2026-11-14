"""Fold a PEFT LoRA adapter into a bf16 Hugging Face checkpoint on the Mac, shard by shard, with MLX (no torch needed).

    PY=.build/finetune-venv/bin/python
    $PY scripts/meeting-extract/merge_peft_local.py --base <hf dir> --adapter <peft adapter dir> --out <hf out dir>

Same result as `PeftModel.merge_and_unload()` up to bf16 rounding: W' = W + (alpha / r) * B @ A, with the product taken
in float32 and rounded once to bf16. Used when the Modal budget has no room for the merge job. Fails if the number of
merged modules differs from the adapter's, or any tensor name differs from the base's.
"""
import argparse
import json
import shutil
from pathlib import Path

import mlx.core as mx


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--delete-base-shards", action="store_true", help="remove each base shard once its merged copy is written (low disk)")
    args = ap.parse_args()
    base, adapter, out = Path(args.base), Path(args.adapter), Path(args.out)
    cfg = json.loads((adapter / "adapter_config.json").read_text())
    scale = cfg["lora_alpha"] / cfg["r"]
    lora = mx.load(str(adapter / "adapter_model.safetensors"))
    pairs = {}
    for key in lora:
        if ".lora_A.weight" in key:
            target = key.removeprefix("base_model.model.").replace(".lora_A.weight", ".weight")
            pairs[target] = (lora[key], lora[key.replace("lora_A", "lora_B")])
    out.mkdir(parents=True, exist_ok=True)
    index = json.loads((base / "model.safetensors.index.json").read_text())
    merged = 0
    for shard in sorted(set(index["weight_map"].values())):
        tensors = mx.load(str(base / shard))
        for name in list(tensors):
            if name in pairs:
                a, b = pairs.pop(name)
                tensors[name] = (tensors[name].astype(mx.float32) + scale * (b @ a)).astype(tensors[name].dtype)
                merged += 1
        mx.eval(tensors)
        mx.save_safetensors(str(out / shard), tensors, metadata={"format": "pt"})
        print(f"{shard}: {len(tensors)} tensors", flush=True)
        del tensors
        if args.delete_base_shards:
            (base / shard).unlink()
    if pairs:
        raise SystemExit(f"{len(pairs)} adapter modules found no base weight, e.g. {next(iter(pairs))}")
    print(f"merged {merged} modules, scale {scale}")
    for item in base.iterdir():
        if item.suffix != ".safetensors" and not (out / item.name).exists():
            shutil.copy2(item, out / item.name)
    for shard in set(index["weight_map"].values()):
        got = set(mx.load(str(out / shard)))
        want = {k for k, v in index["weight_map"].items() if v == shard}
        assert got == want, f"tensor names differ in {shard}"
    print("tensor names match the base")


if __name__ == "__main__":
    main()
