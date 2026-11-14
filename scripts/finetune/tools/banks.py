"""Deterministic slot banks for the voice-actions data (docs/product/FINETUNE.md "Voice actions data v1").

Everything here is written by hand for this dataset — names, apps, date and duration phrases, list
and Shortcut names — so the labels never depend on an LLM. Free-text content (reminder titles,
message bodies, issue titles, …) comes from the LLM banks (`tool_llm.py`), with the small
fallbacks at the bottom used only when a bank is empty (tests, offline runs).

Date phrases are written the way Parakeet's lowercased, unpunctuated output reads ("at 3 30 pm",
"tomorrow at 9"): the model copies the phrase, `DateAnchor` computes the date, and
`murmur-eval finetune tools-check` drops any phrase `DateAnchor` can't resolve.
"""

from __future__ import annotations

US_NAMES = """
sarah mike jessica chris ashley josh emily matt amanda ryan megan tyler lauren kevin rachel brandon
nicole justin hannah dylan olivia ethan chloe noah madison logan grace jacob abby caleb natalie
marcus jamal keisha andre tanya darnell maria jose carlos sofia diego lucia miguel elena luis
camila wei ming jenny kevin kim linh thanh hana kenji yuki min seo jun ben dana jordan casey
taylor morgan riley avery quinn jamie alex sam pat drew blake reese
""".split()

IN_NAMES = """
priya rahul ananya arjun kavya rohan sneha vikram divya aditya pooja karthik meera siddharth neha
rajesh lakshmi suresh deepa manish shreya varun nikhil aishwarya harish anjali ravi swati ganesh
sunita prakash kiran naveen isha tanvi yash aarav vivek sanjay rekha mohan geeta farhan ayesha
imran zoya harpreet gurpreet simran manpreet
""".split()

FAMILY = ["mom", "dad", "my mom", "my dad", "grandma", "my sister", "my brother", "my wife", "my husband",
          "amma", "appa", "mummy", "papa", "my boss", "the landlord", "the babysitter"]
IN_FAMILY = ["amma", "appa", "mummy", "papa", "bhaiya", "didi", "nani", "dadi", "chacha"]

GROUPS = ["the cousins group", "the design team", "the marketing channel", "the dev channel", "the book club",
          "the roommates group", "the soccer parents", "the ops channel", "the release channel", "the college group",
          "the building group", "hash general", "hash random", "hash frontend", "the hiking crew", "the pto channel"]

APPS = """
slack; notion; figma; spotify; safari; google chrome; chrome; firefox; xcode; terminal; finder; mail;
messages; calendar; reminders; notes; system settings; photos; music; zoom; microsoft teams; teams;
microsoft word; excel; powerpoint; keynote; pages; numbers; preview; visual studio code; vs code;
cursor; linear; obsidian; whatsapp; discord; telegram; 1password; activity monitor; app store;
arc; brave; postman; docker desktop; github desktop; iterm; warp; raycast; things; todoist; trello;
asana; jira; bear; craft; logic pro; final cut pro; garageband; imovie; quicktime; facetime;
maps; weather; clock; calculator; textedit; screenshot; books; podcasts; tv; news; stocks
""".replace("\n", " ").split(";")
APPS = [a.strip() for a in APPS if a.strip()]

WEBSITES = ["gmail dot com", "amazon dot com", "linkedin dot com", "reddit dot com", "wikipedia dot org",
            "nytimes dot com", "espn dot com", "netflix dot com", "hacker news", "the hdfc netbanking site", "flipkart",
            "the jira board", "our company wiki", "the aws console", "stack overflow", "google sheets",
            "google calendar", "google drive", "the bank website", "zillow", "airbnb dot com", "the swiggy website",
            "weather dot com", "the school portal", "figma dot com", "the vercel dashboard"]

LIST_NAMES = ["groceries", "grocery", "shopping", "costco", "target", "lumber yard", "packing", "chores",
              "work", "errands", "books to read", "movies", "gift ideas", "sprint", "home depot",
              "trader joe's", "weekend", "house", "garden", "pharmacy", "party", "camping", "kitchen",
              "wedding", "office supplies", "birthday", "school supplies", "baby", "vacation", "reading"]

CALENDARS = ["work", "personal", "family", "home", "school", "kids", "team", "side project", "fitness"]

SHORTCUTS = ["start focus", "good night", "arrive home", "meeting mode", "do not disturb on", "log workout",
             "open work apps", "dark mode toggle", "save to reading list", "log caffeine", "timesheet",
             "new project folder", "clipboard to note", "convert to pdf", "time tracker", "gratitude log",
             "screen time report", "start stream", "log expense", "bedtime", "wake up", "summarize clipboard",
             "compress video", "back up notes", "daily journal", "log mood", "weekly review", "gym check in",
             "parking spot", "quick capture", "focus music", "evening wind down", "batch rename", "log sleep"]
