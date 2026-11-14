"""Positive tool calls: slot grammar → spoken command → label (docs/product/FINETUNE.md "Voice actions data v1").

Labels are written by code, never by an LLM: a generator samples slot values (from `banks.py` and
the LLM content banks), renders one of many spoken phrasings around them, and the label is the
slot values themselves — so every copied argument is, by construction, the speaker's own words.
An utterance is a list of segments: literal text (str) and `Slot`s. ASR shaping (`asr.py`) and
the LLM paraphrase stage only ever touch literal text, never a slot, so the label stays exact.

Self-corrections are slots too: the slot's spoken form carries both values ("at 3 no 4 pm"),
the label carries the corrected one ("at 4 pm").
"""

from __future__ import annotations

import random
import re
from dataclasses import dataclass, field
from typing import Any, Callable

import banks

CORRECTION_CUES = ["no", "no wait", "i mean", "sorry", "actually", "scratch that", "no no", "uh no", "or rather", "wait no"]


@dataclass
class Slot:
    spoken: str


@dataclass
class Draft:
    """One generated example before ASR shaping: segments, the call it means, tags."""

    segments: list[Any]
    tool: str
    args: dict[str, Any]
    tags: list[str] = field(default_factory=list)

    def text(self) -> str:
        return " ".join(s.spoken if isinstance(s, Slot) else s for s in self.segments if (s.spoken if isinstance(s, Slot) else s)).strip()


class Content:
    """The free-text banks (LLM-written, else `banks.FALLBACK`), drawn without much repetition."""

    def __init__(self, bank: dict[str, list[Any]], rng: random.Random) -> None:
        self.rng = rng
        self.bank = {k: list(v) for k, v in bank.items() if v}
        self.pos: dict[str, int] = {}

    def draw(self, kind: str) -> Any:
        items = self.bank.get(kind) or banks.FALLBACK.get(kind) or ["something"]
        index = self.pos.get(kind, 0)
        if index % len(items) == 0:
            self.rng.shuffle(items)
            self.bank[kind] = items
        self.pos[kind] = index + 1
        return items[index % len(items)]


def person(rng: random.Random, locale: str) -> str:
    roll = rng.random()
    if roll < 0.12:
        return rng.choice(banks.IN_FAMILY if locale == "en_IN" else banks.FAMILY)
    names = banks.IN_NAMES if (locale == "en_IN") == (rng.random() < 0.8) else banks.US_NAMES
    return rng.choice(names)


def people(rng: random.Random, locale: str, most: int = 3) -> list[str]:
    count = rng.choices([1, 2, 3], weights=[6, 3, 1])[0]
    out: list[str] = []
    while len(out) < min(count, most):
        name = rng.choice(banks.IN_NAMES if locale == "en_IN" and rng.random() < 0.8 else banks.US_NAMES)
        if name not in out:
            out.append(name)
    return out


def join_spoken(items: list[str], rng: random.Random) -> str:
    """Items as ASR writes a spoken series: no commas, usually "and" before the last."""
    if len(items) == 1:
        return items[0]
    return " ".join(items[:-1]) + (" " if rng.random() < 0.15 else " and ") + items[-1]


def when_slot(rng: random.Random, locale: str, need_time: bool = False, correct: bool = False) -> tuple[Slot, str, list[str]]:
    if correct:
        spoken, label = rng.choice([banks.corrected_time, lambda r: banks.corrected_day(r, locale)])(rng)
        if spoken.startswith("at ") and rng.random() < 0.7:
            day = rng.choice(["tomorrow", "friday", "on monday", "today", "next tuesday"])
            spoken, label = f"{day} {spoken}", f"{day} {label}"
        return Slot(spoken), label, ["self-correction"]
    phrase = banks.when_phrase(rng, locale, need_time=need_time)
    return Slot(phrase), phrase, []


def corrected_value(rng: random.Random, first: str, second: str, repeat: str = "") -> tuple[Slot, str]:
    cue = rng.choice(CORRECTION_CUES)
    return Slot(f"{first} {cue} {repeat + ' ' if repeat else ''}{second}".strip()), second


