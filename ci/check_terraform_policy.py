#!/usr/bin/env python3
"""Terraform policy checks (INFRA-CI, ADR-08 3.2 and ADR-11 3.1). Static, no terraform binary needed.
Fails when:
  - a guarded resource lacks `prevent_destroy = true`
    (the droplet_protected droplet, the pgdata volumes except rehearsal, production buckets and the state bucket);
  - a droplet lacks `ignore_changes` containing user_data, image and ssh_keys;
  - a digitalocean_database_* resource exists (ADR-11: no Managed PostgreSQL);
  - a digitalocean_volume_attachment exists (a human attaches pgdata, so no plan can detach it).
Passes on a repo with no .tf files. Usage: ci/check_terraform_policy.py [root]"""
import os, re, sys

root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), ".."))
HEAD = re.compile(r'^\s*resource\s+"([\w-]+)"\s+"([\w-]+)"\s*\{', re.M)


def blocks(text):
    for m in HEAD.finditer(text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            c = text[i]
            depth += (c == "{") - (c == "}")
            i += 1
        yield m.group(1), m.group(2), text[m.end():i - 1]


def strip_comments(t):
    return re.sub(r"(?m)^\s*(#|//).*$", "", t)


def name_of(body):
    m = re.search(r'\bname\s*=\s*"([^"]*)"', body)
    return m.group(1) if m else ""


bad, n = [], 0
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x not in {".git", ".terraform", "tests"}]
    for f in files:
        if not f.endswith(".tf"):
            continue
        p = os.path.relpath(os.path.join(d, f), root)
        for rtype, label, body in blocks(strip_comments(open(os.path.join(d, f), encoding="utf-8").read())):
            n += 1
            where = f"{p}: {rtype}.{label}"
            prevent = re.search(r"prevent_destroy\s*=\s*true", body) is not None
            nm = name_of(body)
            if rtype.startswith("digitalocean_database_"):
                bad.append(f"{where}: Managed PostgreSQL is withdrawn (ADR-11 3.8)")
            if rtype == "digitalocean_volume_attachment":
                bad.append(f"{where}: volume attachments are made by a human, never by Terraform (ADR-11 3.1)")
            if rtype == "digitalocean_droplet":
                ig = re.search(r"ignore_changes\s*=\s*\[([^\]]*)\]", body)
                have = set(re.findall(r"\b(user_data|image|ssh_keys)\b", ig.group(1))) if ig else set()
                if have != {"user_data", "image", "ssh_keys"}:
                    bad.append(f"{where}: ignore_changes must be exactly [user_data, image, ssh_keys]")
                if re.search(r"(?m)^\s*user_data\s*=", body):
                    bad.append(f"{where}: a droplet must not set user_data (PI.3 rule)")
                if label == "droplet_protected" and not prevent:
                    bad.append(f"{where}: droplet_protected needs prevent_destroy = true")
            if rtype == "digitalocean_volume" and "pgdata" in (nm + label) and "rehearsal" not in (nm + label) and not prevent:
                bad.append(f"{where}: a pgdata volume needs prevent_destroy = true (ADR-11 3.1)")
            if rtype == "digitalocean_spaces_bucket" and re.search(r"prod|tfstate|vault", nm + label) and not prevent:
                bad.append(f"{where}: a production or state bucket needs prevent_destroy = true (ADR-08 3.2)")
for b in bad:
    print("FAIL:", b)
print(f"terraform policy: {n} resource(s) checked, {len(bad)} violation(s)")
sys.exit(1 if bad else 0)