SHORTCUT_INPUTS = ["12 dollars coffee", "two glasses", "thirty minute run", "feeling great", "the quarterly report",
                   "bonjour mes amis", "18 dollars for parking", "grocery run", "project apollo", "q3 kickoff",
                   "level 3 near the elevator", "slept badly", "hola a todos", "240 rupees auto fare"]

MESSAGE_CHANNELS = {
    "slack": ["on slack", "in slack", "via slack"],
    "imessage": ["on imessage", "on messages", "by text"],
    "whatsapp": ["on whatsapp", "in whatsapp", "over whatsapp"],
    "teams": ["on teams", "in teams", "on microsoft teams"],
    "discord": ["on discord", "in discord"],
}
MESSAGE_VERBS = {  # verb that names its own channel
    "slack": ["slack"], "imessage": ["text"], "whatsapp": ["whatsapp"], "teams": [], "discord": [],
}
CHAT_APPS = {"Slack": "slack", "Messages": "imessage", "WhatsApp": "whatsapp", "Microsoft Teams": "teams", "Discord": "discord"}

TRACKERS = {
    "linear": ["linear"], "jira": ["jira"], "github": ["github"], "notion": ["notion"], "asana": ["asana"],
}
TRACKER_APPS = {"Linear": "linear", "Jira": "jira", "Notion": "notion", "Asana": "asana", "GitHub Desktop": "github"}
PROJECTS = ["web app", "checkout", "onboarding", "infra", "platform", "growth", "ios", "android", "design system",
            "billing", "search", "api", "docs", "data", "marketing site", "admin", "backend", "sre", "q4 launch",
            "partner portal", "desktop"]

FRONT_APPS_OTHER = ["Safari", "Google Chrome", "Xcode", "Cursor", "Notes", "Mail", "Notion", "Figma", "Terminal",
                    "Zoom", "Finder", "Calendar", "Microsoft Word", "Google Docs", "Visual Studio Code"]

US_ZONES = ["America/Los_Angeles", "America/New_York", "America/Chicago", "America/Denver"]
IN_ZONE = "Asia/Kolkata"

# -- dates ----------------------------------------------------------------------------------------

WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
          "october", "november", "december"]
HOURS = ["7", "8", "9", "10", "11", "12", "1", "2", "3", "4", "5", "6"]
HOUR_WORDS = ["seven", "eight", "nine", "ten", "eleven", "twelve", "one", "two", "three", "four", "five", "six"]


def _meridiem(hour: str, rng) -> str:  # noqa: ANN001
    """am/pm the way people use it: 7–11 mostly am, 12–6 mostly pm."""
    morning = hour in ("7", "8", "9", "10", "11", "seven", "eight", "nine", "ten", "eleven")
    if hour in ("12", "twelve"):
        return "pm"
    return ("am" if morning else "pm") if rng.random() < 0.9 else ("pm" if morning else "am")


def clock_times(rng) -> str:  # noqa: ANN001
    """One spoken clock time as Parakeet writes it (digits mostly; "3 30"; words sometimes)."""
    roll = rng.random()
    hour = rng.choice(HOURS)
    if roll < 0.45:
        return f"{hour} {_meridiem(hour, rng)}"
    if roll < 0.65:
        return hour
    if roll < 0.8:
        return f"{hour} {rng.choice(['15', '30', '45'])}" + rng.choice(["", f" {_meridiem(hour, rng)}"])
    if roll < 0.9:
        return rng.choice(HOUR_WORDS)
    return rng.choice(["noon", "midnight", f"{rng.choice(HOUR_WORDS)} o'clock", f"half past {rng.choice(HOUR_WORDS)}",
                       f"quarter to {rng.choice(HOURS)}", f"{rng.choice(['7', '8', '9', '10'])} in the morning",
                       f"{rng.choice(['4', '5', '6', '7'])} in the evening"])


def day_phrase(rng, locale: str) -> str:  # noqa: ANN001
    roll = rng.random()
    if roll < 0.25:
        return rng.choice(["tomorrow", "today", "tonight", "tomorrow morning", "tomorrow evening", "this evening",
                           "this afternoon", "tomorrow afternoon", "tomorrow night"])
    if roll < 0.5:
        return rng.choice(["", "on ", "this ", "next "]) + rng.choice(WEEKDAYS)
    if roll < 0.62:
        return rng.choice(["day after tomorrow", "the day after tomorrow", "next week", "this weekend",
                           "end of the week", "monday morning", "friday afternoon"])
    if roll < 0.8:
        month = rng.choice(MONTHS)
        day = rng.randint(1, 28)
        suffix = "th" if 11 <= day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")
        if locale == "en_IN" and rng.random() < 0.5:
            return rng.choice([f"{day}{suffix} {month}", f"on {day}{suffix} {month}", f"{day} {month}"])
        return rng.choice([f"{month} {day}{suffix}", f"on {month} {day}", f"{month} {day}"])
    if roll < 0.9:
        day = rng.randint(2, 28)
        suffix = "th" if 11 <= day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(day % 10, "th")
        return f"on the {day}{suffix}"
    return rng.choice(["in 20 minutes", "in an hour", "in 2 hours", "in 30 minutes", "in 3 days", "in two weeks",
                       "in 10 minutes", "in 45 minutes", "in a week"])


