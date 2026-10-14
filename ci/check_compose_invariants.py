#!/usr/bin/env python3
"""Deploy-command invariants (runbook PI.2 item 3, ADR-04 C-04-05 in part): no project-wide `docker compose up -d`
(it would recreate every service, the database included) and no literal `-t <n>` / `--timeout <n>` stop timeout
(use the named STOP_GRACE / CCD symbols). Scans scripts/, ansible/, compose/, nginx/, cloud-init/ and docs/runbooks/.
Passes on an empty tree. Usage: ci/check_compose_invariants.py [root]"""
import os, re, shlex, sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
SCAN = ["scripts", "ansible", "compose", "nginx", "cloud-init", os.path.join("docs", "runbooks")]
SKIP_NAMES = {"check-versions", "README.md"}
bad, n = [], 0
for top in SCAN:
    for d, dirs, files in os.walk(os.path.join(root, top)):
        dirs[:] = [x for x in dirs if x not in {".git", "tests"}]
        for f in files:
            if f in SKIP_NAMES:
                continue
            p = os.path.join(d, f)
            try:
                lines = open(p, encoding="utf-8").read().splitlines()
            except (OSError, UnicodeDecodeError):
                continue
            for i, line in enumerate(lines, 1):
                s = line.strip()
                if s.startswith("#"):
                    continue
                for seg in re.split(r"\|\||&&|;|\|", s):
                    if not re.search(r"\bdocker[ -]compose\b", seg):
                        continue
                    n += 1
                    try:
                        toks = shlex.split(seg, comments=True)
                    except ValueError:
                        toks = seg.split()
                    if "up" in toks:
                        after = toks[toks.index("up") + 1:]
                        words = [t for t in after if not t.startswith("-") and not re.fullmatch(r"\d+", t)]
                        if not words:
                            bad.append(f"{os.path.relpath(p, root)}:{i}: project-wide `docker compose up` (name the service)")
                    if re.search(r"(\s-t\s*\d+\b|--timeout[ =]\d+)", seg):
                        bad.append(f"{os.path.relpath(p, root)}:{i}: literal stop timeout (use the STOP_GRACE symbol)")
for b in bad:
    print("FAIL:", b)
print(f"compose invariants: {n} compose command(s) checked, {len(bad)} violation(s)")
sys.exit(1 if bad else 0)
