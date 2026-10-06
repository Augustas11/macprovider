"""The signed CB policy's cache_class enum is one set everywhere (#1808).

SPEC-023 v0.22.1 closes `cache_class` to exactly KVCacheSimple and mixed. The
catalog generator, the coordinator feed validator, and the CLI's signed-policy
parser must agree, or a policy one side signs is refused by another.
"""

from __future__ import annotations

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC_SET = {"KVCacheSimple", "mixed"}


class CachePolicyCacheClassParityTest(unittest.TestCase):
    def test_generator_coordinator_and_cli_accept_the_same_classes(self):
        python = (ROOT / "scripts/catalog-release.py").read_text()
        match = re.search(r'entry\["cache_class"\] not in \{([^}]*)\}', python)
        self.assertIsNotNone(match)
        generator = set(re.findall(r'"([^"]+)"', match.group(1)))

        go = (ROOT / "phase4-coordinator/internal/buyer/continuous_batching_policy_feed.go").read_text()
        block = re.search(r"continuousBatchingPolicyCacheClasses = map\[string\]struct\{\}\{(.*?)\n\}", go, re.S)
        self.assertIsNotNone(block)
        coordinator = set(re.findall(r'"([^"]+)":', block.group(1)))

        swift = (ROOT / "phase3-binary/Sources/macprovider-cli/ContinuousBatchingSignedPolicy.swift").read_text()
        allowed = re.search(r'"cache_class",\s*path: path,\s*allowed: \[([^\]]*)\]', swift)
        self.assertIsNotNone(allowed)
        cli = set(re.findall(r'"([^"]+)"', allowed.group(1)))

        self.assertEqual(generator, SPEC_SET)
        self.assertEqual(coordinator, SPEC_SET)
        self.assertEqual(cli, SPEC_SET)


if __name__ == "__main__":
    unittest.main()
