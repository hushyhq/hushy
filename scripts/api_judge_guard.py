"""Path and key guards for the Anthropic API judge (scripts/api_judge.py).

Two jobs, both fail closed:

1. Every file the judge reads or writes must pass the repository's existing guards
   (`finetune/pathguard.py`: heldout, Voice Lab, the app's own data directory, external benchmarks;
   `sealed_guard.py`: sealed file names and sealed byte hashes) plus a "sealed" name check, and must
   sit inside the repository's `Evals/` folder or a scratch folder the operator names explicitly.
2. The API key is read from one file, only when a call is about to be made, and only if its
   permissions are 600 or tighter. The key is never returned in a message; `scrub` removes it from any
   text before that text is printed, logged or stored.
"""

import os
from pathlib import Path
import stat
import sys

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE / "finetune"))

import pathguard  # noqa: E402
from sealed_guard import SealedEvalRefusal, assert_tuning_safe  # noqa: E402

ROOT = _HERE.parent
EVALS = ROOT / "Evals"
DEFAULT_KEY_FILE = "~/.config/hushy/anthropic_api_key"
EXTRA_FORBIDDEN = ("sealed",)  # pathguard has no "sealed" pattern; llm-judge.py refuses it by name
MAX_KEY_BYTES = 4096


class GuardError(Exception):
    """A path or key file was refused. The message never contains key material."""


def _candidates(path):
    raw = os.fspath(path)
    return {raw.lower(), os.path.abspath(raw).lower(), os.path.realpath(raw).lower()}


def refuse_forbidden_name(path):
    """Raises GuardError when `path` (as given or resolved) matches a forbidden pattern."""
    pattern = pathguard.violation(path)
    if pattern is None:
        pattern = next((word for word in EXTRA_FORBIDDEN
                        if any(word in candidate for candidate in _candidates(path))), None)
    if pattern is not None:
        raise GuardError(f"refused path {os.fspath(path)!r}: matches forbidden pattern {pattern!r}")


def scratch_roots(directories):
    """Validates the operator's explicit scratch folders; returns their resolved paths."""
    home = Path.home().resolve()
    roots = []
    for directory in directories or ():
        refuse_forbidden_name(directory)
        resolved = Path(directory).expanduser().resolve()
        if not resolved.is_dir():
            raise GuardError(f"scratch folder does not exist: {directory}")
        if resolved == home or resolved in home.parents:
            raise GuardError(f"refused scratch folder {directory}: it contains the home directory")
        for private in (home / ".config", home / "Library"):
            if resolved == private or private in resolved.parents:
                raise GuardError(f"refused scratch folder {directory}: private directory")
        roots.append(resolved)
    return roots


def _inside_allowed(resolved, scratch):
    return any(resolved == root or root in resolved.parents for root in [EVALS.resolve(), *scratch])


def check_path(path, scratch, role):
    """Any file the tool touches: forbidden names refused, then confined to Evals/ or a scratch folder."""
    refuse_forbidden_name(path)
    resolved = Path(path).expanduser().resolve()
    if not _inside_allowed(resolved, scratch):
        raise GuardError(f"refused {role} {path!r}: outside the repository Evals/ folder and "
                         "every --scratch-dir")
    refuse_forbidden_name(resolved)
    return resolved


def safe_input(path, scratch):
    """A file whose text may reach the API: guarded by name, location and sealed-set hash."""
    resolved = check_path(path, scratch, "input")
    if not resolved.is_file():
        raise GuardError(f"input file does not exist: {path}")
    try:
        assert_tuning_safe(resolved, purpose="the API judge")
    except SealedEvalRefusal as refusal:
        raise GuardError(str(refusal)) from refusal
    return resolved


def safe_output(path, scratch):
    return check_path(path, scratch, "output")


def load_key(path=DEFAULT_KEY_FILE):
    """The API key, or GuardError. Messages name the file and its mode, never its contents."""
    key_path = Path(path).expanduser()
    try:
        descriptor = os.open(key_path, os.O_RDONLY)
    except OSError as exc:
        raise GuardError(f"API key file {key_path} cannot be opened ({exc.strerror}); create it "
                         "with the key on one line and run: chmod 600 " + str(key_path)) from None
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise GuardError(f"API key file {key_path} is not a regular file")
        if info.st_mode & 0o177:
            raise GuardError(f"API key file {key_path} has permissions {stat.S_IMODE(info.st_mode):04o}, "
                             f"looser than 600; run: chmod 600 {key_path}")
        if info.st_uid != os.getuid():
            raise GuardError(f"API key file {key_path} is not owned by the current user")
        raw = handle.read(MAX_KEY_BYTES + 1)
    try:
        key = raw.decode("ascii").strip()
    except UnicodeDecodeError:
        key = ""
    if not key or len(raw) > MAX_KEY_BYTES or any(c.isspace() or not c.isprintable() for c in key):
        raise GuardError(f"API key file {key_path} must hold one printable key on a single line")
    return key


def scrub(text, secrets):
    """`text` with every secret replaced, so error text can be shown or stored safely."""
    text = str(text)
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[redacted]")
    return text
