#!/usr/bin/env python3
"""Convert with mlx_lm 0.31.3's callable quant predicate (CLI offers presets only)."""
import argparse
from mlx_lm.convert import convert


def predicate(path, module):
    name = path.lower()
    if any(key in name for key in ("embed_tokens", "lm_head")):
        bits = 8
    elif any(key in name for key in ("v_proj", "down_proj")):
        bits = 6
    else:
        bits = 4
    return {"group_size": 64, "bits": bits, "mode": "affine"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    convert(hf_path=args.source, mlx_path=args.destination, quantize=True,
            q_group_size=64, q_bits=4, q_mode="affine", quant_predicate=predicate)


if __name__ == "__main__":
    main()
