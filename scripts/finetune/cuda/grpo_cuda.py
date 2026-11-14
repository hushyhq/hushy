#!/usr/bin/env python3
"""GRPO/QLoRA cleanup trial. See GRPO-README.md for PC commands and estimates."""
from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path

from grpo_rewards import WEIGHTS, reward_components, total_reward

DEFAULT_CONFIG = Path(__file__).parent / 'configs/grpo-qwen3.5-4b-qlora.yaml'
FORBIDDEN = ('heldout', 'voicelab', 'ab-', 'long64-b', 'longb')


def safe_path(path: str) -> Path:
    p = Path(path).expanduser()
    if any(term in str(p).lower() for term in FORBIDDEN):
        raise ValueError(f'refusing sealed or test-set path: {p}')
    return p


def read_rows(path: Path) -> list[dict]:
    safe_path(str(path))
    rows = []
    with path.open(encoding='utf-8') as handle:
        for number, line in enumerate(handle):
            if line.strip():
                row = json.loads(line)
                messages = row['messages']
                if [item['role'] for item in messages] != ['system', 'user', 'assistant']:
                    raise ValueError('expected system, user, assistant row')
                user = messages[1]['content']
                # Arm D rows can open with a context block ("About this ...") before the transcript.
                start = 0 if user.startswith('Transcript: ') else user.find('\nTranscript: ') + 1
                if 'Transcript: ' not in user or set(json.loads(messages[2]['content'])) != {'text'}:
                    # The paragraph-marking task (Text/Output) and the older group rows ({text, new_paragraph}).
                    # GRPO trains the intent prompt the shipped 4B uses; these rewards score that answer shape.
                    continue
                if not user.endswith('\nOutput:') or not user.startswith('Transcript: ', start):
                    raise ValueError('unexpected user turn')
                reference = json.loads(messages[2]['content'])
                if set(reference) != {'text'} or not isinstance(reference['text'], str):
                    raise ValueError('unexpected assistant JSON')
                # The arm D file carries no ids; its line number is stable while the file is unchanged.
                rows.append({'id': row.get('id') or f'line-{number:05d}', 'messages': messages[:2],
                             'transcript': user[start + len('Transcript: '):-len('\nOutput:')],
                             'reference': reference['text']})
    return rows


def prompt_text(tokenizer, messages: list[dict]) -> str:
    try:
        return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
    except TypeError:
        return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)


def load_model(base: str, cpu: bool, train: bool):
    import torch
    from transformers import AutoTokenizer, BitsAndBytesConfig
    from train_cuda import model_class
    tokenizer = AutoTokenizer.from_pretrained(base, trust_remote_code=False)
    tokenizer.padding_side = 'left'
    if tokenizer.pad_token is None: tokenizer.pad_token = tokenizer.eos_token
    kwargs = {'dtype': torch.float32 if cpu else torch.bfloat16, 'trust_remote_code': False}
    if not cpu:
        kwargs['quantization_config'] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_quant_type='nf4', bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=torch.bfloat16)
        kwargs['device_map'] = 'auto'
    model = model_class(base).from_pretrained(base, **kwargs)
    model.config.use_cache = not train
    if train and not cpu:
        from peft import prepare_model_for_kbit_training
        model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
    return model, tokenizer


def select(rows: list[dict], model, tokenizer, threshold: float, seed: int, output: Path,
           max_new_tokens: int) -> None:
    import torch
    scored = []
    model.eval()
    for index, row in enumerate(rows, 1):
        prompt = prompt_text(tokenizer, row['messages'])
        encoded = tokenizer(prompt, return_tensors='pt').to(model.device)
        with torch.inference_mode():
            generated = model.generate(**encoded, do_sample=False, max_new_tokens=max_new_tokens,
                                       pad_token_id=tokenizer.pad_token_id)
        completion = tokenizer.decode(generated[0, encoded.input_ids.shape[1]:], skip_special_tokens=True)
        score = total_reward(reward_components(completion, row['transcript'], row['reference']))
        scored.append((row['id'], score))
        if index % 100 == 0: print(f'selected scan: {index}/{len(rows)}', flush=True)
    hard = [row_id for row_id, score in scored if score < threshold]
    random_ids = [row_id for row_id, score in scored if score >= threshold]
    random.Random(seed).shuffle(random_ids)
    chosen = set(hard + random_ids[:len(hard)])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'seed': seed, 'threshold': threshold, 'hard': len(hard),
                                  'random': min(len(hard), len(random_ids)), 'ids': sorted(chosen)}, indent=2))
    print(f'rows: hard={len(hard)} random={min(len(hard), len(random_ids))} total={len(chosen)}')
    if not chosen: raise RuntimeError('selection is empty; raise the threshold')


