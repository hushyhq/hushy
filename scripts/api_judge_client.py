"""Anthropic Messages API client (standard library only) and the price table for the API judge.

Read from Anthropic's documentation on 2026-10-08:
  endpoint and headers  POST https://api.anthropic.com/v1/messages with x-api-key, anthropic-version
                        2023-06-01 and content-type application/json
                        (platform.claude.com/docs/en/api/messages and .../api/errors)
  errors                400/401/402/403/404/413 are not retryable; 429 rate_limit_error carries
                        retry-after; 500, 504 and 529 overloaded_error are transient
                        (platform.claude.com/docs/en/api/errors, .../api/rate-limits)
  spend cap             a 429 with error.details.error_code "enforced_spend_limit_reached" has no
                        retry-after and keeps failing; a 400 "You have reached your specified API usage
                        limits" is the operator's own limit. Any 400 stops the whole run here.
  forced tool use       claude-opus-5-5 and claude-sonnet-5-5 reject tool_choice "any"/"tool" with a
                        400, so structured output goes through output_config.format (json_schema)
                        by default; --structured tool uses a strict tool with tool_choice auto there.
                        (platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools)
  usage                 input_tokens, output_tokens, cache_creation_input_tokens,
                        cache_read_input_tokens (pricing page examples). Thinking tokens are billed as
                        output and count toward max_tokens (build-with-claude/thinking).
  temperature           not supported on models after Opus 4.6, so it is never sent; run-to-run
                        repeatability comes from the cache, not from sampling.
"""

import http.client
import json
import math
import random
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

from api_judge_guard import GuardError, scrub

API_HOST = "api.anthropic.com"
API_PATH = "/v1/messages"
API_VERSION = "2023-06-01"
LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "[::1]", "::1")

# USD per million tokens. Source: https://platform.claude.com/docs/en/about-claude/pricing,
# "Model pricing" table and "Tool use pricing" table, read 2026-10-08. cache_write is the 5-minute
# write price, cache_read the hit price. Haiku 5.5 charges `long` rates when a request's prompt
# (including cache reads and writes) is over 100,000 tokens.
PRICES_AS_OF = "2026-10-08"
PRICES_SOURCE = "https://platform.claude.com/docs/en/about-claude/pricing"
PRICES = {
    "claude-opus-5-5": dict(input=4.0, output=20.0, cache_write=5.0, cache_read=0.20),
    "claude-sonnet-5-5": dict(input=2.0, output=10.0, cache_write=2.5, cache_read=0.10),
    "claude-haiku-5-5": dict(input=0.10, output=0.50, cache_write=0.125, cache_read=0.01,
                             long=dict(over=100_000, input=0.50, output=2.50,
                                       cache_write=0.625, cache_read=0.05)),
}
NO_FORCED_TOOL = ("claude-opus-5-5", "claude-sonnet-5-5")
TOOL_SYSTEM_TOKENS = 286  # added input tokens when any tool is present (pricing page, same date)
CHARS_PER_TOKEN = 3.0  # deliberately low: the 4.7+ tokenizer yields about 30% more tokens
INPUT_RESERVATION_MARGIN = 1.5  # extra input headroom for tokenizer and request overhead

# Prompt caching. Source: https://platform.claude.com/docs/en/build-with-claude/prompt-caching and the
# pricing page above, read 2026-10-11.
#   marker    "cache_control": {"type": "ephemeral"} on a content block. The prefix is built tools,
#             then system, then messages, so one marker on the last system block caches both.
#   minimum   a marked prefix shorter than the model's minimum is processed without caching and no
#             error is returned; both cache counts in `usage` are then 0.
#   lifetime  5 minutes, refreshed at no charge on every hit. Writing costs 1.25x input, reading 0.05x
#             on these models. (A 1-hour entry costs 2x input to write; nothing here asks for one.)
#   parallel  "a cache entry only becomes available after the first response begins", so calls that
#             start together each pay to write it.
#   usage     input_tokens counts only the tokens after the last marker; the three kinds never overlap.
CACHE_CONTROL = {"type": "ephemeral"}
CACHE_MIN_TOKENS = {"claude-opus-5-5": 512, "claude-sonnet-5-5": 512, "claude-haiku-5-5": 512}
CACHE_CAUTIOUS_CHARS_PER_TOKEN = 4.0  # CHARS_PER_TOKEN errs high, which is the unsafe side for a minimum
NO_PROMPT_CACHE_FLAG = "--no-prompt-cache"

