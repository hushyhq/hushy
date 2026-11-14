#!/usr/bin/env python3
"""Render the tiny, authored ASR regression fixture set with macOS `say`.

This set checks product vocabulary and ordinary dictation behavior. Samantha TTS audio is
regression material, not evidence about spontaneous speech, accents, or production latency.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sealed_guard import SealedEvalRefusal, assert_tuning_safe

SAMPLE_RATE = 16_000
VOICE = "Samantha"


def silence(path: Path, seconds: float = 1.5) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(bytes(int(SAMPLE_RATE * seconds) * 2))


def render(source: Path, output: Path, dry_run: bool = False, voice: str = VOICE) -> Path:
    assert_tuning_safe(str(source), purpose="paired ASR synthetic fixture renderer")
    cases = json.loads(source.read_text(encoding="utf-8"))
    clips_in = cases.get("clips")
    if cases.get("schema_version") != 1 or not isinstance(clips_in, list) or not clips_in:
        raise ValueError("input cases must use schema_version 1 and contain non-empty clips")
    ids = [item.get("id") for item in clips_in]
    if any(not isinstance(item, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", item) for item in ids) or len(set(ids)) != len(ids):
        raise ValueError("clip IDs must be unique filename-safe letters, numbers, underscore, or hyphen")
    output = output.resolve()
    if source.resolve() == output / "cases-with-audio.json":
        raise ValueError("output must not overwrite the input cases file")
    if not dry_run:
        output.mkdir(parents=True, exist_ok=True)
    clips = []
    for clip in cases["clips"]:
        clip = dict(clip)
        clip_id = clip["id"]
        audio = output / f"{clip_id}.wav" if clip.get("category") == "silence" else output / f"{clip_id}.aiff"
        if clip.get("category") == "silence":
            if not dry_run:
                silence(audio)
        else:
            text = clip.get("spoken_text", "").strip()
            if not text:
                raise ValueError(f"{clip_id} needs spoken_text")
            command = ["/usr/bin/say", "-v", voice, "-o", str(audio), "--", text]
            if dry_run:
                print("DRY RUN:", json.dumps(command))
            else:
                subprocess.run(command, check=True)
        clip["audio_path"] = str(audio.resolve())
        clips.append(clip)
    destination = output / "cases-with-audio.json"
    if not dry_run:
        destination.write_text(json.dumps({"schema_version": 1, "clips": clips}, indent=2) + "\n", encoding="utf-8")
    print(f"{'Would write' if dry_run else 'Wrote'} {destination}")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=Path("Evals/asr-paired-dev.json"))
    parser.add_argument("--out-dir", type=Path, default=Path("Evals/data/asr-paired-synthetic"))
    parser.add_argument("--voice", default=VOICE, help="macOS say voice (default: Samantha)")
    parser.add_argument("--dry-run", action="store_true", help="show planned TTS calls without writing files or running say")
    args = parser.parse_args()
    render(args.cases, args.out_dir, args.dry_run, args.voice)


if __name__ == "__main__":
    main()
