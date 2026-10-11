#!/bin/bash
# Window 4: A3B main vs narrowed at 2/4/8/16 rows (output-heavy 1800/1024, 60 s);
# 27B main vs narrowed at 1/2/4/8/16 rows with the short shape (512/128, 90 s).
L=<studio-home>/lab-di; OUT=$L/runs/w4-$(date -u +%Y%m%dT%H%MZ); mkdir -p $OUT
$L/sampler.sh > $OUT/samples.log 2>&1 & SAM=$!; trap 'kill $SAM 2>/dev/null' EXIT
echo "WINDOW4_START $(date -u +%T)"
MD="<studio-home>/Library/Application Support/macprovider/models"
A3B="$MD/mlx-community--Qwen3.6-35B-A3B-4bit/38740b847e4cb78f352aba30aa41c76e08e6eb46/3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1"
X=<studio-home>/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
for spec in "verify8 600,901,1501,2000,3000,4500,6000,9000" "verify5 600,901,1501,3000,9000" "verify2 901,3000"; do
  set -- $spec; s=$(date +%s)
  ( cd $L/after && env MACPROVIDER_DECODE_ISOLATION_VERIFY=1 MACPROVIDER_DECODE_ISOLATION_VERIFY_WIDTH=2 MACPROVIDER_DECODE_ISOLATION_LENGTHS=$2 MACPROVIDER_DECODE_ISOLATION_MODEL="$A3B" \
    DYLD_LIBRARY_PATH=$X/usr/lib DYLD_FRAMEWORK_PATH=$X/Library/Frameworks $L/xct/usr/bin/xctest \
    -XCTest "macprovider_cliTests.CBDecodeIsolationProbeTests/testServedModelVerifyRowsMatchTheirLoneLogitsBitwise" .build/debug/phase3-binaryPackageTests.xctest > $OUT/$1-a3b-fused.log 2>&1 )
  echo "$1 exit=$? start=$s end=$(date +%s) $(grep -h "Executed 1 test" $OUT/$1-a3b-fused.log | tail -1)"
done
$L/tput.sh $OUT a3b-main main a3b 2,4,8,16
$L/tput.sh $OUT a3b-narrowed after a3b 2,4,8,16
SHAPE="512 128 90 20" $L/tput.sh $OUT q27b-main main q27b 1,2,4,8,16
SHAPE="512 128 90 20" $L/tput.sh $OUT q27b-narrowed after q27b 1,2,4,8,16
echo "WINDOW4_DONE $(date -u +%T) out=$OUT"
