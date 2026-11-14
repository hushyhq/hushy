"""Tools data v2: generators for the gaps Run T1 measured (docs/product/FINETUNE.md "Tools data v2").

Added on top of v1 with their own random stream, so every v1 row (and its cached LLM calls) is
unchanged. Each generator targets one measured failure:

- `email_about`   — email phrased "about <topic>", "asking <question>", "a thank-you email to X for Y"
- `meeting_with`  — a meeting with people and a time but no calendar word ("set up a sync with …")
- `schedule_plain`— "schedule / book / set up a <event> <when>" (not a table, a cab or a flight)
- `list_simple`   — the list-item convention (below), plus watch/reading/wish lists
- `unsupported_v2`, `clarify_v2`, `sensitive_v2` — more refusal variety

**List-item convention** (one rule, applied everywhere): an item is one noun phrase as spoken.
With no separators in the transcript, a run of single common nouns is one item per word
("chicken rice and yogurt" → chicken · rice · yogurt); a multi-word item stays together only when
it is a lexical compound (a modifier plus its head: "paper towels", "olive oil") or a fixed
binomial ("salt and pepper", "mac and cheese"). The eval's tolerant matcher splits on "and" and
commas, so this is also the reading that scores.
"""

from __future__ import annotations

import random
from typing import Any

import banks
from positives import CORRECTION_CUES, Content, Draft, Slot, join_spoken, people, person, when_slot

ROLES = ["the property manager", "the contractor", "the school office", "my manager", "the vendor", "the insurance agent",
         "our accountant", "the tutor", "the travel agent", "the support team", "the finance team", "the hiring manager",
         "the leasing office", "coach", "the caterer", "the photographer", "the club secretary", "the course instructor"]

MEETINGS = ["sync", "call", "meeting", "catch up", "one on one", "lunch", "coffee", "review", "check in", "planning session",
            "working session", "standup", "brainstorm", "retro", "intro call", "demo", "walkthrough", "debrief", "dinner"]

STAPLES = ["eggs", "milk", "bread", "rice", "chicken", "yogurt", "butter", "cheese", "apples", "onions", "garlic", "tomatoes",
           "coffee", "tea", "sugar", "flour", "pasta", "lentils", "spinach", "carrots", "lemons", "oats", "honey", "cereal",
           "potatoes", "bananas", "grapes", "tofu", "paneer", "ghee", "cucumbers", "avocados", "salmon", "shampoo", "soap",
           "batteries", "napkins", "foil", "sponges", "detergent", "atta", "besan", "curd", "jaggery", "coriander"]
COMPOUNDS = ["paper towels", "olive oil", "dish soap", "toilet paper", "ice cream", "peanut butter", "baking soda",
             "hand soap", "trash bags", "almond milk", "brown rice", "green tea", "cat food", "light bulbs", "sparkling water",
             "frozen peas", "hot sauce", "maple syrup", "cotton swabs", "cling wrap"]
BINOMIALS = ["salt and pepper", "mac and cheese", "fish and chips", "bread and butter", "chips and salsa", "soap and water"]
MEDIA = {"watch": ["the new space documentary", "that heist movie", "the cooking show sanjay liked", "season two of the detective series"],
         "reading": ["the book about habits", "that essay on remote work", "the novel from book club", "the new cookbook"],
         "wish": ["a standing desk", "noise cancelling headphones", "a cast iron pan", "a bigger monitor"]}


def _names(rng: random.Random, ctx: dict[str, Any]) -> tuple[Slot, list[str]]:
    names = people(rng, ctx["locale"], 3)
    return Slot(join_spoken(names, rng)), names


