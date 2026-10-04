#!/usr/bin/env python3
"""Pin each deploy-targets.toml target to its newest ghcr.io tag.

Rewrites the tag in place (a kustomize `newTag:` line, or an
`image: <image>:<tag>` line) and appends "name: old -> new" lines to
$DEPLOY_CHANGES_FILE. Registry auth: $GHCR_USERNAME / $GHCR_TOKEN.
Keeps going past a failing target so the others still deploy, then exits 1.
"""
import base64
import json
import os
import re
import sys
import tomllib
import urllib.parse
import urllib.request

POLICIES = {
    "release": (re.compile(r"^v(\d+)(?:\.(\d+))?(?:\.(\d+))?$"),
                lambda m: tuple(int(g or 0) for g in m.groups())),
    "main": (re.compile(r"^main-(\d+)-[0-9a-f]{7,40}$"),
             lambda m: int(m.group(1))),
}


def list_tags(image):
    registry, repo = image.split("/", 1)
    creds = f"{os.environ['GHCR_USERNAME']}:{os.environ['GHCR_TOKEN']}"
    req = urllib.request.Request(
        f"https://{registry}/token?scope=repository:{repo}:pull",
        headers={"Authorization": "Basic " + base64.b64encode(creds.encode()).decode()})
    with urllib.request.urlopen(req) as resp:
        token = json.load(resp)["token"]
    tags, url = [], f"https://{registry}/v2/{repo}/tags/list?n=1000"
    while url:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req) as resp:
            tags += json.load(resp).get("tags") or []
            link = re.search(r'<([^>]+)>;\s*rel="next"', resp.headers.get("Link", ""))
        url = urllib.parse.urljoin(url, link.group(1)) if link else None
    return tags


def pick(tags, policy):
    pattern, key = POLICIES[policy]
    matches = [(key(m), t) for t in tags if (m := pattern.match(t))]
    return max(matches)[1] if matches else None


def rewrite(path, image, tag):
    """Returns the old tag, or None if the file holds no single tag line.

    Tried in order: an `image: <image>:<tag>` line; the `newTag:` directly
    under this image's `- name: <image>` entry (overlays with several
    images); then the file's only `newTag:` line.
    """
    with open(path) as f:
        text = f.read()
    for pattern in (rf"^(\s*image: {re.escape(image)}:)(\S+)",
                    rf"^([ \t]*- name: {re.escape(image)}[ \t]*\n[ \t]*newTag: )(\S+)",
                    r"^(\s*newTag: )(\S+)"):
        found = re.findall(pattern, text, re.M)
        if len(found) == 1:
            old = found[0][1]
            with open(path, "w") as f:
                f.write(re.sub(pattern, lambda m: m.group(1) + tag, text, flags=re.M))
            return old
    return None


def write_summary(rows):
    """Appends a markdown table of every target's outcome to the job summary."""
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    code = lambda s: f"`{s}`" if s else ""
    lines = ["### Resolved deploy tags", "",
             "| Target | Policy | Status | Previous tag | Resolved tag |",
             "| --- | --- | --- | --- | --- |"]
    for name, policy, status, old, new in rows:
        lines.append(f"| {name} | {policy} | {status} | {code(old)} | {code(new)} |")
    with open(path, "a") as f:
        f.write("\n".join(lines) + "\n\n")


def main():
    with open("deploy-targets.toml", "rb") as f:
        targets = tomllib.load(f)["target"]
    changes, rows, failed = [], [], False
    for t in targets:
        row = lambda status, old=None, new=None: rows.append(
            (t["name"], t["policy"], status, old, new))
        if t.get("hold"):
            print(f"{t['name']}: held, skipping")
            row("⏸️ held")
            continue
        try:
            tag = pick(list_tags(t["image"]), t["policy"])
        except Exception as e:
            print(f"::error::{t['name']}: listing {t['image']} tags failed: {e}")
            row("❌ listing tags failed")
            failed = True
            continue
        if tag is None:
            print(f"::warning::{t['name']}: no tag matches policy {t['policy']!r}")
            row("⚠️ no matching tag")
            continue
        old = rewrite(t["file"], t["image"], tag)
        if old is None:
            print(f"::error::{t['name']}: no single tag line in {t['file']}")
            row("❌ no single tag line", new=tag)
            failed = True
        elif old != tag:
            changes.append(f"{t['name']}: {old} -> {tag}")
            print(changes[-1])
            row("🚀 updated", old, tag)
        else:
            print(f"{t['name']}: up to date ({tag})")
            row("✅ up to date", old, tag)
    if changes and os.environ.get("DEPLOY_CHANGES_FILE"):
        with open(os.environ["DEPLOY_CHANGES_FILE"], "a") as f:
            f.write("\n".join(changes) + "\n")
    write_summary(rows)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
