"""Integration tests: real local Git remotes, plus PTYs for interactive decisions."""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "pull.sh"
BASH = os.environ.get("TEST_BASH", "/bin/bash")
GIT = shutil.which("git")


class PullTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pull-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / "work"
        self.work.mkdir()
        self.remotes = self.root / "remotes"
        self.remotes.mkdir()
        self.manifest = self.root / "components.json"
        self.ignore = Path(str(self.manifest) + ".ignore")
        self.env = os.environ.copy()
        for key in ("GIT_BASE_URL", "DEFAULT_BRANCH", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.env.pop(key, None)
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0", GIT_AUTHOR_NAME="Test",
                        GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_NAME="Test",
                        GIT_COMMITTER_EMAIL="test@example.invalid")
        self.manifest.write_text('{}')

    def git(self, cwd, *args):
        return subprocess.check_output([GIT, *args], cwd=cwd, env=self.env,
                                       stderr=subprocess.PIPE, text=True).strip()

    def write_manifest(self, data):
        self.manifest.write_text(json.dumps(data))

    def fixture(self, name="one", clone=True):
        remote = self.remotes / (name + ".git")
        remote.parent.mkdir(parents=True, exist_ok=True)
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(remote))
        seed = self.root / (name.replace('/', '-') + "-seed")
        self.git(self.root, "init", "--initial-branch=main", str(seed))
        (seed / "tracked").write_text("initial\n")
        self.git(seed, "add", ".")
        self.git(seed, "commit", "-m", "initial")
        self.git(seed, "remote", "add", "origin", str(remote))
        self.git(seed, "push", "-u", "origin", "main")
        repo = self.work / name
        if clone:
            self.git(self.work, "clone", str(remote), str(repo))
        self.write_manifest({name: "main"})
        return seed, repo, remote

    def advance(self, seed):
        (seed / "tracked").write_text("remote update\n")
        self.git(seed, "commit", "-am", "remote update")
        self.git(seed, "push", "origin", "HEAD")
        return self.git(seed, "rev-parse", "HEAD")

    def command(self, *args):
        return [BASH, str(SCRIPT), "--manifest", str(self.manifest), *map(str, args)]

    def run_pull(self, *args, expected=0):
        result = subprocess.run(self.command(*args), cwd=self.work, env=self.env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, expected, output)
        return output

    def interactive(self, *args, replies=(), expected=0):
        master, slave = pty.openpty()
        process = subprocess.Popen(self.command(*args), cwd=self.work, env=self.env,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        output = ""
        pending = list(replies)
        scanned = 0
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk.decode(errors="replace")
                if pending and pending[0][0] in output[scanned:]:
                    marker, reply = pending.pop(0)
                    scanned = len(output)
                    if callable(reply):
                        reply = reply()
                    os.write(master, reply.encode())
            else:
                self.fail("Interactive timeout:\n" + output)
            process.wait(timeout=3)
            self.assertFalse(pending, "Unseen prompts: " + str(pending) + "\n" + output)
            self.assertEqual(process.returncode, expected, output)
            return output
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)

    def divergent(self):
        seed, repo, remote = self.fixture()
        (repo / "local").write_text("local commit\n")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-m", "local-only commit")
        local = self.git(repo, "rev-parse", "HEAD")
        target = self.advance(seed)
        return seed, repo, remote, local, target

    def test_validation_precedes_all_git_work(self):
        bad = ['{"one":', 'null', '[]', '', '{} {}', '{"one":"main","two":123}',
               '{"one":"main","../outside":"main"}', '{"one":"main","one/nested":"main"}',
               '{"one":"main","two":"bad ref"}', '{"one":"main","two":"bad^ref"}']
        for content in bad:
            with self.subTest(content=content):
                self.manifest.write_text(content)
                self.run_pull("--base-url", self.remotes, expected=2)
                self.assertFalse((self.work / "one").exists())

    def test_cli_and_removed_flags(self):
        for args in [("--dry-run",), ("--continue-on-error",), ("--jobs", "0"),
                     ("--jobs", "abc"), ("--jobs", "08"), ("--jobs",),
                     ("--force", "--jobs", "2"), ("--force", "--fetch")]:
            with self.subTest(args=args):
                self.run_pull(*args, expected=2)

    def test_empty_manifest(self):
        self.assertIn("total=0 success=0 failed=0", self.run_pull("--jobs", "2"))

    def test_missing_manifest(self):
        self.manifest.unlink()
        self.run_pull(expected=2)

    def test_clone_and_fast_forward(self):
        seed, repo, _ = self.fixture(clone=False)
        self.run_pull("--base-url", self.remotes)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "main")
        target = self.advance(seed)
        self.run_pull()
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)

    def test_new_branch(self):
        seed, repo, _ = self.fixture()
        self.git(seed, "checkout", "-b", "feature")
        target = self.advance(seed)
        self.git(seed, "push", "origin", "feature")
        self.write_manifest({"one": "feature"})
        self.run_pull()
        self.assertEqual(self.git(repo, "branch", "--show-current"), "feature")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)

    def test_only_origin_is_fetched(self):
        seed, repo, _ = self.fixture()
        self.git(repo, "remote", "add", "upstream", str(self.root / "missing"))
        target = self.advance(seed)
        self.run_pull()
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)

    def test_fetch_preserves_head_and_dirty_files(self):
        seed, repo, _ = self.fixture()
        before = self.git(repo, "rev-parse", "HEAD")
        self.git(repo, "checkout", "-b", "local-work")
        (repo / "tracked").write_text("dirty\n")
        target = self.advance(seed)
        self.run_pull("--fetch")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "local-work")
        self.assertEqual((repo / "tracked").read_text(), "dirty\n")
        self.assertEqual(self.git(repo, "rev-parse", "origin/main"), target)

    def test_fetch_does_not_clone(self):
        self.write_manifest({"one": "main"})
        self.run_pull("--fetch", "--base-url", self.remotes, expected=1)
        self.assertFalse((self.work / "one").exists())

    def test_missing_ref_and_failed_fetch_are_failures(self):
        _, repo, _ = self.fixture()
        before = self.git(repo, "rev-parse", "HEAD")
        self.write_manifest({"one": "missing"})
        self.assertIn("Ref not found", self.run_pull(expected=1))
        self.git(repo, "remote", "set-url", "origin", str(self.root / "missing"))
        self.write_manifest({"one": "main"})
        self.assertIn("fetch origin failed", self.run_pull(expected=1))
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), before)

    def test_default_branch_uses_live_origin_head(self):
        seed, repo, remote = self.fixture()
        self.git(seed, "checkout", "-b", "new-default")
        self.git(seed, "push", "origin", "new-default")
        self.git(remote, "symbolic-ref", "HEAD", "refs/heads/new-default")
        self.write_manifest({"one": ""})
        self.run_pull()
        self.assertEqual(self.git(repo, "branch", "--show-current"), "new-default")

    def test_fallback_default_branch(self):
        _, repo, remote = self.fixture()
        self.git(remote, "symbolic-ref", "HEAD", "refs/heads/missing")
        self.write_manifest({"one": ""})
        output = self.run_pull("--default-branch", "main")
        self.assertIn("origin/HEAD unavailable; using main", output)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "main")

    def test_failed_head_query_uses_default(self):
        _, repo, _ = self.fixture()
        self.write_manifest({"one": ""})
        self.install_git_monitor()
        self.env["TEST_FAIL_HEAD"] = "1"
        self.assertIn("origin/HEAD unavailable; using main", self.run_pull("--default-branch", "main"))
        self.assertEqual(self.git(repo, "branch", "--show-current"), "main")

    def test_clone_with_missing_remote_head_and_explicit_ref(self):
        _, repo, remote = self.fixture(clone=False)
        self.git(remote, "symbolic-ref", "HEAD", "refs/heads/missing")
        self.run_pull("--base-url", self.remotes)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "main")

    def test_tags_and_commits(self):
        seed, repo, _ = self.fixture()
        initial = self.git(seed, "rev-parse", "HEAD")
        self.git(seed, "tag", "v1")
        self.git(seed, "push", "origin", "v1")
        self.advance(seed)
        for ref in ("v1", initial[:10]):
            self.write_manifest({"one": ref})
            self.run_pull()
            self.assertEqual(self.git(repo, "rev-parse", "HEAD"), initial)
            self.assertEqual(self.git(repo, "branch", "--show-current"), "")

    def test_normal_divergence_fails_and_continues(self):
        _, repo, _, local, _ = self.divergent()
        seed2, repo2, _ = self.fixture("two")
        target2 = self.advance(seed2)
        self.write_manifest({"one": "main", "two": "main"})
        output = self.run_pull(expected=1)
        self.assertIn("success=1 failed=1", output)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), local)
        self.assertEqual(self.git(repo2, "rev-parse", "HEAD"), target2)

    def test_force_refuses_noninteractive_data_loss(self):
        _, repo, _, local, _ = self.divergent()
        (repo / "tracked").write_text("dirty\n")
        output = self.run_pull("--force", expected=1)
        self.assertIn("local-only commit", output)
        self.assertIn("Uncommitted tracked changes", output)
        self.assertIn("requires interactive confirmation", output)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), local)
        self.assertEqual((repo / "tracked").read_text(), "dirty\n")

    def test_force_confirms_divergence_and_dirty_changes(self):
        _, repo, _, _, target = self.divergent()
        (repo / "tracked").write_text("dirty\n")
        output = self.interactive("--force", replies=[("Discard the listed data", "yes\n")])
        self.assertIn("local-only commit", output)
        self.assertIn("Uncommitted tracked changes", output)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "main")
        self.assertEqual(self.git(repo, "status", "--porcelain"), "")

    def test_force_decline_keeps_data(self):
        _, repo, _, local, _ = self.divergent()
        self.interactive("--force", replies=[("Discard the listed data", "no\n"),
                                             ("retry / skip", "skip\n")], expected=1)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), local)

    def test_force_fast_forward_needs_no_confirmation(self):
        seed, repo, _ = self.fixture()
        target = self.advance(seed)
        self.run_pull("--force")
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)

    def test_force_local_ahead_requires_confirmation(self):
        _, repo, _ = self.fixture()
        target = self.git(repo, "rev-parse", "HEAD")
        (repo / "tracked").write_text("local\n")
        self.git(repo, "commit", "-am", "ahead")
        self.run_pull()  # Normal ff-only keeps local commits.
        self.assertNotEqual(self.git(repo, "rev-parse", "HEAD"), target)
        self.interactive("--force", replies=[("Discard the listed data", "y\n")])
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)

    def blockers(self):
        seed, repo, _ = self.fixture()
        (seed / "same").write_text("remote\n")
        (seed / "parent").mkdir()
        (seed / "parent" / "child").write_text("remote\n")
        (seed / "directory").write_text("remote\n")
        (seed / "ignored").write_text("remote\n")
        (seed / "line\nbreak").write_text("remote\n")
        self.git(seed, "add", ".")
        self.git(seed, "commit", "-m", "add paths")
        self.git(seed, "push")
        (repo / "same").write_text("local\n")
        (repo / "parent").write_text("local\n")
        (repo / "directory").mkdir()
        (repo / "directory" / "precious").write_text("local\n")
        (repo / "ignored").write_text("local ignored\n")
        (repo / ".git" / "info" / "exclude").write_text("ignored\n")
        (repo / "line\nbreak").write_text("local\n")
        (repo / "keep").write_text("keep me\n")
        return repo

    def test_untracked_and_ignored_blockers_safe_by_default(self):
        repo = self.blockers()
        output = self.run_pull(expected=1)
        for name in ("same", "parent", "directory/precious", "ignored", '"line\\nbreak"'):
            self.assertIn(name, output)
        self.assertEqual((repo / "ignored").read_text(), "local ignored\n")
        self.assertEqual((repo / "directory" / "precious").read_text(), "local\n")

    def test_force_only_overwrites_blockers(self):
        repo = self.blockers()
        self.interactive("--force", replies=[("Discard the listed data", "yes\n")])
        for name in ("same", "parent/child", "directory", "ignored", "line\nbreak"):
            self.assertEqual((repo / name).read_text(), "remote\n")
        self.assertEqual((repo / "keep").read_text(), "keep me\n")

    def test_ignore_persists_reports_and_preserves_manifest(self):
        self.write_manifest({"one": "main"})
        original = self.manifest.read_text()
        self.interactive(replies=[("retry / skip", "ignore\n")], expected=1)
        self.assertEqual(self.ignore.read_text(), "one\n")
        self.assertEqual(self.manifest.read_text(), original)
        output = self.run_pull()
        self.assertIn("Exclusions", output)
        self.assertIn("Fix excluded repos", output)
        self.assertIn("failed=0 excluded=1", output)
        self.write_manifest({})
        self.assertIn("Remove stale exclusions", self.run_pull())

    def test_skip_does_not_persist(self):
        self.write_manifest({"one": "main"})
        self.interactive(replies=[("retry / skip", "skip\n")], expected=1)
        self.assertFalse(self.ignore.exists())

    def test_retry_clears_failure_after_repair(self):
        _, repo, remote = self.fixture()
        self.git(repo, "remote", "set-url", "origin", str(self.root / "missing"))
        def repair():
            self.git(repo, "remote", "set-url", "origin", str(remote))
            return "retry\n"
        output = self.interactive(replies=[("retry / skip", repair)])
        self.assertIn("success=1 failed=0", output)

    def test_force_confirms_each_repository(self):
        targets = {}
        before = {}
        for name in ("one", "two"):
            seed, repo, _ = self.fixture(name)
            before[name] = self.git(repo, "rev-parse", "HEAD")
            (repo / "tracked").write_text("dirty\n")
            targets[name] = self.advance(seed)
        self.write_manifest({"one": "main", "two": "main"})
        self.interactive("--force", replies=[("Discard the listed data for one?", "yes\n"),
                                             ("Discard the listed data for two?", "no\n"),
                                             ("retry / skip", "skip\n")], expected=1)
        self.assertEqual(self.git(self.work / "one", "rev-parse", "HEAD"), targets["one"])
        self.assertEqual(self.git(self.work / "two", "rev-parse", "HEAD"), before["two"])
        self.assertEqual((self.work / "two" / "tracked").read_text(), "dirty\n")

    def test_dirty_default_checkout_does_not_fall_back(self):
        _, repo, _ = self.fixture()
        self.git(repo, "checkout", "-b", "feature")
        (repo / "tracked").write_text("dirty\n")
        self.write_manifest({"one": ""})
        output = self.run_pull("--default-branch", "missing", expected=1)
        self.assertNotIn("using missing", output)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "feature")
        self.assertEqual((repo / "tracked").read_text(), "dirty\n")

    def test_linked_worktree(self):
        seed, repo, _ = self.fixture()
        self.git(repo, "checkout", "-b", "other")
        linked = self.work / "linked"
        self.git(repo, "worktree", "add", str(linked), "main")
        target = self.advance(seed)
        self.write_manifest({"linked": "main"})
        self.run_pull()
        self.assertEqual(self.git(linked, "rev-parse", "HEAD"), target)
        self.assertEqual(self.git(repo, "branch", "--show-current"), "other")

    def test_in_progress_merge_is_preserved(self):
        seed, repo, _ = self.fixture()
        self.advance(seed)
        self.git(repo, "fetch", "origin")
        (repo / ".git" / "MERGE_HEAD").write_text(self.git(repo, "rev-parse", "origin/main") + "\n")
        self.assertIn("Finish or abort", self.run_pull("--force", expected=1))
        self.assertTrue((repo / ".git" / "MERGE_HEAD").exists())

    def test_submodule_tree_fails_clearly(self):
        seed, repo, _ = self.fixture()
        commit = self.git(seed, "rev-parse", "HEAD")
        self.git(seed, "update-index", "--add", "--cacheinfo", "160000," + commit + ",module")
        self.git(seed, "commit", "-m", "gitlink")
        self.git(seed, "push")
        self.assertIn("Submodules are not supported", self.run_pull("--force", expected=1))
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), commit)

    def test_retry_after_clone_with_missing_ref(self):
        seed, repo, _ = self.fixture(clone=False)
        self.write_manifest({"one": "later"})
        def repair():
            self.git(seed, "push", "origin", "HEAD:refs/heads/later")
            return "retry\n"
        self.interactive("--base-url", self.remotes, replies=[("retry / skip", repair)])
        self.assertEqual(self.git(repo, "branch", "--show-current"), "later")
        self.assertEqual(self.git(repo, "status", "--porcelain"), "")

    def test_hand_edited_exclusions(self):
        self.ignore.write_text("# personal exclusions\n\n")
        self.assertNotIn("Exclusions (", self.run_pull())
        self.ignore.write_text("stale-without-newline")
        self.write_manifest({"one": "main"})
        self.interactive(replies=[("retry / skip", "ignore\n")], expected=1)
        self.assertIn("excluded=1", self.run_pull())

    def test_inherited_git_environment_cannot_select_another_repo(self):
        seed, repo, _ = self.fixture()
        target = self.advance(seed)
        self.env.update(GIT_DIR=str(seed / ".git"), GIT_WORK_TREE=str(seed),
                        GIT_INDEX_FILE=str(seed / ".git" / "index"))
        self.run_pull()
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.env.pop(name)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), target)

    def test_assume_unchanged_cannot_hide_data_loss(self):
        seed, repo, _ = self.fixture()
        self.git(repo, "update-index", "--assume-unchanged", "tracked")
        (repo / "tracked").write_text("hidden local data\n")
        self.advance(seed)
        self.run_pull("--force", expected=1)
        self.assertEqual((repo / "tracked").read_text(), "hidden local data\n")

    def test_force_cannot_hide_dirty_changes_behind_index_flags(self):
        _, repo, _, local, _ = self.divergent()
        self.git(repo, "update-index", "--assume-unchanged", "tracked")
        (repo / "tracked").write_text("hidden local data\n")
        output = self.interactive("--force", replies=[("retry / skip", "skip\n")], expected=1)
        self.assertIn("Clear assume-unchanged/skip-worktree", output)
        self.assertEqual(self.git(repo, "rev-parse", "HEAD"), local)
        self.assertEqual((repo / "tracked").read_text(), "hidden local data\n")

    def test_parallel_review_retries_in_the_foreground(self):
        _, repo, remote = self.fixture()
        self.fixture("two")
        self.git(repo, "remote", "set-url", "origin", str(self.root / "missing"))
        self.write_manifest({"one": "main", "two": "main"})
        def repair():
            self.git(repo, "remote", "set-url", "origin", str(remote))
            return "retry\n"
        output = self.interactive("--jobs", "2", replies=[("retry / skip", repair)])
        self.assertIn("success=2 failed=0", output)

    def install_git_monitor(self, delay="0.1"):
        bindir = self.root / "bin"
        bindir.mkdir()
        wrapper = bindir / "git"
        log = self.root / "events.jsonl"
        wrapper.write_text(f'''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
args = sys.argv[1:]
if "ls-remote" in args and os.environ.get("TEST_FAIL_HEAD"):
    sys.exit(1)
if "fetch" not in args:
    os.execv({GIT!r}, [{GIT!r}] + args)
def event(kind):
    with open({str(log)!r}, "a") as file:
        file.write(json.dumps(dict(kind=kind, pid=os.getpid(), repo=args[1])) + "\\n")
def terminate(signum, frame):
    event("terminated")
    sys.exit(143)
signal.signal(signal.SIGTERM, terminate)
event("start")
time.sleep({delay})
result = subprocess.call([{GIT!r}] + args)
event("end")
sys.exit(result)
''')
        wrapper.chmod(0o755)
        self.env["PATH"] = str(bindir) + os.pathsep + self.env["PATH"]
        return log

    def test_parallel_limit_and_failure_accounting(self):
        refs = {}
        for name in ("one", "two", "three", "four"):
            self.fixture(name)
            refs[name] = "main"
        self.git(self.work / "two", "remote", "set-url", "origin", str(self.root / "missing"))
        self.write_manifest(refs)
        log = self.install_git_monitor()
        output = self.run_pull("--jobs", "2", expected=1)
        self.assertIn("success=3 failed=1", output)
        running = maximum = 0
        for event in map(json.loads, log.read_text().splitlines()):
            running += 1 if event["kind"] == "start" else -1
            maximum = max(maximum, running)
        self.assertEqual(maximum, 2)
        self.assertEqual(running, 0)

    def test_parallel_interrupt_stops_workers(self):
        for name in ("one", "two"):
            self.fixture(name)
        self.write_manifest({"one": "main", "two": "main"})
        log = self.install_git_monitor(delay="30")
        process = subprocess.Popen(self.command("--jobs", "2"), cwd=self.work, env=self.env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if log.exists() and len(log.read_text().splitlines()) == 2:
                    break
                time.sleep(0.05)
            else:
                self.fail("Workers did not start")
            workers = [json.loads(line)["pid"] for line in log.read_text().splitlines()]
            process.terminate()
            self.assertEqual(process.wait(timeout=5), 143)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                stopped = {e["pid"] for e in map(json.loads, log.read_text().splitlines()) if e["kind"] == "terminated"}
                if stopped == set(workers):
                    break
                time.sleep(0.05)
            self.assertEqual(stopped, set(workers), "Workers did not receive termination")
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