RETRY_STATUSES = (429, 500, 502, 503, 504, 529)
BACKOFF_BASE_SECONDS = 2.0
BACKOFF_CAP_SECONDS = 60.0
RETRY_AFTER_CAP_SECONDS = 300.0
ERROR_TEXT_LIMIT = 300


class ApiError(Exception):
    """A call failed after its retries (or could not be retried)."""


class FatalApiError(ApiError):
    """The whole run must stop: bad key, no credit, spend limit, or a rejected request shape."""


def price_for(model):
    if model not in PRICES:
        raise GuardError(f"no price known for model {model!r}; add it to PRICES in "
                         f"scripts/api_judge_client.py (known: {', '.join(sorted(PRICES))})")
    return PRICES[model]


def _usage_tokens(usage):
    def field(name):
        value = usage.get(name) if isinstance(usage, dict) else None
        return value if type(value) is int and value >= 0 else 0
    return dict(input=field("input_tokens"), output=field("output_tokens"),
                cache_write=field("cache_creation_input_tokens"),
                cache_read=field("cache_read_input_tokens"))


def usage_cost(model, usage):
    """Dollars for one response's usage object."""
    tokens = _usage_tokens(usage)
    rates = price_for(model)
    prompt = tokens["input"] + tokens["cache_write"] + tokens["cache_read"]
    if "long" in rates and prompt > rates["long"]["over"]:
        rates = rates["long"]
    return sum(tokens[kind] * rates[kind] for kind in tokens) / 1_000_000


def estimate_input_tokens(body):
    text = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
    extra = TOOL_SYSTEM_TOKENS if "tools" in body else 0
    return int(len(text) / CHARS_PER_TOKEN) + extra + 1


def estimate_cost(model, body, output_tokens):
    """Dollars if the call uses `output_tokens` of output (pass max_tokens for the worst case)."""
    return usage_cost(model, dict(input_tokens=estimate_input_tokens(body),
                                  output_tokens=output_tokens))


def reservation_cost(model, body):
    """Reserve max output plus a buffered input estimate before sending a request.

    A request that carries a cache marker may be billed at the cache-write price, which is above the
    input price, so its whole input is reserved at that price.
    """
    input_tokens = math.ceil(estimate_input_tokens(body) * INPUT_RESERVATION_MARGIN)
    kind = "cache_creation_input_tokens" if has_cache_marker(body) else "input_tokens"
    return usage_cost(model, {kind: input_tokens, "output_tokens": body["max_tokens"]})


# ---- prompt caching ----------------------------------------------------------------------------

def add_prompt_cache_flag(parser):
    parser.add_argument(NO_PROMPT_CACHE_FLAG, dest="prompt_cache", action="store_false",
                        help="send the instruction without a prompt-cache marker (the marker is on by default)")


def prompt_cache_on(args):
    """On unless a command line turned it off; tools without the flag get the default."""
    return getattr(args, "prompt_cache", True)


def _marked(block):
    return {**block, "cache_control": dict(CACHE_CONTROL)}


def has_cache_marker(body):
    system, tools = body.get("system"), body.get("tools")
    blocks = (system if isinstance(system, list) else []) + (tools if isinstance(tools, list) else [])
    return any(isinstance(block, dict) and "cache_control" in block for block in blocks)