# -- per-tool generators ------------------------------------------------------------------------
# Each returns a Draft. `c` = Content, `ctx` = {"locale", "frontmostApp", …}.


def create_reminder(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    en_in = ctx["locale"] == "en_IN"
    title = c.draw("reminder")
    tags: list[str] = []
    args: dict[str, Any] = {}
    if rng.random() < 0.1:
        other = c.draw("reminder")
        t_slot, args["title"] = corrected_value(rng, other, title, repeat=rng.choice(["", "remind me to"]))
        tags.append("self-correction")
    else:
        t_slot, args["title"] = Slot(title), title
    w = None
    if rng.random() < 0.78:
        w, args["when"], more = when_slot(rng, ctx["locale"], correct=rng.random() < 0.1 and "self-correction" not in tags)
        tags += more
    lst = None
    if rng.random() < 0.1:
        lst = rng.choice(banks.LIST_NAMES)
        args["list"] = lst
    forms: list[list[Any]] = []
    if w:
        forms += [["remind me to", t_slot, w], ["remind me", w, "to", t_slot], [w, "remind me to", t_slot],
                  ["don't let me forget to", t_slot, w], ["set a reminder to", t_slot, w], ["set a reminder for", w, "to", t_slot],
                  ["add a reminder to", t_slot, w], ["reminder", t_slot, w], ["can you remind me to", t_slot, w],
                  ["i need a reminder to", t_slot, w], ["make a reminder to", t_slot, w], ["could you remind me", w, "to", t_slot],
                  ["remind me to", t_slot, w, "please"], ["hey remind me", w, "that i need to", t_slot],
                  ["ping me", w, "to", t_slot], ["nudge me", w, "to", t_slot], ["create a reminder", t_slot, w]]
        if en_in:
            forms += [["kindly remind me to", t_slot, w], ["please keep a reminder to", t_slot, w],
                      ["put a reminder for", w, "to", t_slot], ["remind me", w, "to", t_slot, "okay"]]
    else:
        forms += [["remind me to", t_slot], ["don't let me forget to", t_slot], ["set a reminder to", t_slot],
                  ["add a reminder to", t_slot], ["reminder to", t_slot], ["can you remind me to", t_slot],
                  ["make a reminder to", t_slot], ["new reminder", t_slot], ["i need to", t_slot, "remind me"]]
        if en_in:
            forms += [["kindly remind me to", t_slot], ["please keep a reminder to", t_slot]]
    form = list(rng.choice(forms))
    if lst:
        form += rng.choice([["in my", Slot(lst), "list"], ["on the", Slot(lst), "list"], ["add it to my", Slot(lst), "list"]])
    return Draft(form, "create_reminder", args, tags)


def create_event(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    en_in = ctx["locale"] == "en_IN"
    title = c.draw("event")
    tags: list[str] = []
    args: dict[str, Any] = {}
    attendees: list[str] = []
    if rng.random() < 0.18:
        attendees = people(rng, ctx["locale"], 2)
        title = f"{title} with {' and '.join(attendees)}"
        args["attendees"] = attendees
    args["title"] = title
    w, args["when"], more = when_slot(rng, ctx["locale"], need_time=rng.random() < 0.7, correct=rng.random() < 0.1)
    tags += more
    t = Slot(title)
    forms = [["add", t, w], ["add", t, "to my calendar", w], ["put", t, "on my calendar", w], ["schedule", t, w],
             ["create an event", t, w], ["block", w, "for", t], ["calendar", t, w], ["new event", t, w],
             ["add an event called", t, w], ["put", t, w, "on the calendar"], ["can you add", t, w],
             ["i have", t, w, "add it to my calendar"], ["put down", t, "for", w], ["mark", w, "for", t],
             ["add", t, "to the calendar for", w], ["save", t, w, "on my calendar"]]
    if en_in:
        forms += [["kindly add", t, "on my calendar", w], ["please block my calendar", w, "for", t], ["fix", t, w, "in my calendar"]]
    form = list(rng.choice(forms))
    extras = []
    if rng.random() < 0.15:
        spoken, minutes = banks.meeting_minutes(rng)
        args["duration_minutes"] = minutes
        extras.append(["for", spoken])
    if rng.random() < 0.15:
        loc = c.draw("location")
        args["location"] = loc
        extras.append([rng.choice(["at", "in"]), Slot(loc)])
    if rng.random() < 0.08:
        cal = rng.choice(banks.CALENDARS)
        args["calendar"] = cal
        extras.append([rng.choice(["on my", "to my", "on the"]), Slot(cal), "calendar"])
    rng.shuffle(extras)
    for extra in extras:
        form += extra
    return Draft(form, "create_event", args, tags + (["attendees"] if attendees else []))


def add_to_list(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    entry = c.draw("list_entry")
    if isinstance(entry, dict) and entry.get("list") and entry.get("items"):
        lst, pool = entry["list"], list(entry["items"])
    else:
        lst, pool = rng.choice(banks.LIST_NAMES), list(banks.FALLBACK["list_items"])
    count = min(len(pool), rng.choices([1, 2, 3, 4, 5], weights=[5, 4, 4, 2, 1])[0])
    items = rng.sample(pool, count)
    tags: list[str] = ["list-items"] if count > 1 else []
    if rng.random() < 0.08 and len(pool) > count:
        wrong = rng.choice([p for p in pool if p not in items])
        item_slot = Slot(f"{wrong} {rng.choice(CORRECTION_CUES)} {join_spoken(items, rng)}")
        tags.append("self-correction")
    else:
        item_slot = Slot(join_spoken(items, rng))
    list_slot = Slot(lst)
    if rng.random() < 0.06:
        other = rng.choice([x for x in banks.LIST_NAMES if x != lst])
        list_slot = Slot(f"{other} list {rng.choice(CORRECTION_CUES)} the {lst}")
        tags.append("self-correction")
    forms = [["add", item_slot, "to", list_slot], ["add", item_slot, "to my", list_slot, "list"],
             ["put", item_slot, "on the", list_slot, "list"], [list_slot, "list add", item_slot],
             ["add", item_slot, "to the", list_slot, "list"], ["can you add", item_slot, "to", list_slot],
             ["throw", item_slot, "on the", list_slot, "list"], ["add to my", list_slot, "list", item_slot],
             ["on my", list_slot, "list put", item_slot], ["we need", item_slot, "add it to the", list_slot, "list"],
             ["stick", item_slot, "on", list_slot], ["add", item_slot, "onto my", list_slot, "list"]]
    if ctx["locale"] == "en_IN":
        forms += [["kindly add", item_slot, "in my", list_slot, "list"], ["add", item_slot, "in", list_slot, "list"]]
    return Draft(list(rng.choice(forms)), "add_to_list", {"items": items, "list": lst}, tags)


def save_note(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    entry = c.draw("note")
    text, title = (entry.get("text"), entry.get("title")) if isinstance(entry, dict) else (entry, None)
    args: dict[str, Any] = {"text": text}
    t = Slot(text)
    if title and rng.random() < 0.25:
        args["title"] = title
        forms = [["create a note called", Slot(title), "saying", t], ["save a note titled", Slot(title), t],
                 ["new note", Slot(title), "that says", t], ["make a note called", Slot(title), "with", t]]
    else:
        forms = [["note to self", t], ["take a note", t], ["save a note", t], ["make a note that", t], ["jot down", t],
                 ["write this down", t], ["new note", t], ["add a note", t], ["save a note that", t], ["quick note", t],
                 ["can you note down", t], ["take a note that", t], ["note down that", t], ["save this as a note", t]]
        if ctx["locale"] == "en_IN":
            forms += [["please note down", t], ["kindly save a note that", t]]
    return Draft(list(rng.choice(forms)), "save_note", args, [])


def open_app(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    target = rng.choice(banks.WEBSITES) if rng.random() < 0.25 else rng.choice(banks.APPS)
    tags: list[str] = []
    slot = Slot(target)
    if rng.random() < 0.1:
        other = rng.choice([a for a in banks.APPS if a != target])
        slot = Slot(f"{other} {rng.choice(CORRECTION_CUES)} {target}")
        tags.append("self-correction")
    forms = [["open", slot], ["launch", slot], ["switch to", slot], ["bring up", slot], ["go to", slot], ["pull up", slot],
             ["can you open", slot], ["open up", slot], ["start", slot], ["fire up", slot], ["open", slot, "please"],
             ["take me to", slot], ["jump to", slot], ["show me", slot], ["get me", slot]]
    return Draft(list(rng.choice(forms)), "open_app", {"target": target}, tags)


def run_shortcut(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    name = c.draw("shortcut") if rng.random() < 0.5 else rng.choice(banks.SHORTCUTS)
    args: dict[str, Any] = {"name": name}
    tags: list[str] = []
    slot = Slot(name)
    if rng.random() < 0.08:
        other = rng.choice([s for s in banks.SHORTCUTS if s != name])
        slot = Slot(f"{other} {rng.choice(CORRECTION_CUES)} the {name}")
        tags.append("self-correction")
    forms = [["run my", slot, "shortcut"], ["run the", slot, "shortcut"], ["run shortcut", slot], ["run the shortcut called", slot],
             ["trigger", slot], ["trigger my", slot, "shortcut"], ["start the", slot, "shortcut"], ["do my", slot, "shortcut"],
             ["fire the", slot, "shortcut"], ["use my", slot, "shortcut"], ["shortcut", slot], ["kick off my", slot, "shortcut"],
             ["can you run", slot], ["run", slot]]
    form = list(rng.choice(forms))
    if rng.random() < 0.18:
        value = rng.choice(banks.SHORTCUT_INPUTS)
        args["input"] = value
        form += [rng.choice(["with", "on", "and pass it", "using"]), Slot(value)]
    return Draft(form, "run_shortcut", args, tags)


def set_timer(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    duration = banks.duration_phrase(rng)
    tags: list[str] = []
    slot = Slot(duration)
    if rng.random() < 0.12:
        other = banks.duration_phrase(rng)
        if other != duration:
            cue = rng.choice(["no", "no make it", "actually make it", "i mean", "uh no", "sorry"])
            slot = Slot(f"{other} {cue} {duration}")
            tags.append("self-correction")
    args: dict[str, Any] = {"duration": duration}
    label = c.draw("timer_label") if rng.random() < 0.35 else None
    forms = [["set a timer for", slot], ["start a timer for", slot], ["timer", slot], ["set timer for", slot],
             ["put a timer for", slot], ["timer for", slot], ["can you set a timer for", slot], ["count down", slot],
             ["i need a timer for", slot], ["set a timer", slot]]
    single = re.fullmatch(r"(\d+|[a-z]+) (minute|second|hour)s", duration)
    if single and not tags and rng.random() < 0.3:
        # "a 25 minute timer": the adjectival form is singular, and the label copies it.
        duration = f"{single.group(1)} {single.group(2)}"
        slot, args["duration"] = Slot(duration), duration
        forms = [["start a", slot, "timer"], ["give me a", slot, "timer"], ["set a", slot, "timer"], [slot, "timer"]]
    if ctx["locale"] == "en_IN":
        forms += [["keep a timer for", slot], ["put a timer of", slot], ["please set a timer for", slot]]
    form = list(rng.choice(forms))
    if label:
        args["label"] = label
        form += [rng.choice(["for", "for", "called", "labeled"]), Slot(label)]
    return Draft(form, "set_timer", args, tags)


def propose_email_draft(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    to = people(rng, ctx["locale"], 2) if rng.random() < 0.8 else [person(rng, ctx["locale"])]
    entry = c.draw("email")
    body, subject = (entry.get("body"), entry.get("subject")) if isinstance(entry, dict) else (entry, None)
    args: dict[str, Any] = {"to": to, "body": body}
    to_slot, b = Slot(" and ".join(to)), Slot(body)
    tags: list[str] = []
    if len(to) == 1 and rng.random() < 0.08:
        wrong = person(rng, ctx["locale"])
        if wrong != to[0]:
            to_slot = Slot(f"{wrong} {rng.choice(['no', 'i mean', 'sorry', 'actually'])} {to[0]}")
            tags.append("self-correction")
    if subject and rng.random() < 0.3:
        args["subject"] = subject
        forms = [["email", to_slot, "subject", Slot(subject), "body", b], ["send an email to", to_slot, "subject", Slot(subject), "saying", b],
                 ["draft an email to", to_slot, "with the subject", Slot(subject), "saying", b]]
    else:
        forms = [["email", to_slot, "saying", b], ["email", to_slot, "that", b], ["send an email to", to_slot, "saying", b],
                 ["draft an email to", to_slot, "saying", b], ["write an email to", to_slot, "that says", b],
                 ["send", to_slot, "an email saying", b], ["shoot", to_slot, "an email that", b], ["compose an email to", to_slot, b],
                 ["email", to_slot, "and tell them", b], ["draft a mail to", to_slot, "saying", b]]
        if ctx["locale"] == "en_IN":
            forms += [["drop a mail to", to_slot, "that", b], ["mail", to_slot, "that", b], ["kindly send a mail to", to_slot, "saying", b]]
    return Draft(list(rng.choice(forms)), "propose_email_draft", args, tags)


def propose_message(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    en_in = ctx["locale"] == "en_IN"
    recipient = rng.choice(banks.GROUPS) if rng.random() < 0.15 else person(rng, ctx["locale"])
    text = c.draw("message")
    front = ctx.get("frontmostApp")
    implied = banks.CHAT_APPS.get(front or "")
    tags: list[str] = []
    r_slot, m = Slot(recipient), Slot(text)
    if rng.random() < 0.08 and not recipient.startswith("the"):
        wrong = person(rng, ctx["locale"])
        if wrong != recipient:
            r_slot = Slot(f"{wrong} {rng.choice(['no', 'scratch that', 'i mean', 'actually'])} {recipient}")
            tags.append("self-correction")
    if implied and rng.random() < 0.45:
        channel = implied
        forms = [["message", r_slot, "saying", m], ["tell", r_slot, "that", m], ["reply to", r_slot, "saying", m],
                 ["send", r_slot, "a message saying", m], ["message", r_slot, "that", m], ["let", r_slot, "know that", m],
                 ["send a message to", r_slot, "saying", m], ["write to", r_slot, m]]
        if en_in:
            forms += [["revert to", r_slot, "that", m], ["drop a message to", r_slot, "saying", m]]
    else:
        channel = rng.choice(["slack", "slack", "imessage", "whatsapp", "whatsapp" if en_in else "imessage", "teams", "discord"])
        on = rng.choice(banks.MESSAGE_CHANNELS[channel])
        forms = [["message", r_slot, on, "saying", m], ["send", r_slot, "a message", on, "saying", m], ["tell", r_slot, on, "that", m],
                 ["reply to", r_slot, on, m], ["ping", r_slot, on, "that", m], ["message", r_slot, on, "that", m],
                 ["send a message to", r_slot, on, "saying", m], ["dm", r_slot, on, m]]
        forms += [[verb, r_slot, "that", m] for verb in banks.MESSAGE_VERBS[channel]]
        forms += [[verb, r_slot, m] for verb in banks.MESSAGE_VERBS[channel]]
        if en_in:
            forms += [["revert to", r_slot, on, "that", m], ["drop a message to", r_slot, on, "saying", m]]
    return Draft(list(rng.choice(forms)), "propose_message", {"channel": channel, "recipient": recipient, "text": text}, tags)


def propose_issue(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    entry = c.draw("issue")
    title, description = (entry.get("title"), entry.get("description")) if isinstance(entry, dict) else (entry, None)
    implied = banks.TRACKER_APPS.get(ctx.get("frontmostApp") or "")
    args: dict[str, Any] = {"title": title}
    t = Slot(title)
    tags: list[str] = []
    project = rng.choice(banks.PROJECTS) if rng.random() < 0.3 else None
    if implied and rng.random() < 0.5:
        tracker = implied
        forms = [["create an issue for", t], ["file a bug", t], ["new ticket", t], ["make an issue", t], ["log a bug for", t],
                 ["open a ticket for", t], ["create a ticket", t]]
        if project:
            forms = [["create an issue in", Slot(project), "for", t], ["file a bug under", Slot(project), t]]
    else:
        tracker = rng.choice(list(banks.TRACKERS))
        tr = rng.choice(banks.TRACKERS[tracker])
        forms = [[f"create a {tr} issue", t], [f"make a {tr} issue for", t], [f"file a {tr} issue", t], [f"log a bug in {tr}", t],
                 [f"open a ticket in {tr} for", t], [f"new {tr} ticket", t], [f"add a {tr} ticket for", t], [f"create a {tr} ticket", t]]
        if tracker in ("notion", "asana"):
            forms += [[f"add a {tr} task to", t], [f"create a {tr} task", t]]
        if project:
            forms = [[f"create a {tr} issue in", Slot(project), "for", t], [f"file a {tr} ticket in the", Slot(project), "project", t],
                     [f"new {tr} issue under", Slot(project), t]]
            if tracker == "github":
                forms += [["file a github issue on the", Slot(project), "repo", t]]
    if project:
        args["project"] = project
    args["tracker"] = tracker
    form = list(rng.choice(forms))
    if description and rng.random() < 0.3:
        args["description"] = description
        form += [rng.choice(["description", "details", "with the details", "and add that"]), Slot(description)]
    return Draft(form, "propose_issue", args, tags)


def propose_calendar_invite(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    entry = c.draw("meeting")
    title, notes = (entry.get("title"), entry.get("notes")) if isinstance(entry, dict) else (entry, None)
    attendees = people(rng, ctx["locale"], 3)
    w, when, tags = when_slot(rng, ctx["locale"], need_time=rng.random() < 0.8, correct=rng.random() < 0.08)
    args: dict[str, Any] = {"title": title, "when": when, "attendees": attendees}
    a, t = Slot(" and ".join(attendees)), Slot(title)
    forms = [["invite", a, "to", t, w], ["send an invite to", a, "for", t, w], ["send", a, "a calendar invite for", t, w],
             ["set up", t, "with", a, w, "and send the invite"], ["schedule", t, "with", a, w, "and invite them"],
             ["send a meeting invite to", a, "for", t, w], ["invite", a, "to a", t, w], ["book", t, "with", a, w, "send them an invite"],
             ["create a calendar invite for", t, w, "with", a], ["send an invite for", t, w, "to", a]]
    form = list(rng.choice(forms))
    if rng.random() < 0.15:
        spoken, minutes = banks.meeting_minutes(rng)
        args["duration_minutes"] = minutes
        form += ["for", spoken]
    if rng.random() < 0.12:
        loc = c.draw("location")
        args["location"] = loc
        form += [rng.choice(["at", "in"]), Slot(loc)]
    if notes and rng.random() < 0.15:
        args["notes"] = notes
        form += [rng.choice(["agenda", "notes", "to discuss"]), Slot(notes)]
    return Draft(form, "propose_calendar_invite", args, tags + ["attendees"])


GENERATORS: dict[str, Callable[[random.Random, Content, dict[str, Any]], Draft]] = {
    "create_reminder": create_reminder, "create_event": create_event, "add_to_list": add_to_list, "save_note": save_note,
    "open_app": open_app, "run_shortcut": run_shortcut, "set_timer": set_timer, "propose_email_draft": propose_email_draft,
    "propose_message": propose_message, "propose_issue": propose_issue, "propose_calendar_invite": propose_calendar_invite,
}

# Fragments that start one tool before the speaker switches to another ("open slack no wait …").
SWITCH_FRAGMENTS = ["remind me to", "open", "set a timer", "text", "add a note", "add", "email", "message", "create an event",
                    "run the", "invite", "put it on my calendar", "add it to the list"]


def cross_tool_correction(draft: Draft, rng: random.Random) -> Draft:
    """"<start of another command> <cue> <the real command>": the label is the real command."""
    cue = rng.choice(["no wait", "actually", "scratch that", "never mind", "sorry", "no no", "wait actually"])
    return Draft([rng.choice(SWITCH_FRAGMENTS), cue] + draft.segments, draft.tool, draft.args, draft.tags + ["self-correction", "tool-switch"])
