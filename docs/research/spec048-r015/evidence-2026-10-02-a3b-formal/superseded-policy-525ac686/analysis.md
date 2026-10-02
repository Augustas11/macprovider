| Cell | Status | Blocks | Decode ratio | Decode LB | TTFT UB | ITL UB | Rejection UB | E2E ratio (info) | Hard failures |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| s1-p1536-o128 | PASS | 10/10 | 1.277 | 0.267637 | 0.0493022 | -0.90516 | 0 | 1.128 | - |
| s1-p1536-o512 | PASS | 10/10 | 1.261 | 0.244092 | 0.0490439 | -0.904705 | 0 | 1.208 | - |
| s1-p4096-o128 | FAIL | 10/10 | 1 | -0.00416984 | 0.0165802 | 0.00567608 | 0 | 1.001 | native_mtp_proposals_missing,native_mtp_target_forwards_missing |
| s1-p4096-o512 | FAIL | 10/10 | 1.001 | -0.00192421 | 0.0146102 | 0.00520197 | 0 | 1.001 | native_mtp_proposals_missing,native_mtp_target_forwards_missing |
| s2-p1536-o512 | PASS | 10/10 | 0.9973 | -0.00661975 | 0.0230584 | 0.00375794 | 0 | 0.9923 | - |
| s8-p1536-o512 | FAIL | 10/10 | 0.9974 | -0.0228243 | 0.0129981 | 0.0166541 | 0 | 0.999 | sustained_missing,sustained_incomplete: 0/1800 seconds |
