"""Regression checks for the shared pin and the image's runtime contract."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/check_opencode_version.sh"


class OpenCodeVersionTests(unittest.TestCase):
    def test_shared_pin_wiring(self):
        dockerfile = (ROOT / "Dockerfile").read_text()
        global_args, stages = re.split(r"^FROM ", dockerfile, maxsplit=1, flags=re.M)
        pins = re.findall(r"^ARG OPENCODE_VERSION=(.+)$", dockerfile, re.M)
        self.assertEqual(len(pins), 1)
        self.assertIn(f"ARG OPENCODE_VERSION={pins[0]}", global_args)
        self.assertRegex(pins[0], r"^\d+\.\d+\.\d+$")
        stage_map = {}
        for stage in re.split(r"^FROM ", "FROM " + stages, flags=re.M)[1:]:
            header, body = stage.split("\n", 1)
            stage_map[header.split(" AS ")[1]] = (header.split()[0], body)
        for name in ("agent-clis", "core"):
            self.assertRegex(stage_map[name][1], r"(?m)^ARG OPENCODE_VERSION$")
        self.assertIn('"opencode-ai@${OPENCODE_VERSION}"', stage_map["agent-clis"][1])
        self.assertRegex(stage_map["core"][1], r"(?m)^ENV OPENCODE_VERSION=\$\{OPENCODE_VERSION\}$")
        for name in ("cad", "ml", "infra"):
            self.assertEqual(stage_map[name][0], "core")
            self.assertNotIn("OPENCODE_VERSION", stage_map[name][1])
        self.assertIn('expect "OpenCode runtime version matches its exported pin" bash "$here/scripts/check_opencode_version.sh"',
                      (ROOT / "scripts/smoke_test.sh").read_text())

    def check_version(self, version, output="1.19.3", status=0):
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "opencode"
            cli.write_text('#!/bin/bash\n[[ "$*" == --version ]] || exit 99\n'
                           'printf "%s\\n" "$TEST_OUTPUT"\nexit "$TEST_STATUS"\n')
            cli.chmod(0o755)
            env = os.environ.copy()
            env.pop("OPENCODE_VERSION", None)
            env.update(PATH=f"{directory}:{env['PATH']}", TEST_OUTPUT=output,
                       TEST_STATUS=str(status))
            if version is not None:
                env["OPENCODE_VERSION"] = version
            return subprocess.run(["bash", str(CHECK)], env=env, capture_output=True,
                                  text=True, check=False)

    def test_matching_version(self):
        result = self.check_version("1.19.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("matches the exported pin", result.stdout)

    def test_rejects_invalid_contract(self):
        cases = [
            (None, "1.19.3", 0, "valid pinned"),
            ("", "1.19.3", 0, "valid pinned"),
            ("v1.19.3", "v1.19.3", 0, "valid pinned"),
            ("1.19", "1.19", 0, "valid pinned"),
            ("1.19.3-dev", "1.19.3-dev", 0, "valid pinned"),
            ("01.19.3", "01.19.3", 0, "valid pinned"),
            ("1.19.3", "1.19.4", 0, "mismatch"),
            ("1.19.3", "", 0, "mismatch"),
            ("1.19.3", "1.19.3\nextra", 0, "mismatch"),
            ("1.19.3", "1.19.3", 1, "--version failed"),
            ("1.19.3", "", 127, "--version failed"),
        ]
        for version, output, status, message in cases:
            with self.subTest(version=version, output=output, status=status):
                result = self.check_version(version, output, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
