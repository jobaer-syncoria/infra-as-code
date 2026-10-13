#!/usr/bin/env python3
"""Maintenance windows must not overlap (ADR-08 3.8, ADR-11 3.8): the pgbackup hour, the WAL-G base backup and the
patch window (there is no DO database maintenance window). Reads config/windows.yml, which does not exist until
HI-08-10 is answered; a missing file passes with a note. Format:
  windows:
    pgbackup:    {day: daily, start: "02:00", minutes: 60}
    walg_base:   {day: sun,   start: "03:00", minutes: 120}
    patch:       {day: wed,   start: "04:00", minutes: 120}
Days are daily or mon..sun; times are UTC. Usage: ci/check_windows.py [root]"""
import itertools, os, sys

import yaml

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
p = os.path.join(root, "config", "windows.yml")
if not os.path.exists(p):
    print("windows: config/windows.yml not present yet (HI-08-10 pending): nothing to check"); sys.exit(0)
DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
w = (yaml.safe_load(open(p, encoding="utf-8")) or {}).get("windows") or {}
spans = {}
for name, v in w.items():
    h, m = (int(x) for x in str(v["start"]).split(":"))
    days = DAYS if v["day"] == "daily" else [v["day"]]
    for d in days:
        s = DAYS.index(d) * 1440 + h * 60 + m
        spans.setdefault(name, []).append((s, s + int(v["minutes"])))
WEEK = 7 * 1440
bad = []
for (a, sa), (b, sb) in itertools.combinations(spans.items(), 2):
    for x0, x1 in sa:
        for y0, y1 in sb:
            for off in (-WEEK, 0, WEEK):
                if x0 < y1 + off and y0 + off < x1:
                    bad.append(f"windows {a} and {b} overlap")
for b in sorted(set(bad)):
    print("FAIL:", b)
print(f"windows: {len(spans)} window(s) checked, {len(set(bad))} overlap(s)")
sys.exit(1 if bad else 0)
