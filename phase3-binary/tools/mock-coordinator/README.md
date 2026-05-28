# Mock coordinator harness

This directory contains a small Python WebSocket coordinator used by
`phase3-binary/scripts/test-ac11.sh` through `test-ac15.sh`.

Prerequisites:

- Python 3
- `websockets` Python package available in the active environment
- A local MLX model matching `MACPROVIDER_MODEL` for AC-11 through AC-14

Example:

```bash
python3 phase3-binary/tools/mock-coordinator/mock_coordinator.py \
  --scenario nonstream \
  --port 19081 \
  --model mlx-community/Llama-3.2-3B-Instruct-4bit
```

The mock accepts a provider WebSocket connection, sends `hello_ack`, then
drives the selected SPEC-001 v1.2.1 § 6.6 scenario.
