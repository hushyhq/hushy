"""GRPO row selection with vLLM: the same scores as `grpo_cuda.py --select`, in minutes rather than hours.

Run in the serve venv (vLLM). Greedy answers from the merged bf16 base for every intent row, scored with
`grpo_rewards`; writes `selection.json` in the same shape `grpo_cuda.py` reads for training.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grpo_cuda import read_rows  # noqa: E402
from grpo_rewards import reward_components, total_reward  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--threshold', type=float, default=3.0)
    parser.add_argument('--seed', type=int, default=7)
    parser.add_argument('--max-new-tokens', type=int, default=160)
    parser.add_argument('--gpu-util', type=float, default=0.89)
    args = parser.parse_args()
    from vllm import LLM, SamplingParams
    rows = read_rows(args.data)
    # As serve/run_server.sh runs it (no vision encoder); few sequences, since each holds a linear-attention cache block.
    llm = LLM(model=args.base, dtype='bfloat16', language_model_only=True, generation_config='vllm',
              enable_prefix_caching=True, gpu_memory_utilization=args.gpu_util, max_model_len=2048, max_num_seqs=16)
    tokenizer = llm.get_tokenizer()
    prompts = [tokenizer.apply_chat_template(r['messages'], tokenize=False, add_generation_prompt=True,
                                             enable_thinking=False) for r in rows]
    outputs = llm.generate(prompts, SamplingParams(temperature=0, max_tokens=args.max_new_tokens))
    scored = [(row['id'], total_reward(reward_components(out.outputs[0].text, row['transcript'], row['reference'])))
              for row, out in zip(rows, outputs)]
    hard = [row_id for row_id, score in scored if score < args.threshold]
    ordinary = [row_id for row_id, score in scored if score >= args.threshold]
    random.Random(args.seed).shuffle(ordinary)
    chosen = set(hard + ordinary[:len(hard)])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'seed': args.seed, 'threshold': args.threshold, 'hard': len(hard),
                                       'random': min(len(hard), len(ordinary)), 'ids': sorted(chosen),
                                       'scanned': len(rows), 'by': 'vllm bf16 greedy'}, indent=2))
    scores = sorted(s for _, s in scored)
    print(f'rows: scanned={len(rows)} hard={len(hard)} random={min(len(hard), len(ordinary))} total={len(chosen)} '
          f'median_score={scores[len(scores) // 2]:.2f}')
    if not chosen: raise RuntimeError('selection is empty; raise the threshold')


if __name__ == '__main__':
    main()
