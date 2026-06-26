from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class CliFakePipelineTests(unittest.TestCase):
    def test_cli_pipeline_with_fake_provider_and_fixture_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as output_dir:
            env = os.environ.copy()
            env["TUBEFOLD_CONFIG"] = "/dev/null"
            env.pop("PROVIDER", None)
            env.pop("OUTPUT_DIR", None)

            result = subprocess.run(
                [
                    str(ROOT / "bin" / "tubefold"),
                    "https://youtu.be/dQw4w9WgXcQ",
                    "--provider",
                    "fake",
                    "--output-dir",
                    output_dir,
                    "--metadata-json",
                    str(ROOT / "tests" / "fixtures" / "metadata.json"),
                    "--transcript-file",
                    str(ROOT / "tests" / "fixtures" / "transcript.txt"),
                    "--transcript-language",
                    "pl",
                    "--no-open",
                ],
                text=True,
                capture_output=True,
                env=env,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            output_path = Path(result.stdout.strip())
            self.assertTrue(output_path.exists())
            self.assertEqual(output_path.name, "Hello - World - Demo.md")
            content = output_path.read_text(encoding="utf-8")
            self.assertIn('type: "tubefold"', content)
            self.assertIn('transcript_language_code: "pl"', content)
            self.assertIn("# Fake Summary", content)


if __name__ == "__main__":
    unittest.main()
