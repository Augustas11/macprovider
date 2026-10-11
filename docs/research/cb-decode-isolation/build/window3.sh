#!/bin/bash
# Window 3: served-model bitwise probes on the after debug test build.
# 16 rows of unequal length (crossing 1024 and 16384 keys inside the window)
# decoded in serve-window (16-step) lockstep windows, capped (11 + 5 rows per
# forward) and uncapped (16), each row vs alone, A3B fused on/off and 27B;
# then the packed native-MTP verify isolation probe (A3B, 8 rows, width 3).
L=<studio-home>/lab-di; OUT=$L/runs/w3-$(date -u +%Y%m%dT%H%MZ); mkdir -p $OUT
$L/sampler.sh > $OUT/samples.log 2>&1 & SAM=$!; trap 'kill $SAM 2>/dev/null' EXIT
echo "WINDOW3_START $(date -u +%T)"
MD="<studio-home>/Library/Application Support/macprovider/models"
A3B="$MD/mlx-community--Qwen3.6-35B-A3B-4bit/38740b847e4cb78f352aba30aa41c76e08e6eb46/3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1"
Q27="$MD/mlx-community--Qwen3.6-27B-4bit/c000ac2c2057d94be3fa931000c31723aac53282/518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931"
X=<studio-home>/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer
LEN16=300,600,750,901,1019,1100,1501,2000,3000,4095,4500,6000,8185,9000,12000,16380
run() { # name model test [VAR=value ...]
  local n=$1 m=$2 t=$3; shift 3
  s=$(date +%s)
  ( cd $L/after && env "$@" MACPROVIDER_DECODE_ISOLATION_MODEL="$m" DYLD_LIBRARY_PATH=$X/usr/lib DYLD_FRAMEWORK_PATH=$X/Library/Frameworks \
    $L/xct/usr/bin/xctest -XCTest "macprovider_cliTests.CBDecodeIsolationProbeTests/$t" .build/debug/phase3-binaryPackageTests.xctest > $OUT/$n.log 2>&1 )
  echo "$n exit=$? start=$s end=$(date +%s) $(grep -h "Executed 1 test" $OUT/$n.log | tail -1)"
}
U=MACPROVIDER_DECODE_ISOLATION_ROWS_PER_FORWARD=0
run decode16-a3b-fused-capped "$A3B" testServedModelDecodeRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_LENGTHS=$LEN16
run decode16-a3b-fused-uncapped "$A3B" testServedModelDecodeRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_LENGTHS=$LEN16 $U
run decode16-a3b-stock-capped "$A3B" testServedModelDecodeRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_LENGTHS=$LEN16 MLX_LM_QWEN35_FUSED_MOE=0
run decode16-a3b-stock-uncapped "$A3B" testServedModelDecodeRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_LENGTHS=$LEN16 MLX_LM_QWEN35_FUSED_MOE=0 $U
run decode16-q27b-capped "$Q27" testServedModelDecodeRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_LENGTHS=$LEN16
run decode16-q27b-uncapped "$Q27" testServedModelDecodeRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_LENGTHS=$LEN16 $U
run verify8-a3b-fused "$A3B" testServedModelVerifyRowsMatchTheirLoneLogitsBitwise MACPROVIDER_DECODE_ISOLATION_VERIFY=1 MACPROVIDER_DECODE_ISOLATION_LENGTHS=600,901,1501,2000,3000,4500,6000,9000
echo "WINDOW3_DONE $(date -u +%T) out=$OUT"
