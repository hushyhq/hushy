#!/usr/bin/env python3
"""Choosing which groups (meetings, series, single rows) are held out of training.

A group's fate depends only on (seed, source name, group id): each group gets a fixed position
in [0, 1) from a hash of those three, and is held when its position is below the fraction. So the
held set does not move when rows are filtered, labels change, or other groups come and go. Two
corrections keep the split usable: a source with two or more groups always holds at least one
(the lowest position), and never all of them (the highest position stays in training)."""

import hashlib


def position(seed, name, group):
    """A stable number in [0, 1) for one group of one source under one seed."""
    digest = hashlib.sha256(f"{seed}\x1f{name}\x1f{group}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / 2 ** 64


def held_groups(groups, seed, name, fraction):
    """The groups of source `name` to hold out. Empty when there are fewer than two groups."""
    ranked = sorted(set(groups), key=lambda group: (position(seed, name, group), group))
    if len(ranked) < 2:
        return set()
    held = [group for group in ranked if position(seed, name, group) < fraction]
    if not held:
        held = ranked[:1]
    if len(held) == len(ranked):
        held = ranked[:-1]
    return set(held)
