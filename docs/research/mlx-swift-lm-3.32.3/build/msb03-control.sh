#!/bin/bash
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
O=<studio-home>/lab-332/runs2/step2-msb-control; mkdir -p $O
M="<studio-home>/Library/Application Support/macprovider/models/mlx-community--Qwen3.6-35B-A3B-4bit/38740b847e4cb78f352aba30aa41c76e08e6eb46/3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1"
<studio-home>/lab-332/control-1.8.230/bin/macprovider-cli msb-throughput --model "$M" --engine scheduler --scenario msb03 --output $O/scheduler-msb03.json > $O/scheduler-msb03.log 2>&1; echo "control msb03 exit=$?"