def with_cache_marker(body):
    """A copy of `body` whose stable prefix ends in one cache marker; `body` itself is not changed.

    The marker goes on the system text, which also covers any tool definitions (they come first in
    the prefix). With no system text it goes on the last tool. The on-disk result cache is keyed by
    the unmarked request, so this is applied only as a request is sent.
    """
    if has_cache_marker(body):
        return body
    system, tools = body.get("system"), body.get("tools")
    if isinstance(system, str) and system.strip():
        return {**body, "system": [_marked({"type": "text", "text": system})]}
    if isinstance(system, list) and system and isinstance(system[-1], dict):
        return {**body, "system": [*system[:-1], _marked(system[-1])]}
    if isinstance(tools, list) and tools and isinstance(tools[-1], dict):
        return {**body, "tools": [*tools[:-1], _marked(tools[-1])]}
    return body


def wire_body(body, prompt_cache=True):
    """The request as it is sent: marked for the prompt cache unless that is switched off."""
    return with_cache_marker(body) if prompt_cache else body


def cache_prefix_tokens(body):
    """(estimate, cautious estimate) of the cacheable prefix: tool definitions plus the system text.

    The first uses the cost estimator, which errs high; the second assumes fewer tokens per character
    and leaves out the tool-use overhead, so a prefix that clears a minimum on it very likely does.
    """
    prefix = {name: body[name] for name in ("tools", "system") if body.get(name)}
    if not prefix:
        return 0, 0
    raw = sum(len(part) if isinstance(part, str) else len(json.dumps(part, ensure_ascii=False, separators=(",", ":")))
              for part in prefix.values())
    return estimate_input_tokens(prefix), int(raw / CACHE_CAUTIOUS_CHARS_PER_TOKEN)


def cache_prefix_line(model, body, calls, prompt_cache=True):
    """One dry-run line: the prefix length against the model's documented minimum, and the saving."""
    estimate, cautious = cache_prefix_tokens(body)
    minimum = CACHE_MIN_TOKENS.get(model)
    size = f"prefix (tools + system) about {estimate} tokens by the cost estimator, {cautious} at a cautious " \
           f"{CACHE_CAUTIOUS_CHARS_PER_TOKEN:g} characters per token"
    if minimum is None:
        return f"  prompt cache: {size}; no documented minimum is recorded for {model}"
    if estimate < minimum:
        verdict = "below it, so a marker would do nothing"
    elif cautious < minimum:
        verdict = "borderline; only a paid call can tell (usage.cache_creation_input_tokens above 0)"
    else:
        verdict = "clears it"
    line = f"  prompt cache: {size}; the minimum for {model} is {minimum}: {verdict}"
    if not prompt_cache:
        return f"{line}; switched off ({NO_PROMPT_CACHE_FLAG})"
    if estimate < minimum or calls < 2:
        return line
    rates = price_for(model)
    saving = estimate * ((calls - 1) * (rates["input"] - rates["cache_read"])
                         - (rates["cache_write"] - rates["input"])) / 1_000_000
    return (f"{line}; over {calls} calls (one write, then reads within 5 minutes of each other) about "
            f"${saving:.2f} less than the estimate")


def cache_share(results):
    """Input tokens by kind over a run's results, and the share of all input that was read from cache."""
    def total(name):
        return sum((r.get("usage") or r).get(name, 0) for r in results)
    read, written, plain = total("cache_read_tokens"), total("cache_write_tokens"), total("input_tokens")
    everything = read + written + plain
    return {"cache_read_tokens": read, "cache_write_tokens": written, "input_tokens": everything,
            "cache_read_share": round(read / everything, 4) if everything else 0.0}


def cache_share_line(results):
    share = cache_share(results)
    return (f"prompt cache: {share['cache_read_tokens']} of {share['input_tokens']} input tokens read from cache "
            f"({share['cache_read_share']:.1%}), {share['cache_write_tokens']} written")


