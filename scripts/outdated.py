#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["ansible-core", "pyyaml"]
# ///
"""List versions pinned in this repo next to the newest upstream release.

Covers the k3s/cert-manager/Flux pins in ansible/group_vars/all/cluster.yml,
the collections in ansible/requirements.yml, Flux HelmRelease chart versions,
third-party image tags under k8s/ (our own ghcr.io/zetatwo images are kept
current by the deploy workflow), GitHub Actions used under .github/, and the
Terraform provider versions in terraform/.terraform.lock.hcl. It also lists
the locally installed `ansible` package, which nothing in the repo pins.

An image tag is compared only against tags of the same shape: `18.7-trixie`
against other `<n>.<n>-trixie` tags, `v7.15.6` against `v<n>.<n>.<n>`. A
short pin like an action's `v3` is compared at its own precision, so v3.4.0
doesn't count as newer. Run with --all to also list what is already current.
"""
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml
from ansible.inventory.manager import InventoryManager
from ansible.parsing.dataloader import DataLoader
from ansible.vars.manager import VariableManager

ROOT = Path(__file__).resolve().parent.parent
OWN_IMAGES = "ghcr.io/zetatwo/"
CLUSTER_PINS = {
    "k3s_version": "k3s-io/k3s",
    "cert_manager_version": "cert-manager/cert-manager",
    "flux_version": "fluxcd/flux2",
}


def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "infra-outdated", **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read(), resp.headers


def get_json(url, headers=None):
    return json.loads(get(url, headers)[0])


def numbers(version):
    """(1, 37, 2, 1) for 'v1.37.2+k3s1': every digit run, for ordering."""
    return tuple(int(n) for n in re.findall(r"\d+", version))


def is_stable(version):
    return not re.search(r"-(alpha|beta|rc|pre|dev)|alpha|beta|rc\d", version, re.I)


def change(current, latest):
    """'major'/'minor'/'patch' if latest is newer, compared at current's precision."""
    a = numbers(current)
    b = numbers(latest)[: len(a)]
    if b <= a:
        return None
    level = next(i for i, (x, y) in enumerate(zip(a, b)) if x != y)
    return ["major", "minor", "patch"][min(level, 2)]


# --- sources ---------------------------------------------------------------

def github_latest(repo):
    releases = get_json(f"https://api.github.com/repos/{repo}/releases?per_page=100")
    tags = [r["tag_name"] for r in releases
            if not r["draft"] and not r["prerelease"] and is_stable(r["tag_name"])]
    return max(tags, key=numbers)


def galaxy_latest(collection):
    namespace, name = collection.split(".")
    data = get_json("https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/"
                    f"collections/index/{namespace}/{name}/")
    return data["highest_version"]["version"]


def pypi_latest(package):
    return get_json(f"https://pypi.org/pypi/{package}/json")["info"]["version"]


def helm_latest(repo_url, chart):
    index = yaml.safe_load(get(repo_url.rstrip("/") + "/index.yaml")[0])
    versions = [e["version"] for e in index["entries"][chart] if is_stable(e["version"])]
    return max(versions, key=numbers)


def registry_tags(image):
    """All tags of an image, via the OCI distribution API with anonymous auth."""
    first = image.split("/", 1)[0]
    if "." not in first and ":" not in first:  # docker.io shorthand
        image = "docker.io/" + (image if "/" in image else "library/" + image)
    registry, repo = image.split("/", 1)
    if registry == "docker.io":
        registry = "registry-1.docker.io"
    url = f"https://{registry}/v2/{repo}/tags/list?n=1000"
    headers, tags = {}, []
    while url:
        try:
            body, resp_headers = get(url, headers)
        except urllib.error.HTTPError as e:
            if e.code != 401 or headers:
                raise
            challenge = dict(re.findall(r'(\w+)="([^"]*)"', e.headers["WWW-Authenticate"]))
            query = urllib.parse.urlencode(
                {k: challenge[k] for k in ("service", "scope") if k in challenge})
            token = get_json(f"{challenge['realm']}?{query}")
            headers = {"Authorization": f"Bearer {token.get('token') or token['access_token']}"}
            continue
        tags += json.loads(body).get("tags") or []
        link = re.search(r"<([^>]+)>", resp_headers.get("Link", ""))
        url = urllib.parse.urljoin(url, link.group(1)) if link else None
    return tags


def image_latest(image, tag):
    shape = re.compile("^" + re.sub(r"\\\d+|\d+", r"\\d+", re.escape(tag)) + "$")
    return max((t for t in registry_tags(image) if shape.match(t)), key=numbers)


def terraform_latest(source):
    _, namespace, name = source.split("/")
    data = get_json(f"https://registry.terraform.io/v1/providers/{namespace}/{name}/versions")
    return max((v["version"] for v in data["versions"] if is_stable(v["version"])), key=numbers)


