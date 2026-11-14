"""Tests for the commercial-only licence filter.

    cd scripts/finetune && python3 -m unittest discover -s tests
"""
from __future__ import annotations

import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import licence_filter  # noqa: E402

SOURCES = {
    "ami": {"licence": "CC-BY-4.0", "commercial_safe": True, "attribution": "AMI Meeting Corpus, CC BY 4.0"},
    "gyafc": {"licence": "Yahoo research-only", "commercial_safe": False},
}


def rows(*items: dict) -> list[str]:
    return [json.dumps(item) + "\n" for item in items]


class LicenceFilterTests(unittest.TestCase):
    def test_keeps_and_tags_only_commercial_safe_sources(self) -> None:
        out = io.StringIO()
        report = licence_filter.run(SOURCES, rows(
            {"id": "a", "source": "ami", "text": "invented"},
            {"id": "b", "source": "gyafc", "text": "invented"},
            {"id": "c", "source": "unknown", "text": "invented"},
            {"id": "d", "text": "invented"},
        ), out)
        kept = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([row["id"] for row in kept], ["a"])
        self.assertEqual(kept[0]["licence"], "CC-BY-4.0")
        self.assertTrue(kept[0]["commercial_safe"])
        self.assertEqual(report["kept"], {"ami": 1})
        reasons = {(d["source"], d["reason"]) for d in report["dropped"]}
        self.assertEqual(reasons, {("gyafc", "not commercial-safe"), ("unknown", "source not listed"),
                                   ("<none>", "no source field")})
        self.assertEqual(report["attributions"], ["AMI Meeting Corpus, CC BY 4.0"])

    def test_a_row_cannot_claim_its_own_licence(self) -> None:
        out = io.StringIO()
        licence_filter.run(SOURCES, rows({"id": "x", "source": "gyafc", "commercial_safe": True}), out)
        self.assertEqual(out.getvalue(), "")

    def test_source_table_must_say_licence_and_commercial_use(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sources.json"
            path.write_text(json.dumps({"sources": {"ami": {"licence": "CC-BY-4.0"}}}))
            with self.assertRaises(ValueError):
                licence_filter.load_sources(path)


if __name__ == "__main__":
    unittest.main()
