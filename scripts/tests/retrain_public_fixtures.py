"""Invented fixtures shared by the public retrain tests. No corpus text."""

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import retrain_public_rows as rows  # noqa: E402


CLEAN_PROOF = {"pathsChecked": 7, "forbiddenPathsTouched": 0}
HEX = set("0123456789abcdef")


def read_jsonl(path):
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def make_base(root, proof=CLEAN_PROOF, extra_train=(), extra_valid=()):
    """An invented base folder laid out like the real one: <set>/mlx with the manifest one level up."""
    base = root / "set" / "mlx"
    base.mkdir(parents=True)
    row = rows.messages("Invented system rule", "Map the blue lantern", "Map the blue lantern.")
    rows.write_rows(base / "train.jsonl", [row, *extra_train])
    # Spaced JSON plus an extra key: a rewrite (rather than a copy) would change these bytes.
    (base / "valid.jsonl").write_text("".join(json.dumps(item) + "\n" for item in ({**row, "note": "kept"}, *extra_valid)),
                                      encoding="utf-8")
    if proof is not None:
        (root / "set" / "manifest.json").write_text(json.dumps({"heldoutProof": proof}), encoding="utf-8")
    return base


def lantern_source(root, meetings=3):
    """Two invented rows per meeting, labelled."""
    count = meetings * 2
    cases = [{"id": f"id{i}", "spoken": f"the amber lantern turns near tower {i}",
              "meeting": f"meeting{i // 2}", "series": f"series{i // 4}", "licence": "CC BY 4.0"}
             for i in range(count)]
    labels = [{"id": f"id{i}", "text": f"The amber lantern turns near tower {i}."} for i in range(count)]
    rows.write_rows(root / "cases", cases)
    rows.write_rows(root / "labels", labels)
    return ("lanterns", root / "cases", root / "labels")


def tower_ids(path):
    contents = [row["messages"][1]["content"] for row in read_jsonl(path)]
    return {int(content.split("tower ")[1].split("\n")[0]) for content in contents if "amber" in content}


def benchmark_files(root):
    """Invented text laid out like the two benchmarks, in folders named like them."""
    qa = root / "disfl-qa" / "dev.json"
    speech = root / "disfluencyspeech" / "rows.jsonl"
    qa.parent.mkdir()
    speech.parent.mkdir()
    qa.write_text(json.dumps({"q1": {"original": "Where does the quartz heron nest?",
                                     "disfluent": "Where does the, uh no, where does the quartz heron nest?"},
                              "q2": {"original": "THE AMBER LANTERN turns near tower 0!", "disfluent": ""}}))
    # Written directly: the guard refuses these folders to every ordinary reader and writer.
    speech.write_text("".join(json.dumps(row) + "\n" for row in (
        {"text": "The amber lantern turns near tower 3."}, {"spoken": "a velvet anvil"},
        {"reference": "A velvet anvil."}, {"transcript": "seven paper kites", "words": 3})))
    return qa, speech
