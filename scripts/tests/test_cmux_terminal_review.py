#!/usr/bin/env python3
"""TDD tests for cmux-terminal-review.sh

Tests exercise the script's core functions by isolating socket discovery
via CMUX_SOCKET_DIRS and mocking cmux/tmux commands.

Run: python3 scripts/tests/test_cmux_terminal_review.py
"""
import json
import os
import shutil
import socket
import subprocess
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(SCRIPT_DIR, "..", "cmux-terminal-review.sh")


class CmuxTerminalReviewTest(unittest.TestCase):
    """Test the cmux terminal review script."""

    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(SCRIPT):
            raise unittest.SkipTest(f"Script not found: {SCRIPT}")

    def _make_mock_bin(self, commands):
        """Create a temp dir with mock shell scripts for each command->stdout mapping."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_")
        for cmd, stdout in commands.items():
            path = os.path.join(tmpdir, cmd)
            with open(path, "w") as f:
                f.write(f"#!/bin/bash\n{stdout}\n")
            os.chmod(path, 0o755)
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        return tmpdir

    def _make_real_socket(self, tmpdir, name="cmux-test.sock"):
        """Create a real AF_UNIX socket file so -S test passes."""
        socket_path = os.path.join(tmpdir, name)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(socket_path)
        srv.listen(1)
        self.addCleanup(lambda: srv.close())
        return socket_path

    def _run(self, env_extra=None, mock_path=None):
        env = os.environ.copy()
        env.update(env_extra or {})
        if mock_path:
            env["PATH"] = mock_path + ":" + env.get("PATH", "")
        return subprocess.run(
            ["bash", SCRIPT],
            capture_output=True, text=True, timeout=15, env=env,
        )

    # ── Test 1: No socket → ERROR exit ──

    def test_no_socket_exits_with_error(self):
        """When no cmux socket is found, script exits non-zero with ERROR."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_empty_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        mock_bin = self._make_mock_bin({"cmux": "exit 1", "nc": "exit 1", "tmux": "exit 1"})
        env = {
            "HOME": tmpdir,
            "CMUX_SOCKET_PATH": os.path.join(tmpdir, "nope.sock"),
            "CMUX_SOCKET_DIRS": tmpdir,  # only search our empty dir
        }
        result = self._run(env_extra=env, mock_path=mock_bin)
        self.assertNotEqual(result.returncode, 0, f"Should exit non-zero. stdout: {result.stdout}")
        self.assertIn("ERROR", result.stdout + result.stderr)

    # ── Test 2: CLI tree preferred over RPC ──

    def test_cli_tree_preferred_over_rpc(self):
        """When cmux CLI works, script uses it instead of raw RPC."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_cli_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        sock_path = self._make_real_socket(tmpdir)
        mock_tree = 'window window:1 [current] ◀ active\n└── workspace workspace:2 "my-project" [selected] ◀ active\n'
        mock_bin = self._make_mock_bin({
            "cmux": f"echo '{mock_tree}'",
            "tmux": "exit 1",
            "nc": "exit 1",
        })
        env = {
            "CMUX_SOCKET_PATH": sock_path,
        }
        result = self._run(env_extra=env, mock_path=mock_bin)
        self.assertIn("my-project", result.stdout)

    # ── Test 3: RPC fallback when TabManager unavailable ──

    def test_rpc_fallback_when_tabmanager_unavailable(self):
        """When cmux CLI returns 'TabManager not available', falls back to RPC."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_rpc_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        sock_path = self._make_real_socket(tmpdir)
        rpc_response = json.dumps({
            "jsonrpc": "2.0", "id": 1,
            "result": {"windows": [{"workspaces": [
                {"name": "rpc-workspace", "ref": "workspace:5", "id": "ws-5"}
            ]}]}
        })
        mock_bin = self._make_mock_bin({
            "cmux": "echo 'TabManager not available' >&2; exit 0",
            "nc": f"cat >/dev/null; echo '{rpc_response}'",  # ignore stdin, return RPC JSON
            "tmux": "exit 1",
        })
        env = {"CMUX_SOCKET_PATH": sock_path, "CMUX_SOCKET_DIRS": tmpdir}
        result = self._run(env_extra=env, mock_path=mock_bin)
        self.assertEqual(result.returncode, 0,
                          f"Should succeed with RPC fallback.\nstdout: {result.stdout}\nstderr: {result.stderr}")
        self.assertIn("rpc-workspace", result.stdout)

    # ── Test 4: AO tmux sessions captured ──

    def test_tmux_sessions_in_output(self):
        """When tmux sessions exist, names appear in output."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_tmux_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        sock_path = self._make_real_socket(tmpdir)
        mock_tree = 'window w:1 [current] ◀ active\n└── workspace ws:2 "test" [selected] ◀ active\n'
        mock_bin = self._make_mock_bin({
            "cmux": f"echo '{mock_tree}'",
            "tmux": "echo 'abc-cc-orchestrator: 1 windows'; echo 'some output' >&2; exit 0",
            "nc": "exit 1",
        })
        env = {"CMUX_SOCKET_PATH": sock_path}
        result = self._run(env_extra=env, mock_path=mock_bin)
        self.assertIn("orchestrator", result.stdout)

    # ── Test 5: Required sections present ──

    def test_output_has_required_sections(self):
        """Output contains Healthy, Risky, Blocked, and AO tmux sections."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_sections_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        sock_path = self._make_real_socket(tmpdir)
        mock_tree = 'window w:1 ◀ active\n└── workspace ws:2 "test" ◀ active\n'
        mock_bin = self._make_mock_bin({
            "cmux": f"echo '{mock_tree}'",
            "tmux": "exit 1",
            "nc": "exit 1",
        })
        env = {"CMUX_SOCKET_PATH": sock_path}
        result = self._run(env_extra=env, mock_path=mock_bin)
        for section in ["Healthy", "Risky", "Blocked", "AO tmux sessions"]:
            self.assertIn(section, result.stdout, f"Missing '{section}' section")

    # ── Test 6: Blocked detection ──

    def test_blocked_detection_from_tmux(self):
        """AO tmux sessions showing errors are reported."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_blocked_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        sock_path = self._make_real_socket(tmpdir)
        mock_tree = 'window w:1 ◀ active\n└── workspace ws:2 "idle" ◀ active\n'
        mock_bin = self._make_mock_bin({
            "cmux": f"echo '{mock_tree}'",
            "tmux": "echo 'abc-crash: 1 windows'; echo 'Error: spawnSync ENOBUFS' >&2; exit 0",
            "nc": "exit 1",
        })
        env = {"CMUX_SOCKET_PATH": sock_path}
        result = self._run(env_extra=env, mock_path=mock_bin)
        self.assertIn("crash", result.stdout)

    # ── Test 7: No hang on failure ──

    def test_clean_exit_no_hang(self):
        """Script exits cleanly (0 or 1) without hanging."""
        tmpdir = tempfile.mkdtemp(prefix="cmux_test_hang_")
        self.addCleanup(lambda: shutil.rmtree(tmpdir, ignore_errors=True))
        mock_bin = self._make_mock_bin({"cmux": "exit 1", "nc": "exit 1", "tmux": "exit 1"})
        env = {"HOME": tmpdir, "CMUX_SOCKET_DIRS": tmpdir}
        result = self._run(env_extra=env, mock_path=mock_bin)
        self.assertIn(result.returncode, [0, 1])


if __name__ == "__main__":
    unittest.main()
