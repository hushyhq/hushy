"""Reads AMI and ICSI NXT corpora into speaker turns built from dialogue acts, and resolves the
corpora's own summary links (abstractive sentence -> supporting dialogue acts) to verbatim text.

Turn rule: dialogue acts sorted by start time; consecutive acts of one speaker with less than
TURN_GAP seconds between them are one turn. The quote for a record is the text of one linked
dialogue act, so it is always a substring of exactly one turn.
"""
import html
import re
from dataclasses import dataclass, field
from pathlib import Path

from common import Turn

TURN_GAP = 1.5
ID_ATTR = re.compile(r'<(\w+) nite:id="([^"]+)"')
WORD = re.compile(r'<w nite:id="([^"]+)"([^>]*)>([^<]*)</w>')
START = re.compile(r'starttime="([\d.]*)"')
END = re.compile(r'endtime="([\d.]*)"')
CLASS = re.compile(r' c="([^"]*)"')
RANGE = re.compile(r'([\w.]+\.xml)#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?')
SENTENCE = re.compile(r'<sentence nite:id="([^"]+)"[^>]*>(.*?)</sentence>', re.S)
SECTION = re.compile(r'<(abstract|actions|decisions|problems|progress) [^>]*>(.*?)</\1>', re.S)

AMI_ROLES = {"PM": "Project Manager", "ME": "Marketing Expert", "UI": "User Interface Designer", "ID": "Industrial Designer"}


@dataclass
class Act:
    act_id: str
    speaker: str
    start: float
    end: float
    text: str


@dataclass
class Meeting:
    meeting_id: str
    speakers: list
    turns: list
    act_turn: dict = field(default_factory=dict)  # act id -> (turn index, text)
    words: int = 0
    uncovered_words: int = 0


def read(path: Path) -> str:
    return path.read_text(encoding="latin-1")


def join(tokens: list) -> str:
    out = ""
    for token, punc in tokens:
        out += token if punc or not out else " " + token
    return out


def word_table(path: Path, icsi: bool) -> tuple:
    """(ordered element ids, {word id: (start, token, is_punctuation)})."""
    text = read(path)
    order = [m.group(2) for m in ID_ATTR.finditer(text)]
    words = {}
    for wid, attrs, token in WORD.findall(text):
        start = START.search(attrs)
        cls = CLASS.search(attrs)
        punc = ('punc="true"' in attrs) or (icsi and cls is not None and cls.group(1) not in ("W", "WS"))
        words[wid] = (float(start.group(1)) if start and start.group(1) else None, html.unescape(token).strip(), punc)
    return order, words


def expand(order_index: dict, order: list, first: str, last: str | None) -> list:
    a = order_index.get(first)
    b = order_index.get(last) if last else a
    if a is None or b is None or b < a:
        return []
    return order[a:b + 1]


def acts_of(path: Path, speaker_of, word_tables: dict, orders: dict, icsi: bool) -> list:
    """Dialogue acts of one channel file as Act objects."""
    text = read(path)
    out = []
    tag = "dialogueact" if icsi else "dact"
    for m in re.finditer(rf'<{tag} nite:id="([^"]+)"([^>]*)>(.*?)</{tag}>', text, re.S):
        act_id, attrs, body = m.groups()
        tokens, start, end = [], None, None
        for fname, a, b in RANGE.findall(body):
            key = fname.replace(".xml", "")
            if key not in word_tables:
                continue
            index = orders[key + "#index"]
            for wid in expand(index, orders[key], a, b or None):
                w = word_tables[key].get(wid)
                if not w:
                    continue
                t, token, punc = w
                if not punc and not token:
                    continue
                if tokens == [] and punc:
                    continue
                tokens.append((token, punc))
                if t is not None and not punc:
                    start = t if start is None else min(start, t)
                    end = t if end is None else max(end, t)
        body_text = join(tokens)
        if not body_text or start is None:
            continue
        speaker = speaker_of(act_id, attrs)
        out.append(Act(act_id, speaker, start, end, body_text))
    return out