def when_phrase(rng, locale: str, need_time: bool = False) -> str:  # noqa: ANN001
    """A spoken date/time phrase (the `when` value is exactly this text)."""
    day = day_phrase(rng, locale)
    # "in 20 minutes" and "tomorrow evening" already say when; a clock time would contradict them.
    if day.startswith("in ") or day.endswith(("morning", "afternoon", "evening", "night", "tonight", "week", "weekend")):
        return day
    if need_time or rng.random() < 0.6:
        time = clock_times(rng)
        if rng.random() < 0.2:
            return f"at {time} {day}".replace("  ", " ")
        return f"{day} at {time}"
    return day


def corrected_time(rng) -> tuple[str, str]:  # noqa: ANN001
    """(spoken, corrected) for a time the speaker fixes mid-phrase: "at 3 no 4 pm" → "at 4 pm"."""
    start = rng.randrange(len(HOURS) - 1)
    first, second = HOURS[start], HOURS[start + rng.choice([1, 1, 2]) if start + 2 < len(HOURS) else start + 1]
    if rng.random() < 0.5:
        first, second = second, first
    ampm = rng.choice(["", f" {_meridiem(second, rng)}"])
    cue = rng.choice(["no", "no wait", "i mean", "sorry", "actually", "uh no", "no make it", "make that", "or rather"])
    return f"at {first} {cue} {second}{ampm}", f"at {second}{ampm}"


def corrected_day(rng, locale: str) -> tuple[str, str]:  # noqa: ANN001
    first, second = rng.sample(["tomorrow", "friday", "monday", "thursday", "wednesday", "saturday", "tuesday", "sunday"], 2)
    time = clock_times(rng)
    cue = rng.choice(["no", "no wait", "i mean", "sorry", "actually", "scratch that"])
    return f"{first} {cue} {second} at {time}", f"{second} at {time}"


# -- durations ------------------------------------------------------------------------------------

def duration_phrase(rng) -> str:  # noqa: ANN001
    roll = rng.random()
    if roll < 0.55:
        return f"{rng.choice([1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 15, 18, 20, 25, 30, 35, 40, 45, 50, 55, 60, 90])} minutes"
    if roll < 0.7:
        return rng.choice(["an hour", "one hour", "two hours", "an hour and a half", "half an hour", "1 hour",
                           "2 hours", "3 hours", "a minute", "one minute"])
    if roll < 0.82:
        return f"{rng.choice([10, 15, 20, 30, 45, 60, 90])} seconds"
    if roll < 0.92:
        return f"{rng.choice(['five', 'ten', 'fifteen', 'twenty', 'thirty', 'forty five', 'three', 'two'])} minutes"
    return rng.choice(["1 hour 30 minutes", "2 minutes 30 seconds", "an hour and 15 minutes", "one and a half hours",
                       "a minute and a half"])


def meeting_minutes(rng) -> tuple[str, int]:  # noqa: ANN001
    minutes = rng.choice([15, 20, 30, 45, 60, 90, 120])
    spoken = {60: rng.choice(["an hour", "one hour", "60 minutes"]), 90: rng.choice(["an hour and a half", "90 minutes"]),
              120: rng.choice(["two hours", "2 hours"])}.get(minutes, f"{minutes} minutes")
    return spoken, minutes


# -- fallbacks (only when an LLM bank is empty) --------------------------------------------------

FALLBACK = {
    "reminder": ["renew the car registration", "pick up the dry cleaning", "pay the water bill", "book the vet for luna",
                 "send the invoice to the client", "water the ferns", "buy a birthday card", "drop off the donation bags"],
    "event": ["team lunch", "sprint planning", "school open house", "yoga class", "quarterly review", "haircut"],
    "location": ["conference room b", "the blue bottle on 3rd street", "the downtown office", "city hall"],
    "note": ["the cabin wifi is slow in the evenings", "idea for the newsletter lead with a customer story"],
    "message": ["stuck in traffic be there soon", "can you review my pr when you get a chance", "dinner is at 7 tonight"],
    "email_body": ["please send over the signed contract by thursday", "thanks for the call today here are the notes"],
    "email_subject": ["contract", "follow up", "invoice"],
    "issue": ["checkout button misaligned on mobile", "export to csv drops the header row"],
    "timer_label": ["the pasta", "the oven", "stretch break", "the cookies"],
    "meeting": ["mockup walkthrough", "one on one", "roadmap sync", "budget check in"],
    "list_items": ["eggs", "oat milk", "sourdough", "napkins", "coffee beans", "bananas", "dish soap", "batteries"],
}
