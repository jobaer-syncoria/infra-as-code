#!/usr/bin/env python3
"""ADR-11 CI parts: INFRA-PG-11-01 (no path to 5432), INFRA-PG-11-02 (authentication), and the base-digest check.
 1. No `ports:` key on the compose service `postgres`; no 5432 in terraform firewall definitions, nginx files or
    ansible UFW/firewall files; no digitalocean_database_* resource.
 2. compose/postgres/pg_hba.conf (when it exists): no auth method trust, md5 or password; no `host` line for role
    postgres; the last line is `host all all 0.0.0.0/0 reject`. compose/postgres/postgresql.conf must set
    password_encryption = scram-sha-256.
 3. Base digest: every `postgres:17-trixie@sha256:<digest>` in the repo names the same digest.
Passes on an empty tree. Usage: ci/check_postgres.py [root]"""
import glob, os, re, sys

try:
    import yaml
except ImportError:
    print("FAIL: pyyaml is required (pip install pyyaml)"); sys.exit(2)

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
bad = []


def rel(p):
    return os.path.relpath(p, root)


def walk(top, exts=None):
    for d, dirs, files in os.walk(os.path.join(root, top)):
        dirs[:] = [x for x in dirs if x not in {".git", ".terraform", "tests"}]
        for f in files:
            if exts is None or f.endswith(exts):
                yield os.path.join(d, f)


# 1. 5432
for p in glob.glob(os.path.join(root, "compose", "**", "*.y*ml"), recursive=True):
    try:
        doc = yaml.safe_load(open(p, encoding="utf-8")) or {}
    except yaml.YAMLError as e:
        bad.append(f"{rel(p)}: not valid YAML ({e.__class__.__name__})"); continue
    svc = (doc.get("services") or {}).get("postgres") if isinstance(doc, dict) else None
    if isinstance(svc, dict) and "ports" in svc:
        bad.append(f"{rel(p)}: service postgres has a `ports:` key (INFRA-PG-11-01)")
for top, exts in (("terraform", (".tf",)), ("nginx", None), ("ansible", None), ("cloud-init", None)):
    for p in walk(top, exts):
        if os.path.basename(p) == "README.md":
            continue
        try:
            body = open(p, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        body = re.sub(r"(?m)^\s*(#|//).*$", "", body)
        if top == "ansible" and not re.search(r"ufw|firewall|iptables|nftables", p + body, re.I):
            continue
        if re.search(r"(?<![\d.])5432(?!\d)", body):
            bad.append(f"{rel(p)}: mentions 5432 in a firewall, nginx or UFW file (INFRA-PG-11-01)")
        if re.search(r'resource\s+"digitalocean_database_', body):
            bad.append(f"{rel(p)}: digitalocean_database_* resource (ADR-11 3.8)")

# 2. pg_hba and postgresql.conf
hba = os.path.join(root, "compose", "postgres", "pg_hba.conf")
if os.path.exists(hba):
    rows = [l.split("#")[0].split() for l in open(hba, encoding="utf-8") if l.split("#")[0].strip()]
    for r in rows:
        if any(m in ("trust", "md5", "password") for m in r[3:]):
            bad.append(f"compose/postgres/pg_hba.conf: forbidden auth method in `{' '.join(r[:4])} ...`")
        if r and r[0].startswith("host") and len(r) > 2 and "postgres" in r[2].split(","):
            bad.append("compose/postgres/pg_hba.conf: a host line names the postgres role")
    if not rows or rows[-1][:5] != ["host", "all", "all", "0.0.0.0/0", "reject"]:
        bad.append("compose/postgres/pg_hba.conf: the last line must be `host all all 0.0.0.0/0 reject`")
    conf = os.path.join(root, "compose", "postgres", "postgresql.conf")
    ok = os.path.exists(conf) and re.search(r"(?m)^\s*password_encryption\s*=\s*'?scram-sha-256'?", open(conf, encoding="utf-8").read())
    if not ok:
        bad.append("compose/postgres/postgresql.conf must set password_encryption = scram-sha-256")

# 3. one upstream digest
digests = {}
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x not in {".git", ".terraform", "tests"}]
    for f in files:
        p = os.path.join(d, f)
        try:
            body = open(p, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for m in re.finditer(r"postgres:17-trixie@(sha256:[0-9a-f]{64})", body):
            digests.setdefault(m.group(1), []).append(rel(p))
if len(digests) > 1:
    bad.append("postgres:17-trixie names more than one digest: " + "; ".join(f"{k[:19]}... in {','.join(sorted(set(v)))}" for k, v in digests.items()))

for b in bad:
    print("FAIL:", b)
print(f"postgres checks: {len(digests)} base digest(s) seen, {len(bad)} violation(s)")
sys.exit(1 if bad else 0)