# --- pins in this repo -----------------------------------------------------

def ansible_vars():
    """Ansible vars as the first inventory host sees them, untemplated.

    Uses Ansible's internal Python API, which can change between releases.
    Vaulted values elsewhere in group_vars are never decrypted.
    """
    loader = DataLoader()
    inventory = InventoryManager(loader=loader, sources=[str(ROOT / "ansible/inventory/hosts.yaml")])
    variables = VariableManager(loader=loader, inventory=inventory)
    return variables.get_vars(host=inventory.get_hosts()[0])


def pins():
    """Yield (group, name, current, where, lookup) for everything pinned."""
    cluster = ansible_vars()
    for var, repo in CLUSTER_PINS.items():
        yield ("cluster", repo.split("/")[1], cluster[var], f"cluster.yml {var}",
               lambda repo=repo: github_latest(repo))

    requirements = yaml.safe_load((ROOT / "ansible/requirements.yml").read_text())
    for c in requirements["collections"]:
        yield ("ansible", c["name"], str(c["version"]), "ansible/requirements.yml",
               lambda name=c["name"]: galaxy_latest(name))
    try:
        out = subprocess.run(["ansible-community", "--version"], capture_output=True,
                             text=True, check=True).stdout
        yield ("ansible", "ansible (package)", out.split()[-1], "installed locally, not pinned",
               lambda: pypi_latest("ansible"))
    except (OSError, subprocess.CalledProcessError):
        pass

    actions = {}
    for path in sorted((ROOT / ".github").rglob("*.yml")):
        for repo, ref in re.findall(r"uses:\s*([\w.-]+/[\w.-]+)(?:/[^@\s]*)?@(v?\d+(?:\.\d+)*)\b",
                                    path.read_text()):
            actions.setdefault((repo, ref), []).append(str(path.relative_to(ROOT)))
    for (repo, ref), paths in actions.items():
        where = paths[0] + (f" (+{len(paths) - 1} more)" if len(paths) > 1 else "")
        yield ("action", repo, ref, where, lambda repo=repo: github_latest(repo))

    docs = []
    for path in sorted((ROOT / "k8s").rglob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if isinstance(doc, dict):
                docs.append((path, doc))
    helm_repos = {d["metadata"]["name"]: d["spec"]["url"]
                  for _, d in docs if d.get("kind") == "HelmRepository"}
    for path, d in docs:
        if d.get("kind") != "HelmRelease":
            continue
        spec = d["spec"]["chart"]["spec"]
        url = helm_repos[spec["sourceRef"]["name"]]
        yield ("helm", spec["chart"], spec["version"], str(path.relative_to(ROOT)),
               lambda url=url, chart=spec["chart"]: helm_latest(url, chart))

    images = {}
    for path in sorted((ROOT / "k8s").rglob("*.yaml")):
        for m in re.finditer(r"^\s*image:\s*[\"']?([^\s\"']+)", path.read_text(), re.M):
            ref = m.group(1)
            if ref.startswith(OWN_IMAGES) or ":" not in ref.rsplit("/", 1)[-1]:
                continue
            images.setdefault(ref, []).append(str(path.relative_to(ROOT)))
    for ref, paths in images.items():
        image, tag = ref.rsplit(":", 1)
        where = paths[0] + (f" (+{len(paths) - 1} more)" if len(paths) > 1 else "")
        yield ("image", image, tag, where, lambda image=image, tag=tag: image_latest(image, tag))

    lock = (ROOT / "terraform/.terraform.lock.hcl").read_text()
    for source, version in re.findall(r'provider "([^"]+)" \{\s*version\s*=\s*"([^"]+)"', lock):
        yield ("terraform", source.split("/", 1)[1], version, ".terraform.lock.hcl",
               lambda source=source: terraform_latest(source))


def main():
    show_all = "--all" in sys.argv[1:]
    items = list(pins())

    def check(item):
        try:
            return item, item[4](), None
        except Exception as e:  # keep going; report per row
            return item, None, e

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(check, items))

    rows, outdated, failed = [], 0, 0
    for (group, name, current, where, _), latest, err in results:
        if err:
            failed += 1
            rows.append((group, name, current, "?", f"error: {err}", where))
            continue
        level = change(current, latest)
        if level:
            outdated += 1
        if level or show_all:
            rows.append((group, name, current, latest, level or "ok", where))

    if rows:
        widths = [max(len(str(r[i])) for r in rows) for i in range(5)]
        for r in rows:
            print("  ".join(str(c).ljust(w) for c, w in zip(r, widths)) + "  " + r[5])
    print(f"\n{outdated} outdated, {failed} failed, {len(items)} checked")


if __name__ == "__main__":
    main()
