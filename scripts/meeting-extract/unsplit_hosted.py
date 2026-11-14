"""Turn the hosted MLX folder (embed_tokens split in two parts for the 290 MiB upload limit, see reshard_mlx.py) back into
one ordinary MLX folder that mlx_lm can load. This is how the stock r10d 6-bit is run in Python for the extract eval.

    .build/finetune-venv/bin/python scripts/meeting-extract/unsplit_hosted.py <hosted dir> <out dir>
"""
import json
import shutil
import sys
from pathlib import Path

import mlx.core as mx

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
dst.mkdir(parents=True, exist_ok=True)
manifest = json.loads((src / "reshard-manifest.json").read_text())
tensors = {}
for f in sorted(src.glob("model-*.safetensors")):
    tensors.update(mx.load(str(f)))
for name, spec in manifest["split_tensors"].items():
    parts = [tensors.pop(p) for p in spec["parts"]]
    full = mx.concatenate(parts, axis=0)
    assert list(full.shape) == spec["shape"], (full.shape, spec["shape"])
    tensors[name] = full
mx.save_safetensors(str(dst / "model.safetensors"), tensors, metadata=manifest["metadata"])
for f in ("config.json", "chat_template.jinja", "tokenizer.json", "tokenizer_config.json", "generation_config.json"):
    if (src / f).exists():
        shutil.copyfile(src / f, dst / f)
print(len(tensors), "tensors")
