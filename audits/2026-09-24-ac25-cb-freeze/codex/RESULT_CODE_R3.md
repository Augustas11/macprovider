codex
No runtime correctness findings in `b332156b`.

- `ContinuousBatchScheduler.swift:2247-2251`: expiry occurs before removal; after `await`, the loop rechecks `waiting`, so actor reentrancy cannot dereference stale state.
- `:1640-1666`: stale wakes remain guarded; expiry removes the deadline, releases the replay claim, resumes waiters with timeout, and creates no terminal/settlement result.
- Cancellation and drain paths remove queued work safely; bounded `attempts` prevents spin.
- Existing tests pass: all 9 `testAC25*`; full scheduler suite: 79 passed, 4 skipped.

M1 — regression test gap, `ContinuousBatchSchedulerTests.swift:2104-2106, 2160-2168`: the stale-timeout test always makes `late` fail with `capacityExceeded`, so it can never observe an overdue request being admitted. A regression that admits the request after the bounce but before the zero-delay timeout would still pass this test.

VERDICT: FAIL (0/0/1)
diff --git a/phase3-binary/Package.resolved b/phase3-binary/Package.resolved
index bb1482bc90a07f87445ff61629a8f6177ff82ec8..8d3b0b6fd9c44023cc538cc2b217e0d36a8dd6e0
--- a/phase3-binary/Package.resolved
+++ b/phase3-binary/Package.resolved
@@ -1,6 +1,15 @@
 {
   "pins" : [
     {
+      "identity" : "async-http-client",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/swift-server/async-http-client.git",
+      "state" : {
+        "revision" : "f95c908967e98c68c5ce3fd61a7974e7e869e303",
+        "version" : "1.36.1"
+      }
+    },
+    {
       "identity" : "eventsource",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/mattt/EventSource.git",
@@ -28,6 +37,15 @@
       }
     },
     {
+      "identity" : "swift-algorithms",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-algorithms.git",
+      "state" : {
+        "revision" : "87e50f483c54e6efd60e885f7f5aa946cee68023",
+        "version" : "1.2.1"
+      }
+    },
+    {
       "identity" : "swift-argument-parser",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/apple/swift-argument-parser.git",
@@ -46,6 +64,15 @@
       }
     },
     {
+      "identity" : "swift-async-algorithms",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-async-algorithms.git",
+      "state" : {
+        "revision" : "3da39bbc4e687d4192af7c9cf4eab805745a0b9c",
+        "version" : "1.1.5"
+      }
+    },
+    {
       "identity" : "swift-atomics",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/apple/swift-atomics.git",
@@ -55,6 +82,15 @@
       }
     },
     {
+      "identity" : "swift-certificates",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-certificates.git",
+      "state" : {
+        "revision" : "c8aece90ea05f9866bd392a5bf13b5cae56c0e03",
+        "version" : "1.20.0"
+      }
+    },
+    {
       "identity" : "swift-collections",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/apple/swift-collections.git",
@@ -73,6 +109,33 @@
       }
     },
     {
+      "identity" : "swift-distributed-tracing",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-distributed-tracing.git",
+      "state" : {
+        "revision" : "dc4030184203ffafbb2ec614352487235d747fe0",
+        "version" : "1.4.1"
+      }
+    },
+    {
+      "identity" : "swift-http-structured-headers",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-http-structured-headers.git",
+      "state" : {
+        "revision" : "933538faa42c432d385f02e07df0ace7c5ecfc47",
+        "version" : "1.7.0"
+      }
+    },
+    {
+      "identity" : "swift-http-types",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-http-types.git",
+      "state" : {
+        "revision" : "db774a277f60063a32d854f2980299caf06da041",
+        "version" : "1.6.0"
+      }
+    },
+    {
       "identity" : "swift-huggingface",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/huggingface/swift-huggingface.git",
@@ -91,6 +154,15 @@
       }
     },
     {
+      "identity" : "swift-log",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-log.git",
+      "state" : {
+        "revision" : "3ffafb9722d5d918c614feb496c8789a3b59d222",
+        "version" : "1.15.0"
+      }
+    },
+    {
       "identity" : "swift-nio",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/apple/swift-nio.git",
@@ -100,6 +172,42 @@
       }
     },
     {
+      "identity" : "swift-nio-extras",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-extras.git",
+      "state" : {
+        "revision" : "3078359149adac3dd1255621a041e361e3f0edd1",
+        "version" : "1.35.0"
+      }
+    },
+    {
+      "identity" : "swift-nio-http2",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-http2.git",
+      "state" : {
+        "revision" : "0f3e54e29c944c2e835ad52159da7d9e1c94ac69",
+        "version" : "1.46.0"
+      }
+    },
+    {
+      "identity" : "swift-nio-ssl",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-ssl.git",
+      "state" : {
+        "revision" : "03827c1a9fdb2b6b00a4e93ede8861520263af8c",
+        "version" : "2.37.4"
+      }
+    },
+    {
+      "identity" : "swift-nio-transport-services",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-nio-transport-services.git",
+      "state" : {
+        "revision" : "67787bb645a5e67d2edcdfbe48a216cc549222d5",
+        "version" : "1.28.0"
+      }
+    },
+    {
       "identity" : "swift-numerics",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/apple/swift-numerics",
@@ -109,6 +217,24 @@
       }
     },
     {
+      "identity" : "swift-service-context",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/apple/swift-service-context.git",
+      "state" : {
+        "revision" : "d0997351b0c7779017f88e7a93bc30a1878d7f29",
+        "version" : "1.3.0"
+      }
+    },
+    {
+      "identity" : "swift-service-lifecycle",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/swift-server/swift-service-lifecycle.git",
+      "state" : {
+        "revision" : "7f9326b0326ff86e3646295ea6e891f68c471c5e",
+        "version" : "2.12.0"
+      }
+    },
+    {
       "identity" : "swift-syntax",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/swiftlang/swift-syntax.git",
@@ -136,6 +262,15 @@
       }
     },
     {
+      "identity" : "swift-xet",
+      "kind" : "remoteSourceControl",
+      "location" : "https://github.com/huggingface/swift-xet.git",
+      "state" : {
+        "revision" : "341bfd4172f6a57119bfd49bafa11cf5d21fab75",
+        "version" : "0.2.3"
+      }
+    },
+    {
       "identity" : "yams",
       "kind" : "remoteSourceControl",
       "location" : "https://github.com/jpsim/Yams.git",

