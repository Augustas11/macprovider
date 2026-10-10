#!/bin/bash
export PATH=/usr/sbin:/opt/homebrew/bin:/usr/bin:/bin
cd <studio-home>/lab-332/cs/$1/phase3-binary && swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS > <studio-home>/lab-332/cs/build-$1.log 2>&1
echo "exit=$? $(date -u +%T)" >> <studio-home>/lab-332/cs/build-$1.log
cp -c <studio-home>/lab-332/bin/mlx.metallib .build/release/ 2>/dev/null