def build_turns(acts: list) -> tuple:
    acts = sorted(acts, key=lambda a: (a.start, a.end))
    turns, act_turn, last_end = [], {}, {}
    for act in acts:
        prev = turns[-1] if turns else None
        if prev and prev.speaker == act.speaker and act.start - last_end[act.speaker] < TURN_GAP:
            prev.text += " " + act.text
        else:
            turns.append(Turn(act.speaker, act.start, act.text))
        last_end[act.speaker] = max(act.end, last_end.get(act.speaker, 0.0))
        act_turn[act.act_id] = (len(turns) - 1, act.text)
    return turns, act_turn


def load_ami(root: Path, meeting: str, roles: dict) -> Meeting:
    word_tables, orders, acts = {}, {}, []
    for agent in roles:
        path = root / f"words/{meeting}.{agent}.words.xml"
        if not path.exists():
            continue
        key = f"{meeting}.{agent}.words"
        order, words = word_table(path, icsi=False)
        word_tables[key], orders[key], orders[key + "#index"] = words, order, {w: i for i, w in enumerate(order)}
    for agent in roles:
        path = root / f"dialogueActs/{meeting}.{agent}.dialog-act.xml"
        if path.exists():
            label = AMI_ROLES.get(roles[agent], roles[agent])
            acts += acts_of(path, lambda _id, _attrs, label=label: label, word_tables, orders, icsi=False)
    turns, act_turn = build_turns(acts)
    total = sum(1 for w in (x for t in word_tables.values() for x in t.values()) if not w[2])
    covered = sum(len(t.text.split()) for t in turns)
    return Meeting(meeting, sorted({AMI_ROLES.get(r, r) for r in roles.values()}), turns, act_turn, total, max(0, total - covered))


def load_icsi(root: Path, meeting: str) -> Meeting:
    word_tables, orders, acts = {}, {}, []
    for path in sorted((root / "Words").glob(f"{meeting}.*.words.xml")):
        key = path.name.replace(".xml", "")
        order, words = word_table(path, icsi=True)
        word_tables[key], orders[key], orders[key + "#index"] = words, order, {w: i for i, w in enumerate(order)}
    codes = {}
    for path in sorted((root / "DialogueActs").glob(f"{meeting}.*.dialogue-acts.xml")):
        raw = acts_of(path, lambda _id, attrs: re.search(r'participant="([^"]*)"', attrs).group(1) if re.search(r'participant="([^"]*)"', attrs) else "?", word_tables, orders, icsi=True)
        acts += raw
    for act in sorted(acts, key=lambda a: a.start):
        codes.setdefault(act.speaker, f"Speaker {len(codes) + 1}")
    for act in acts:
        act.speaker = codes[act.speaker]
    turns, act_turn = build_turns(acts)
    total = sum(1 for w in (x for t in word_tables.values() for x in t.values()) if not w[2])
    covered = sum(len(t.text.split()) for t in turns)
    return Meeting(meeting, sorted(codes.values(), key=lambda s: int(s.split()[1])), turns, act_turn, total, max(0, total - covered))


def summary_sentences(path: Path) -> dict:
    """{sentence id: (section, text)} from an abstractive summary file."""
    out = {}
    text = read(path)
    for section, body in SECTION.findall(text):
        for sid, sentence in SENTENCE.findall(body):
            sentence = html.unescape(re.sub(r"\s+", " ", sentence)).strip()
            if sentence and sentence != "*NA*":
                out[sid] = (section, sentence)
    return out


def summary_links(path: Path) -> dict:
    """{abstractive sentence id: [dialogue act ids]} from a summlink file."""
    text = read(path)
    links = {}
    for block in re.finditer(r"<summlink .*?</summlink>", text, re.S):
        ext = re.search(r'role="extractive"\s+href="[^#]+#id\(([^)]+)\)"', block.group(0))
        abstract = re.search(r'role="abstractive"\s+href="[^#]+#id\(([^)]+)\)"', block.group(0))
        if ext and abstract:
            links.setdefault(abstract.group(1), []).append(ext.group(1))
    return links