def email_about(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    to = rng.choice(ROLES) if rng.random() < 0.45 else person(rng, ctx["locale"])
    r = Slot(to)
    roll = rng.random()
    if roll < 0.45:
        entry = c.draw("email")
        topic = entry.get("subject") if isinstance(entry, dict) and entry.get("subject") else "the invoice"
        body, b = topic, Slot(topic)
        form = rng.choice([["draft an email to", r, "about", b], ["write an email to", r, "about", b], ["send", r, "an email about", b],
                           ["email", r, "about", b], ["shoot", r, "a quick email about", b], ["compose a mail to", r, "regarding", b],
                           ["drop", r, "a mail about", b], ["write to", r, "by email about", b]])
    elif roll < 0.85:
        question = c.draw("email_ask")
        body, b = question, Slot(question)
        form = rng.choice([["write an email to", r, "asking", b], ["email", r, "asking", b], ["draft an email to", r, "to ask", b],
                           ["send", r, "an email asking", b], ["mail", r, "and ask", b], ["email", r, "to find out", b]])
    else:
        reason = rng.choice(["the interview today", "the quick turnaround", "hosting us last weekend", "the referral",
                             "covering my shift", "the detailed feedback", "the warm welcome"])
        body, b = f"thank you for {reason}", Slot(reason)
        form = rng.choice([["draft a thank you email to", r, "for", b], ["write a thank you email to", r, "for", b],
                           ["send", r, "a thank you email for", b]])
    return Draft(list(form), "propose_email_draft", {"to": [to], "body": body}, [])


def meeting_with(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    meeting = rng.choice(MEETINGS)
    a_slot, names = _names(rng, ctx)
    w, when, tags = when_slot(rng, ctx["locale"], need_time=True, correct=rng.random() < 0.08)
    # The title is copied as spoken, so the names in it are joined the way the speaker said them.
    title = f"{meeting} with {a_slot.spoken}"
    t = Slot(title)
    form = rng.choice([["set up a", t, w], ["book a", t, w], ["set a", t, w], ["arrange a", t, w], ["plan a", t, w],
                       ["schedule a", t, w], ["put in a", t, w], ["fix a", t, w], ["let's do a", t, w, "put it down"],
                       ["organise a", t, w], ["can you set up a", t, w]])
    return Draft(list(form), "create_event", {"title": title, "when": when, "attendees": names}, tags + ["attendees"])


def schedule_plain(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    title = c.draw("event")
    w, when, tags = when_slot(rng, ctx["locale"], need_time=rng.random() < 0.8)
    t = Slot(title)
    form = rng.choice([["schedule a", t, w], ["schedule", t, w], ["book", t, "for", w], ["set up", t, w], ["book a slot for", t, w],
                       ["pencil in", t, w], ["lock in", t, w], ["get", t, "on the books for", w]])
    return Draft(list(form), "create_event", {"title": title, "when": when}, tags + [])


def list_simple(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    if rng.random() < 0.2:
        kind = rng.choice(list(MEDIA))
        item = rng.choice(MEDIA[kind])
        form = rng.choice([["add", Slot(item), "to my", Slot(kind), "list"], ["put", Slot(item), "on my", Slot(kind), "list"],
                           ["save", Slot(item), "to the", Slot(kind), "list"]])
        return Draft(list(form), "add_to_list", {"items": [item], "list": kind}, [])
    count = rng.choices([2, 3, 4, 5], weights=[3, 4, 3, 1])[0]
    items = rng.sample(STAPLES, count)
    roll = rng.random()
    if roll < 0.3:
        items[rng.randrange(count)] = rng.choice(COMPOUNDS)
    elif roll < 0.45:
        items[rng.randrange(count)] = rng.choice(BINOMIALS)
    if any(" and " in i for i in items):
        # A binomial already carries "and": join the rest with spaces so the series stays readable.
        spoken = " ".join(items[:-1]) + " and " + items[-1] if " and " not in items[-1] else " ".join(items)
    else:
        spoken = join_spoken(items, rng)
    tags = ["list-items"]
    item_slot = Slot(spoken)
    if rng.random() < 0.1:
        wrong = rng.choice([s for s in STAPLES if s not in items])
        item_slot = Slot(f"{wrong} {rng.choice(CORRECTION_CUES)} {spoken}")
        tags.append("self-correction")
    lst = rng.choice(["groceries", "grocery", "shopping", "kirana", "costco", "target", "pantry", "weekend", "party"])
    form = rng.choice([["add", item_slot, "to", Slot(lst)], ["add", item_slot, "to my", Slot(lst), "list"],
                       ["put", item_slot, "on the", Slot(lst), "list"], ["we need", item_slot, "add them to", Slot(lst)],
                       ["add", item_slot, "to the", Slot(lst), "list please"], [Slot(lst), "list", item_slot]])
    return Draft(list(form), "add_to_list", {"items": items, "list": lst}, tags)


def unsupported_v2(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    name = person(rng, ctx["locale"])
    forms = [["accept the invite from", name], ["decline the", rng.choice(["team offsite invite", "friday meeting"])],
             ["rsvp yes to the party"], ["unsubscribe me from this newsletter"], ["archive all my read emails"],
             ["snooze this reminder for an hour"], ["summarize my inbox"], ["read that message out loud"],
             ["translate this page to spanish"], ["find the pdf", name, "sent me"], ["search my notes for the wifi details"],
             ["book a flight to", rng.choice(["chicago", "mumbai", "denver"]), rng.choice(["next friday", "tomorrow morning"])],
             ["reserve a table at the thai place for", rng.choice(["4", "two", "six"])], ["renew my netflix subscription"],
             ["top up my phone with 20 dollars"], ["pay", name, "back for dinner"], ["split the bill with", name],
             ["delete the", rng.choice(["standup reminder", "last event", "grocery list"])], ["clear my calendar for tomorrow"],
             ["move all my meetings to the afternoon"], ["change the dentist appointment to 4"], ["mute", name, "on slack"],
             ["leave the", rng.choice(["book club group", "design channel"])], ["block", name, "on whatsapp"],
             ["start recording this call"], ["join my next meeting"], ["turn on do not disturb"], ["set my status to away"]]
    return Draft(list(rng.choice(forms)), "no_action", {"reason": "unsupported"}, ["unsupported"])


def clarify_v2(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    name = person(rng, ctx["locale"])
    forms = [["send it to her"], ["email them the update"], ["remind me about it"], ["add those to the list"],
             ["put that on my calendar"], ["text him back"], ["message", name, "about it"], ["schedule it for next week"],
             ["book a meeting with", name], ["set up a call with the team"], ["invite them"], ["open the other one"],
             ["run it again"], ["make a list"], ["remind", name], ["set a timer for later"], ["save that"],
             ["add it to my", rng.choice(["work", "personal"]), "calendar"], ["email the team"], ["reply to", name],
             ["create a ticket for this"], ["note this down"]]
    return Draft(list(rng.choice(forms)), "no_action", {"reason": "needs_clarification"}, ["ambiguous"])


def sensitive_v2(rng: random.Random, c: Content, ctx: dict[str, Any]) -> Draft:
    name = person(rng, ctx["locale"])
    digits = "".join(rng.choice("0123456789") for _ in range(rng.choice([6, 8, 9])))
    secret = rng.choice([f"my passport number is k{digits}", f"the ifsc is sbin0{digits[:6]} and account {digits}",
                         f"my driving licence number is {digits}", f"the gate code is {digits[:4]}",
                         f"my medicare number is {digits}", f"the recovery code is {digits}", f"my pan number is abcde{digits[:4]}f"])
    forms = [["save a note", secret], ["text", name, secret], ["email", name, "saying", secret], ["remind me that", secret],
             ["add", secret, "to my list"], ["whatsapp", name, secret]]
    return Draft(list(rng.choice(forms)), "no_action", {"reason": "sensitive_content"}, ["sensitive"])


# Extra rows per generator (oversampled ×1.5 before filters, like v1), and the label each adds to.
GENERATORS_V2 = {
    "email_about": (email_about, 130), "meeting_with": (meeting_with, 150), "schedule_plain": (schedule_plain, 50),
    "list_simple": (list_simple, 130), "unsupported_v2": (unsupported_v2, 70), "clarify_v2": (clarify_v2, 60),
    "sensitive_v2": (sensitive_v2, 20),
}


def label_of(draft: Draft) -> str:
    return draft.args["reason"] if draft.tool == "no_action" else draft.tool
