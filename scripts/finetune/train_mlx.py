#!/usr/bin/env python3
"""`mlx_lm.lora` on Apple silicon, with the chat template rendered exactly as the Swift runtime
renders it (non-thinking: `enable_thinking=False`, so the prompt ends in the empty
`<think>\\n\\n</think>\\n\\n` block and only the JSON answer is trained — `mask_prompt`).

    python3 scripts/finetune/train_mlx.py --config scripts/finetune/configs/mlx-qwen3.5-0.8b-smoke.yaml

Every other option is mlx_lm.lora's own (a YAML config; see mlx_lm/LORA.md). This is the Mac
path; the CUDA path is scripts/finetune/cuda/ (same data files, same prompt).
"""

from __future__ import annotations

import sys

import mlx_lm.lora
from mlx_lm.tuner import datasets

_original_process = datasets.ChatDataset.process


def _process_without_thinking(self, d):  # noqa: ANN001
    messages = d[self.chat_key]
    tokens = self.tokenizer.apply_chat_template(messages, return_dict=False, enable_thinking=False)
    if not self.mask_prompt:
        return (tokens, 0)
    prompt = self.tokenizer.apply_chat_template(
        messages[:-1], add_generation_prompt=True, return_dict=False, enable_thinking=False
    )
    if tokens[: len(prompt)] != prompt:
        raise ValueError("chat template: the prompt is not a prefix of the full conversation")
    return (tokens, len(prompt))


datasets.ChatDataset.process = _process_without_thinking

if __name__ == "__main__":
    sys.argv[0] = "mlx_lm.lora"
    mlx_lm.lora.main()
