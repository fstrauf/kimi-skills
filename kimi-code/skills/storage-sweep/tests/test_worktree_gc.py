import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worktree_gc as gc  # noqa: E402

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def sh(cwd, *a, date=None):
    env = dict(ENV)
    if date:
        env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"] = date
    subprocess.run(a, cwd=cwd, env=env, check=True, capture_output=True)


def make_repo(tmp: Path) -> Path:
    """Primary repo with an origin remote on main."""
    origin = tmp / "origin.git"
    sh(tmp, "git", "init", "--bare", "-b", "main", str(origin))
    repo = tmp / "code" / "app"
    repo.mkdir(parents=True)
    sh(repo, "git", "init", "-b", "main")
    sh(repo, "git", "remote", "add", "origin", str(origin))
    (repo / "a").write_text("1")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-m", "init", date="2020-01-01T00:00:00")
    sh(repo, "git", "push", "-u", "origin", "main")
    sh(repo, "git", "remote", "set-head", "origin", "main")
    return repo


def add_wt(repo: Path, name: str, date: str) -> Path:
    wt = repo / ".claude" / "worktrees" / name
    sh(repo, "git", "worktree", "add", "-b", name, str(wt))
    (wt / "f").write_text(name)
    sh(wt, "git", "add", "-A")
    sh(wt, "git", "commit", "-m", name, date=date)
    return wt


def age(wt: Path):
    """Backdate git metadata so the worktree looks idle (fresh metadata == active)."""
    gitdir = Path(subprocess.run(["git", "-C", str(wt), "rev-parse", "--absolute-git-dir"],
                                 capture_output=True, text=True, check=True).stdout.strip())
    old = time.time() - 30 * 86400
    for n in ("HEAD", "index"):
        if (gitdir / n).exists():
            os.utime(gitdir / n, (old, old))


def verdicts(repo: Path, idle_days=2):
    vs, _ = gc.scan([repo.parent], idle_days, use_gh=False)
    return {Path(v.path).name: v for v in vs}


def test_classification(tmp_path):
    repo = make_repo(tmp_path)
    old = "2020-02-01T00:00:00"

    merged = add_wt(repo, "merged-old", old)
    sh(repo, "git", "merge", "--ff-only", "merged-old")
    sh(repo, "git", "push", "origin", "main")

    unpushed = add_wt(repo, "unpushed-old", old)

    pushed = add_wt(repo, "pushed-old", old)
    sh(pushed, "git", "push", "-u", "origin", "pushed-old")

    dirty = add_wt(repo, "dirty-old", old)
    sh(dirty, "git", "push", "-u", "origin", "dirty-old")
    (dirty / "wip").write_text("x")

    recent = add_wt(repo, "recent", time.strftime("%Y-%m-%dT%H:%M:%S"))
    sh(recent, "git", "push", "-u", "origin", "recent")

    for w in (merged, unpushed, pushed, dirty):
        age(w)
    v = verdicts(repo)
    assert v["app"].status == "KEEP" and "primary" in v["app"].reasons[0]
    assert v["merged-old"].status == "SAFE"
    # gh disabled => unmerged branches must never be SAFE/REVIEW
    assert v["pushed-old"].status == "KEEP"
    assert any("no remote" in r for r in v["unpushed-old"].reasons)
    assert any("uncommitted" in r for r in v["dirty-old"].reasons)
    assert any("active" in r for r in v["recent"].reasons)


def test_apply_refuses_keep_and_removes_safe(tmp_path):
    repo = make_repo(tmp_path)
    old = "2020-02-01T00:00:00"
    merged = add_wt(repo, "merged-old", old)
    sh(repo, "git", "merge", "--ff-only", "merged-old")
    sh(repo, "git", "push", "origin", "main")
    dirty = add_wt(repo, "dirty-old", old)
    (dirty / "wip").write_text("x")
    age(merged); age(dirty)

    rc = gc.apply([str(dirty), str(repo)], [repo.parent], 2, False, False)
    assert rc == 1 and dirty.exists() and repo.exists()

    assert gc.apply([str(merged)], [repo.parent], 2, False, False) == 0
    assert not merged.exists()