def train(rows: list[dict], model, tokenizer, cfg: dict, output: Path, cpu: bool, max_steps: int) -> None:
    import torch
    from datasets import Dataset
    from peft import LoraConfig
    from trl import GRPOConfig, GRPOTrainer
    from train_cuda import DEFAULT_TARGETS
    if not rows: raise ValueError('no selected rows')
    # An answer cut off at the completion cap fails the format reward for the whole group, so a row whose
    # reference cannot fit teaches nothing. Train only on rows that fit.
    limit = int(cfg.get('max_reference_tokens', 200))
    fits = [row for row in rows if len(tokenizer(json.dumps({'text': row['reference']}, ensure_ascii=False),
                                                 add_special_tokens=False)['input_ids']) <= limit]
    print(f'rows that fit {limit} answer tokens: {len(fits)} of {len(rows)}', flush=True)
    rows = fits
    if not rows: raise ValueError('no selected rows fit the answer limit')
    prompts = [prompt_text(tokenizer, row['messages']) for row in rows]
    dataset = Dataset.from_dict({'prompt': prompts, 'transcript': [r['transcript'] for r in rows],
                                 'reference': [r['reference'] for r in rows]})
    lengths = sorted(len(tokenizer(json.dumps({'text': row['reference']}, ensure_ascii=False),
                                   add_special_tokens=False)['input_ids']) for row in rows)
    cap = min(int(cfg.get('max_completion_length', 160)), max(24, math.ceil(lengths[-1] * 1.5)))
    output.mkdir(parents=True, exist_ok=True)
    log_file = output / 'reward-components.jsonl'
    call = 0
    trainer = None
    def reward_fn(completions, transcript, reference, **_kwargs):
        nonlocal call
        call += 1
        components = []
        for completion, source, target in zip(completions, transcript, reference):
            if isinstance(completion, list):
                completion = completion[0].get('content', '') if completion else ''
            components.append(reward_components(completion, source, target))
        with log_file.open('a', encoding='utf-8') as handle:
            handle.write(json.dumps({'step': trainer.state.global_step if trainer else 0, 'call': call, 'count': len(components),
                'mean': {name: sum(c[name] for c in components)/len(components) for name in WEIGHTS},
                'mean_total': sum(map(total_reward, components))/len(components)}) + '\n')
        return [total_reward(c) for c in components]
    rank = int(cfg.get('rank', 16))
    lora = LoraConfig(r=rank, lora_alpha=2*rank, lora_dropout=0.0,
                      target_modules=DEFAULT_TARGETS, bias='none', task_type='CAUSAL_LM')
    args = GRPOConfig(output_dir=str(output / 'checkpoints'), max_steps=max_steps,
        per_device_train_batch_size=1, gradient_accumulation_steps=int(cfg.get('gradient_accumulation_steps', 4)),
        num_generations=int(cfg.get('num_generations', 4)),  # TRL 1.15 has no max_prompt_length
        max_completion_length=cap, learning_rate=float(cfg.get('learning_rate', 5e-6)),
        beta=float(cfg.get('beta', 0.02)), gradient_checkpointing=True,
        gradient_checkpointing_kwargs={'use_reentrant': False}, bf16=not cpu, use_cpu=cpu,
        logging_steps=1, save_steps=50, save_total_limit=2, report_to='none', seed=int(cfg.get('seed', 7)),
        dataloader_num_workers=0)
    if args.beta <= 0: raise ValueError('beta must keep a KL reference')
    trainer = GRPOTrainer(model=model, args=args, reward_funcs=reward_fn, train_dataset=dataset,
                          processing_class=tokenizer, peft_config=lora)
    checkpoints = sorted((output/'checkpoints').glob('checkpoint-*'), key=lambda p: int(p.name.split('-')[-1]))
    trainer.train(resume_from_checkpoint=str(checkpoints[-1]) if checkpoints else None)
    trainer.model.save_pretrained(str(output/'adapter'))
    tokenizer.save_pretrained(str(output/'adapter'))
    print(f'peak allocated GiB: {torch.cuda.max_memory_allocated()/2**30:.2f}' if torch.cuda.is_available() else 'CPU dry run complete')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    parser.add_argument('--select', action='store_true')
    parser.add_argument('--cpu-dry-run', action='store_true')
    parser.add_argument('--tiny-model', help='local model directory for CPU dry run')
    parser.add_argument('--max-steps', type=int)
    args = parser.parse_args()
    import yaml
    cfg = yaml.safe_load(args.config.read_text())
    base = args.tiny_model if args.cpu_dry_run else str(Path(cfg['base_model']).expanduser())
    if args.cpu_dry_run and (not base or not Path(base).is_dir()):
        parser.error('--cpu-dry-run requires --tiny-model pointing to a local model directory')
    data = safe_path(cfg['data_dir'])
    output = safe_path(cfg['output_dir'])
    if args.select:
        rows = read_rows(data/'train.jsonl')
        model, tokenizer = load_model(base, args.cpu_dry_run, train=False)
        select(rows, model, tokenizer, float(cfg.get('selection_threshold', 3.0)),
               int(cfg.get('seed', 7)), output/'selection.json', int(cfg.get('selection_max_new_tokens', 160)))
    else:
        selection = json.loads((output/'selection.json').read_text())
        ids = set(selection['ids'])
        rows = [row for row in read_rows(data/'train.jsonl') if row['id'] in ids]
        model, tokenizer = load_model(base, args.cpu_dry_run, train=True)
        train(rows, model, tokenizer, cfg, output, args.cpu_dry_run,
              args.max_steps if args.max_steps is not None else int(cfg.get('max_steps', 100)))


if __name__ == '__main__':
    main()
