"""Pure, text-only rewards for the cleanup GRPO trial. No training rows or phrase lists."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import json
import re
import unicodedata

NUMBER_WORDS = dict(zip(
    'zero one two three four five six seven eight nine ten eleven twelve fifteen twenty thirty sixty hundred okay'.split(),
    '0 1 2 3 4 5 6 7 8 9 10 11 12 15 20 30 60 100 ok'.split(),
))
WEIGHTS = {'format': 0.5, 'similarity': 4.0, 'facts': 0.4, 'retracted': 0.3, 'length': 0.3}


def normalized_words(text: str) -> list[str]:
    """EvalMetrics.normalizedWords: lowercase, split punctuation, map its number words."""
    chunks = re.split(r"[^\w']+", text.lower().replace('’', "'"), flags=re.UNICODE)
    return [NUMBER_WORDS.get(w, w) for chunk in chunks if (w := chunk.strip("'"))]


def keys(text: str) -> list[str]:
    return [''.join(c for c in word if c.isalnum()) for word in normalized_words(text)]


def _distance(a: str, b: str) -> int:
    rows = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1): rows[i][0] = i
    for j in range(len(b) + 1): rows[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            rows[i][j] = min(rows[i-1][j] + 1, rows[i][j-1] + 1, rows[i-1][j-1] + (a[i-1] != b[j-1]))
            if i > 1 and j > 1 and a[i-1] == b[j-2] and a[i-2] == b[j-1]:
                rows[i][j] = min(rows[i][j], rows[i-2][j-2] + 1)
    return rows[-1][-1]


def _inflection(x: str, y: str) -> bool:
    stem, other = sorted((x, y), key=len)
    if len(stem) < 2 or not other.startswith(stem[:-1]): return False
    if other.startswith(stem) and other[len(stem):] in {'s','es','ed','d','ing','er','ers','ly','est'}: return True
    if other.startswith(stem + stem[-1]) and other[len(stem)+1:] in {'ed','ing','er','ers'}: return True
    rest = other[len(stem)-1:]
    return (stem.endswith('e') and rest in {'ing','er','ers'}) or (stem.endswith('y') and rest in {'ies','ied','ier','iest','ily'})


def _near(a: str, b: str) -> bool:
    if a == b or _inflection(a, b): return True
    short, long = sorted((a, b), key=len)
    return (len(short) >= 4 and not long.startswith(short) and short not in long
            and _distance(a, b) <= max(1, len(long) // 4))


def _same(a: str, b: str) -> bool:
    return a == b or (bool(a) and bool(b) and a[0] == b[0] and _near(a, b))

def _contracts(whole: str, head: str, tail: str) -> bool:
    if len(whole) <= len(head) or not whole.startswith(head) or whole[-1] != tail[-1]: return False
    rest = tail
    for letter in whole[len(head):]:
        pos = rest.find(letter)
        if pos < 0: return False
        rest = rest[pos+1:]
    return True


@dataclass(frozen=True)
class RewriteAccount:
    words: int
    letters: int
    in_order: int
    in_order_letters: int
    elsewhere: int
    elsewhere_letters: int

    @property
    def added(self) -> int: return self.words - self.in_order - self.elsewhere

    @property
    def added_letters(self) -> int: return self.letters - self.in_order_letters - self.elsewhere_letters

    @property
    def is_rewrite(self) -> bool:
        return 6 * self.added_letters + self.elsewhere_letters <= 2 * self.in_order_letters


def rewrite_account(text: str, source: str) -> RewriteAccount:
    """Port of RewriteAccount.measure without its optional `also` source."""
    answer, ordered = keys(text), keys(source)
    pool = set(ordered)
    joined = {''.join(ordered[i:j]) for i in range(len(ordered)) for j in range(i+2, min(i+4, len(ordered))+1)}
    source_pairs = list(zip(ordered, ordered[1:]))
    def present(i: int) -> bool:
        word = answer[i]
        if word in joined or any(_near(word, candidate) for candidate in pool): return True
        if any(_contracts(word, a, b) for a, b in source_pairs): return True
        for a, b in ((answer[i-1], word) if i else ('', ''), (word, answer[i+1]) if i+1 < len(answer) else ('', '')):
            if a and b and (a+b in pool or any(_contracts(source_word, a, b) for source_word in pool)): return True
        return False
    present_weights = [len(word) for i, word in enumerate(answer) if present(i)]
    # Swift's Score orders by letters, then word count. Its three match types are one-to-one,
    # one answer word to two source words, and two answer words to one source word.
    previous = [(0, 0)] * (len(ordered)+1)
    earlier = previous[:]
    for i, word in enumerate(answer, 1):
        current = [(0, 0)] * (len(ordered)+1)
        for j, source_word in enumerate(ordered, 1):
            best = max(previous[j], current[j-1])
            if _same(word, source_word): best = max(best, (previous[j-1][0]+len(word), previous[j-1][1]+1))
            if j > 1 and (ordered[j-2]+source_word == word or _contracts(word, ordered[j-2], source_word)):
                best = max(best, (previous[j-2][0]+len(word), previous[j-2][1]+1))
            if i > 1 and (answer[i-2]+word == source_word or _contracts(source_word, answer[i-2], word)):
                best = max(best, (earlier[j-1][0]+len(answer[i-2])+len(word), earlier[j-1][1]+2))
            current[j] = best
        earlier, previous = previous, current
    kept_letters, kept_words = previous[-1]
    total_present = sum(present_weights)
    return RewriteAccount(len(answer), sum(map(len, answer)), min(kept_words, len(present_weights)),
                          min(kept_letters, total_present), max(0, len(present_weights)-kept_words),
                          max(0, total_present-kept_letters))


def parse_completion(completion: str) -> str | None:
    try:
        value = json.loads(completion.strip())
    except (ValueError, TypeError):
        return None
    return value['text'] if isinstance(value, dict) and set(value) == {'text'} and isinstance(value['text'], str) else None


def _similarity(reference: str, text: str) -> float:
    a, b = normalized_words(reference), normalized_words(text)
    if not a: return float(not b)
    previous = list(range(len(b)+1))
    for i, word in enumerate(a, 1):
        current = [i]
        for j, other in enumerate(b, 1):
            current.append(min(current[-1]+1, previous[j]+1, previous[j-1]+(word != other)))
        previous = current
    return max(0.0, 1 - previous[-1] / max(len(a), len(b), 1))


def _fact_tokens(reference: str) -> Counter[str]:
    raw = re.findall(r"[\w']+", reference, flags=re.UNICODE)
    result: Counter[str] = Counter()
    for word in raw:
        normalized = normalized_words(word)
        if not normalized: continue
        token = normalized[0]
        unusual = len(token) >= 9  # shape only; no vocabulary list
        capitalized = word[0].isupper() and not (len(raw) > 1 and word == raw[0])
        number = any(c.isdigit() for c in word)
        if unusual or capitalized or number: result[token] += 1
    return result


def reward_components(completion: str, transcript: str, reference: str) -> dict[str, float]:
    text = parse_completion(completion)
    if text is None:
        return {name: 0.0 for name in WEIGHTS}
    if not rewrite_account(text, transcript).is_rewrite:
        return {name: 0.0 for name in WEIGHTS}
    output = Counter(normalized_words(text))
    facts = _fact_tokens(reference)
    missing = sum((facts - output).values())
    source, target = Counter(normalized_words(transcript)), Counter(normalized_words(reference))
    retracted = source - target
    retained = sum((retracted & output).values())
    target_length = len(normalized_words(reference))
    excess = max(0, len(normalized_words(text)) - max(target_length + 2, round(1.5 * target_length)))
    return {'format': 1.0, 'similarity': _similarity(reference, text),
            'facts': -min(1.0, missing / max(1, sum(facts.values()))),
            'retracted': -min(1.0, retained / max(1, sum(retracted.values()))),
            'length': -min(1.0, excess / max(1, target_length))}


def total_reward(components: dict[str, float]) -> float:
    return sum(WEIGHTS[name] * value for name, value in components.items())
