#!/usr/bin/env python3
"""Syncs the shared files of mcloud-conventions into the MCloud repositories (sync/targets.yml).

Every target gets the shared files, the shared blocks of its files (between the markers) and `.mcloud-conventions`,
the checksums `make lint` checks. Without --push it only shows the changes; with --push it commits them to the
branch mcloud-conventions-sync and opens (or updates) the pull request into the target branch.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

SOURCE = Path(__file__).resolve().parent.parent
START = "# >>> mcloud-conventions"
END = "# <<< mcloud-conventions"
MANIFEST = ".mcloud-conventions"
BRANCH = "mcloud-conventions-sync"
SOURCE_REPO = "zebrunner/mcloud-conventions"


class SyncError(Exception):
    pass


def run(*args, cwd=None, check=True):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SyncError(f"{' '.join(args)}: {result.stderr.strip() or result.stdout.strip()}")
    # rstrip: the first line of git status --porcelain starts with a space
    return result.stdout.rstrip()


def block_of(text, where):
    """the shared block of a text, the marker lines included; a SyncError when the markers are missing"""
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.startswith(START)]
    ends = [i for i, line in enumerate(lines) if line.startswith(END)]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        raise SyncError(f"{where}: one block between '{START}' and '{END}' is expected")
    return starts[0], ends[0] + 1, "".join(lines[starts[0] : ends[0] + 1])


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


def plan(config, repo):
    """the files [(source, destination)] and the blocks [destination] of a target repository"""
    target = config["repos"][repo]
    paths = target.get("paths", {})
    files, blocks = [], []
    for group in target["groups"]:
        spec = config["groups"][group]
        for entry in spec.get("files", []):
            src, dest = (entry, entry) if isinstance(entry, str) else next(iter(entry.items()))
            for prefix, replacement in paths.items():
                if dest.startswith(prefix):
                    dest = replacement + dest[len(prefix) :]
            files.append((src, dest))
        blocks.extend(spec.get("blocks", []))
    return files, blocks


def apply(config, repo, checkout, source_sha):
    """writes the shared files, blocks and the manifest into the checkout; the changed paths"""
    files, blocks = plan(config, repo)
    sums = []
    for src, dest in files:
        source_file, target_file = SOURCE / src, checkout / dest
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, target_file)
        shutil.copymode(source_file, target_file)
        sums.append((hashlib.sha256(source_file.read_bytes()).hexdigest(), dest))
    for dest in blocks:
        _, _, block = block_of((SOURCE / dest).read_text(), f"{SOURCE_REPO}/{dest}")
        target_file = checkout / dest
        if not target_file.exists():
            raise SyncError(f"{repo}/{dest} is missing: create it with the shared block (CONVENTIONS.md)")
        text = target_file.read_text()
        start, end, _ = block_of(text, f"{repo}/{dest}")
        lines = text.splitlines(keepends=True)
        target_file.write_text("".join(lines[:start]) + block + "".join(lines[end:]))
        sums.append((sha256(block), f"{dest}#block"))

    manifest = checkout / MANIFEST
    body = "".join(f"{s}  {p}\n" for s, p in sums)
    old = manifest.read_text() if manifest.exists() else ""
    changed = [
        line
        for line in run("git", "status", "--porcelain", "--untracked-files=all", cwd=checkout).splitlines()
        if not line.endswith(MANIFEST)
    ]
    if changed or not old.endswith(body) or not old:
        manifest.write_text(
            "# The shared files of zebrunner/mcloud-conventions and their checksums, written by its sync\n"
            "# and checked by `make lint`: change the shared files in mcloud-conventions, not here.\n"
            f"# synced from {SOURCE_REPO}@{source_sha}\n" + body
        )
    return run("git", "status", "--porcelain", "--untracked-files=all", cwd=checkout).splitlines()


def open_pull_request(repo, checkout, base, source_sha, changes):
    """commits the changes to BRANCH and opens or updates its pull request"""
    short = source_sha[:7]
    run("git", "checkout", "-B", BRANCH, cwd=checkout)
    run("git", "add", "--all", cwd=checkout)
    run(
        "git",
        "commit",
        "--quiet",
        "--message",
        f"chore(conventions): sync the shared files of {SOURCE_REPO}@{short}",
        cwd=checkout,
    )
    run("git", "push", "--quiet", "--force", "origin", BRANCH, cwd=checkout)
    body = (
        f"The shared files of [{SOURCE_REPO}](https://github.com/{SOURCE_REPO}) at "
        f"[{short}](https://github.com/{SOURCE_REPO}/commit/{source_sha}), opened by its sync.\n\n"
        "Changed:\n\n" + "".join(f"- `{line[3:]}`\n" for line in changes) + "\n"
        "Review and merge it as any other pull request; a change of a shared file is made in mcloud-conventions.\n"
    )
    existing = run(
        "gh",
        "pr",
        "list",
        "--repo",
        repo,
        "--head",
        BRANCH,
        "--state",
        "open",
        "--json",
        "number",
        "--jq",
        ".[0].number",
    )
    title = f"chore(conventions): sync the shared files of mcloud-conventions@{short}"
    if existing:
        run("gh", "pr", "edit", existing, "--repo", repo, "--title", title, "--body", body)
        return f"https://github.com/{repo}/pull/{existing} (updated)"
    return run("gh", "pr", "create", "--repo", repo, "--base", base, "--head", BRANCH, "--title", title, "--body", body)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=SOURCE / "sync" / "targets.yml", type=Path)
    parser.add_argument("--repo", action="append", help="sync only this repository (owner/name), repeatable")
    parser.add_argument(
        "--local", action="append", default=[], metavar="REPO=PATH", help="use a local checkout of a repository"
    )
    parser.add_argument("--push", action="store_true", help="commit, push and open the pull requests (needs GH_TOKEN)")
    args = parser.parse_args()

    config = yaml.safe_load(args.config.read_text())
    local = dict(item.split("=", 1) for item in args.local)
    repos = args.repo or list(config["repos"])
    source_sha = run("git", "rev-parse", "HEAD", cwd=SOURCE, check=False) or "local"
    token = os.environ.get("GH_TOKEN", "")
    summary, failed = [], False

    with tempfile.TemporaryDirectory() as work:
        for repo in repos:
            base = config["repos"][repo].get("branch", config.get("branch", "develop"))
            try:
                if repo in local:
                    checkout = Path(local[repo])
                else:
                    checkout = Path(work) / repo.replace("/", "_")
                    auth = f"x-access-token:{token}@" if token else ""
                    run(
                        "git",
                        "clone",
                        "--quiet",
                        "--depth",
                        "1",
                        "--branch",
                        base,
                        f"https://{auth}github.com/{repo}.git",
                        str(checkout),
                    )
                changes = apply(config, repo, checkout, source_sha)
                if not changes:
                    result = "up to date"
                elif args.push:
                    result = open_pull_request(repo, checkout, base, source_sha, changes)
                else:
                    result = "changes: " + ", ".join(line[3:] for line in changes)
            except SyncError as error:
                result, failed = f"FAIL: {error}", True
            print(f"{repo}: {result}")
            summary.append(f"| {repo} | {result} |")

    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as out:
            out.write("| Repository | Sync |\n| --- | --- |\n" + "\n".join(summary) + "\n")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
