#!/usr/bin/env python3
"""Syncs the shared files of mcloud-conventions into the MCloud repositories (sync/targets.yml).

Every target gets the shared files, the shared blocks of its files (between the markers) and `.mcloud-conventions`,
the checksums `make lint` checks; a file that is no longer shared is removed while it is the synced one. Without --push
it only shows the changes; with --push it commits them to the branch mcloud-conventions-sync and opens (or updates) the
pull request into the target branch, or closes that pull request when the target is up to date.
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
    try:
        result = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    except OSError as error:
        raise SyncError(f"{args[0]} can't be run: {error.strerror}") from error
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


def manifest_entries(text):
    """the (checksum, path) entries of a manifest"""
    return [tuple(line.split(None, 1)) for line in text.splitlines() if line.strip() and not line.startswith("#")]


def status(checkout, paths):
    """the lines of git status --porcelain of the paths"""
    return run("git", "status", "--porcelain", "--untracked-files=all", "--", *paths, cwd=checkout).splitlines()


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
    """writes the shared files, blocks and the manifest into the checkout, removes the files that are no longer shared;
    the git status lines of the paths of the sync (other changes of a local checkout are not its business)"""
    files, blocks = plan(config, repo)
    manifest = checkout / MANIFEST
    old = manifest.read_text() if manifest.exists() else ""
    sums, paths = [], [MANIFEST]
    for src, dest in files:
        source_file, target_file = SOURCE / src, checkout / dest
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, target_file)
        shutil.copymode(source_file, target_file)
        sums.append((hashlib.sha256(source_file.read_bytes()).hexdigest(), dest))
        paths.append(dest)
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
        paths.append(dest)
    # a file that is no longer shared is removed while it is the synced one, a changed one is the project's now; a
    # block that is no longer shared stays in its file
    shared = {path for _, path in sums}
    for old_sum, path in manifest_entries(old):
        target_file = checkout / path
        if path in shared or path.endswith("#block") or Path(path).is_absolute() or ".." in Path(path).parts:
            continue
        if not target_file.is_file():
            continue
        if hashlib.sha256(target_file.read_bytes()).hexdigest() == old_sum:
            target_file.unlink()
            paths.append(path)

    body = "".join(f"{s}  {p}\n" for s, p in sums)
    changed = status(checkout, paths[1:]) if len(paths) > 1 else []
    if changed or manifest_entries(old) != sums:
        manifest.write_text(
            "# The shared files of zebrunner/mcloud-conventions and their checksums, written by its sync\n"
            "# and checked by `make lint`: change the shared files in mcloud-conventions, not here.\n"
            f"# synced from {SOURCE_REPO}@{source_sha}\n" + body
        )
    return status(checkout, paths)


def open_pull_request(repo, checkout, base, source_sha, changes):
    """commits the changes to BRANCH, pushes it unless the remote one has the same files, opens or updates its pull
    request"""
    short = source_sha[:7]
    run("git", "checkout", "-B", BRANCH, cwd=checkout)
    paths = [line[3:] for line in changes]
    run("git", "add", "--all", "--", *paths, cwd=checkout)
    # the paths of the sync only, not the changes a local checkout has staged
    run(
        "git",
        "commit",
        "--quiet",
        "--message",
        f"chore(conventions): sync the shared files of {SOURCE_REPO}@{short}",
        "--",
        *paths,
        cwd=checkout,
    )
    unchanged = False
    if run("git", "ls-remote", "origin", f"refs/heads/{BRANCH}", cwd=checkout):
        run("git", "fetch", "--quiet", "--depth", "1", "origin", BRANCH, cwd=checkout)
        tree = run("git", "rev-parse", "HEAD^{tree}", cwd=checkout)
        unchanged = run("git", "rev-parse", "FETCH_HEAD^{tree}", cwd=checkout) == tree
    if not unchanged:
        run("git", "push", "--quiet", "--force", "origin", BRANCH, cwd=checkout)
    body = (
        f"The shared files of [{SOURCE_REPO}](https://github.com/{SOURCE_REPO}) at "
        f"[{short}](https://github.com/{SOURCE_REPO}/commit/{source_sha}), opened by its sync.\n\n"
        "Changed:\n\n" + "".join(f"- `{line[3:]}`\n" for line in changes) + "\n"
        "Review and merge it as any other pull request; a change of a shared file is made in mcloud-conventions.\n"
    )
    existing = open_pull_request_number(repo)
    title = f"chore(conventions): sync the shared files of mcloud-conventions@{short}"
    if existing and unchanged:
        return f"https://github.com/{repo}/pull/{existing} (unchanged)"
    if existing:
        run("gh", "pr", "edit", existing, "--repo", repo, "--title", title, "--body", body)
        return f"https://github.com/{repo}/pull/{existing} (updated)"
    return run("gh", "pr", "create", "--repo", repo, "--base", base, "--head", BRANCH, "--title", title, "--body", body)


def open_pull_request_number(repo):
    """the number of the open pull request of BRANCH, empty without one"""
    return run(
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


def close_stale_pull_request(repo):
    """closes the open pull request of BRANCH of a target that is up to date; the result for the summary"""
    existing = open_pull_request_number(repo)
    if not existing:
        return "up to date"
    run(
        "gh",
        "pr",
        "close",
        existing,
        "--repo",
        repo,
        "--delete-branch",
        "--comment",
        f"The target branch has the shared files of {SOURCE_REPO} already, closed by its sync.",
    )
    return f"up to date, closed the stale https://github.com/{repo}/pull/{existing}"


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
    if any("=" not in item for item in args.local):
        parser.error("--local is REPO=PATH")
    local = dict(item.split("=", 1) for item in args.local)
    repos = args.repo or list(config["repos"])
    unknown = [repo for repo in repos if repo not in config["repos"]]
    if unknown:
        parser.error(f"unknown --repo {', '.join(unknown)}: not a repository of {args.config}")
    try:
        source_sha = run("git", "rev-parse", "HEAD", cwd=SOURCE, check=False) or "local"
    except SyncError:
        source_sha = "local"
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
                    # a local checkout on the branch of the sync is up to date with itself, not with its base
                    on_branch = run("git", "rev-parse", "--abbrev-ref", "HEAD", cwd=checkout) == BRANCH
                    result = close_stale_pull_request(repo) if args.push and not on_branch else "up to date"
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
