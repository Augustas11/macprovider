#!/bin/bash
C=<studio-home>/lab-332/cs
$C/run-repro.sh old2 B-old-churn LAB_REPEAT=6 LAB_CHURN_GB=16
$C/run-repro.sh old2 C-old-alias MLX_LAB_ALIAS=1
$C/run-repro.sh new2 D-new-alias MLX_LAB_ALIAS=1
$C/run-repro.sh new2 E-new-churn LAB_REPEAT=6 LAB_CHURN_GB=16
echo SEQ1_DONE
