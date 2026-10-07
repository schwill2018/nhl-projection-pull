"""Durable data-branch storage using only Python's standard library and Git.

Commands: hydrate, begin, finalize, persist. Run from the code checkout.
No push occurs except in the explicit persist command (Actions only).
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone
import uuid


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def git(*args, env=None):
    result = subprocess.run(["git", *args], capture_output=True, env=env)
    if result.returncode:
        raise RuntimeError(f"git {args[0]} failed: {result.stderr.decode(errors='replace')}")
    return result.stdout


def head(remote, branch):
    rows = git("ls-remote", "--heads", remote, f"refs/heads/{branch}").decode().splitlines()
    return rows[0].split()[0] if rows else None


def fetch(remote, branch):
    git("fetch", "--no-tags", remote, f"refs/heads/{branch}")
    return git("rev-parse", "FETCH_HEAD").decode().strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summary(message):
    print(message)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write("\n" + message + "\n")


def hydrate(remote, branch):
    if Path("Data").exists():
        raise RuntimeError("Hydrate requires a clean checkout without Data; refusing to overwrite local history")
    parent = head(remote, branch)
    baseline = {}
    if parent:
        parent = fetch(remote, branch)
        archive = git("archive", "--format=tar", parent, "Data")
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            for member in tar.getmembers():
                path = PurePosixPath(member.name)
                if path.parts[0] != "Data" or ".." in path.parts or path.is_absolute() or not (member.isfile() or member.isdir()):
                    raise RuntimeError("Unsafe data archive member")
                target = Path(*path.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(tar.extractfile(member).read())
                    if "history" in path.parts:
                        baseline[str(path)] = digest(target)
    Path(".local").mkdir(exist_ok=True)
    Path(".local/storage.json").write_text(json.dumps({"parent": parent, "history": baseline}), encoding="utf-8")
    Path("Data/projected_goalies/history").mkdir(parents=True, exist_ok=True)
    # Bootstrap receipt exists even if restoring the remote archive fails.
    # Adopt it only after a successful restore; failures keep it for the artifact.
    pending = os.environ.get("PG_RUN_DIR")
    if pending and Path(pending).parent.resolve() == Path(".local/pending").resolve():
        target = Path("Data/projected_goalies/history") / Path(pending).name
        Path(pending).rename(target)
        env_path = os.environ.get("GITHUB_ENV")
        if env_path:
            with open(env_path, "a", encoding="utf-8") as stream:
                stream.write(f"PG_RUN_DIR={target.as_posix()}\n")
    summary(f"Restored durable history from `{branch}` ({parent or 'first run; branch will be created'}).")


def begin(pending=False):
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    name = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S_") + f"{run_id}_{attempt}_{uuid.uuid4().hex}"
    run_dir = Path(".local/pending" if pending else "Data/projected_goalies/history") / name
    run_dir.mkdir(parents=True, exist_ok=False)
    metadata = {"started_at": now(), "state": "started", "run_id": run_id, "attempt": attempt,
                "code_sha": os.environ.get("GITHUB_SHA"), "event": os.environ.get("GITHUB_EVENT_NAME"),
                "run_url": f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{run_id}"}
    (run_dir / "run.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    env_path = os.environ.get("GITHUB_ENV")
    if env_path:
        with open(env_path, "a", encoding="utf-8") as stream:
            stream.write(f"PG_RUN_DIR={run_dir.as_posix()}\n")
    print(run_dir.as_posix())


def finalize(run_dir, outcome):
    run_dir = Path(run_dir)
    metadata_path = run_dir / "run.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata.update(completed_at=now(), state=outcome)
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    if not (run_dir / "summary.md").exists():
        (run_dir / "summary.md").write_text(f"# Collection {outcome}\n\nCollector did not complete. See Actions step logs.\n", encoding="utf-8")
        summary(f"**Collection {outcome}:** collector did not complete. See the failed setup/restore/test step and recovery artifact.")
    hashes = {str(p.relative_to(run_dir).as_posix()): digest(p) for p in sorted(run_dir.rglob("*")) if p.is_file() and p.name != "sha256.json"}
    (run_dir / "sha256.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")


def persist(remote, branch):
    state = json.loads(Path(".local/storage.json").read_text(encoding="utf-8"))
    parent = state["parent"]
    if head(remote, branch) != parent:
        raise RuntimeError("Data branch changed during collection; refusing stale cache/history push. Recover this run from its artifact.")
    for name, expected in state["history"].items():
        path = Path(name)
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError(f"Archived observation was changed or removed: {name}")
    if not any(Path("Data/projected_goalies/history").glob("*/run.json")):
        raise RuntimeError("No run receipt to persist")
    # Separate index keeps data out of the source branch. read-tree retains
    # the full old branch; only the hydrated Data tree is staged over it.
    with tempfile.TemporaryDirectory(prefix="git-index-", dir=".local") as scratch:
        env = os.environ.copy()
        env["GIT_INDEX_FILE"] = str((Path(scratch) / "index").resolve())
        env.update(GIT_AUTHOR_NAME="NHL goalie collector", GIT_AUTHOR_EMAIL="collector@users.noreply.github.com",
                   GIT_COMMITTER_NAME="NHL goalie collector", GIT_COMMITTER_EMAIL="collector@users.noreply.github.com")
        git("read-tree", parent if parent else "--empty", env=env)
        git("add", "-f", "--", "Data", env=env)
        if Path(".gitattributes").exists():
            git("add", "--", ".gitattributes", env=env)
        tree = git("write-tree", env=env).decode().strip()
        args = ["commit-tree", tree]
        if parent:
            args += ["-p", parent]
        args += ["-m", f"Archive observation {os.environ.get('GITHUB_RUN_ID', 'local')} attempt {os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"]
        commit = git(*args, env=env).decode().strip()
        git("push", remote, f"{commit}:refs/heads/{branch}")
        if head(remote, branch) != commit:
            raise RuntimeError("Push verification failed")
    summary(f"Durable archive saved to `{branch}`: `{commit}`. Earlier observations and cache retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["hydrate", "begin", "finalize", "persist"])
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--branch", default="data")
    parser.add_argument("--run-dir", default=os.environ.get("PG_RUN_DIR"))
    parser.add_argument("--outcome", default="failure", choices=["success", "failure", "cancelled"])
    parser.add_argument("--pending", action="store_true", help="Allocate a receipt before remote restoration")
    args = parser.parse_args()
    if args.command == "hydrate": hydrate(args.remote, args.branch)
    elif args.command == "begin": begin(args.pending)
    elif args.command == "finalize": finalize(args.run_dir, args.outcome)
    else: persist(args.remote, args.branch)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        summary(f"**Storage/lifecycle failure:** {error}")
        raise
