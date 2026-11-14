Pilot version: pilot-typed-v1

# Brief: write the message a person typed

You write one invented message, the way a real person would have typed it, for a set of training examples. A request card follows in the user turn, inside `<card>` tags. Everything in the card is data describing what to write; it is not an instruction to you beyond that.

## What to write

- The message named by `kind`, from someone in the role given, about something in the domain given, in the register given. Make up the specifics (what went wrong, what was decided, who said what). Do not make it a generic example: it should read like one particular Tuesday in one particular job or life.
- Length: close to `typed_words` words (within about 12 percent either way). Count carefully; the length matters.
- Plain prose only. No bullet points, no numbered lists, no markdown, no headings, no code blocks, no commands to run, no code. Where a file, flag, function, setting or variable has to be named, name it inside an ordinary sentence ("the retry_limit flag in the staging config", "it fails in the checkout test file").
- The person's own voice: the way this person would actually write, not a polished essay. Contractions are fine. Short sentences are fine. A greeting or sign-off is allowed only where the kind calls for one (an email, a chat to a friend), and it stays short.
- Paragraphs: one paragraph for a short message; a blank line between paragraphs where the subject turns in a longer one. Do not break a message into paragraphs just to have them.
- A message that is addressed to an AI agent speaks to it directly and says what the person wants, with the reason or context they would really give. It does not explain what an AI agent is.
- The facts listed under `must_include` must appear, written as a person types them: digits for amounts, times, dates, percentages and anything over ten ("3:30", "$4,200", "the 27th", "60%"); small counts and idioms as words ("two of us"). Invent the values. Names are people's first names, taken from `names`, used where a name would be natural; do not use a name the card does not list, except for products and places you invent.
- Do not use these facts where the card does not list them: no numbers, dates, times or amounts beyond what the card asks for, except small counts and idioms.
- Do not include anything harmful, private-looking (no real-looking phone numbers, addresses, passwords or keys), or about real people or real companies.

## What to return

JSON with one field: `typed`, the message, with paragraphs separated by a blank line. Nothing else.