def base_url_parts(base_url):
    """(scheme, netloc) of a base URL the key may be sent to: the real API, or loopback for tests."""
    parts = urllib.parse.urlsplit(base_url)
    if parts.scheme == "https" and parts.hostname == API_HOST and not parts.port:
        return parts.scheme, parts.netloc
    if parts.scheme in ("http", "https") and parts.hostname in LOOPBACK_HOSTS:
        return parts.scheme, parts.netloc
    raise GuardError(f"refused --base-url {base_url!r}: the key is only sent to https://{API_HOST} "
                     "or to a loopback address")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a redirect would carry the key header to another host


def _error_fields(raw):
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
        error = payload["error"]
        details = error.get("details") if isinstance(error.get("details"), dict) else {}
        return str(error.get("type", "")), str(error.get("message", "")), str(details.get("error_code", ""))
    except (ValueError, KeyError, AttributeError, TypeError):
        return "", "", ""


class AnthropicClient:
    """One authenticated connection target. The key lives only in a private attribute."""

    def __init__(self, key, base_url=f"https://{API_HOST}", timeout=300.0, max_retries=5,
                 sleep=time.sleep):
        scheme, netloc = base_url_parts(base_url)
        self._key = key
        self._url = f"{scheme}://{netloc}{API_PATH}"
        self._timeout = timeout
        self._max_retries = max_retries
        self._sleep = sleep
        self._random = random.Random()
        handlers = [_NoRedirect()]
        if scheme == "http" or urllib.parse.urlsplit(base_url).hostname in LOOPBACK_HOSTS:
            handlers.append(urllib.request.ProxyHandler({}))
        self._opener = urllib.request.build_opener(*handlers)
        self.retries_used = 0

    def __repr__(self):
        return f"AnthropicClient({self._url!r}, key=<redacted>)"

    def _clean(self, text):
        return scrub(text, [self._key])[:ERROR_TEXT_LIMIT]

    def _post_once(self, body):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self._url, data=data, method="POST", headers={
            "x-api-key": self._key, "anthropic-version": API_VERSION,
            "content-type": "application/json"})
        with self._opener.open(request, timeout=self._timeout) as response:
            return json.loads(response.read().decode("utf-8")), response.headers.get("request-id", "")

    def _backoff(self, attempt, retry_after):
        delay = min(BACKOFF_CAP_SECONDS, BACKOFF_BASE_SECONDS * 2 ** attempt)
        delay *= 1 + 0.25 * self._random.random()
        if retry_after is not None:
            delay = max(delay, min(retry_after, RETRY_AFTER_CAP_SECONDS))
        self.retries_used += 1
        self._sleep(delay)

    def send(self, body):
        """(response JSON, request id). Retries rate limits, overload and network faults with backoff."""
        last = "no attempt made"
        for attempt in range(self._max_retries + 1):
            retry_after = None
            try:
                return self._post_once(body)
            except urllib.error.HTTPError as exc:
                kind, message, code = _error_fields(exc.read())
                last = self._clean(f"HTTP {exc.code} {kind}: {message}")
                if self._is_fatal(exc.code, kind, message, code):
                    raise FatalApiError(last) from None
                if exc.code not in RETRY_STATUSES:
                    raise ApiError(last) from None
                header = exc.headers.get("retry-after") if exc.headers else None
                retry_after = float(header) if header and header.replace(".", "", 1).isdigit() else None
            except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError,
                    http.client.HTTPException) as exc:
                last = self._clean(f"network error: {type(exc).__name__}")
            except (ValueError, UnicodeDecodeError):
                raise ApiError("response was not valid JSON") from None
            if attempt < self._max_retries:
                self._backoff(attempt, retry_after)
        raise ApiError(f"gave up after {self._max_retries} retries; last: {last}")

    @staticmethod
    def _is_fatal(status, kind, message, code):
        # A 400 is a rejected request shape or the operator's own spend limit; either way every
        # later call would fail the same way, so the run stops instead of repeating it.
        if status == 429:
            return code == "enforced_spend_limit_reached"
        return status in (400, 401, 402, 403, 404, 413)
