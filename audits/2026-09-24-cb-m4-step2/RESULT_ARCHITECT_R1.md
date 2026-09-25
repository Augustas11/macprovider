codex
Architecture audit of `f9a71a3b2`: one MEDIUM rollout/spec-conformance finding.

Finding M-1 — pre-AC-26 canary admission conflicts with the normative gate

- Evidence: [`ModelRuntime.swift:3974-3985`](...): with `continuousBatchingCachedTurns=true`, a usable positive cached hit is admitted in both `.canary` and `.on`.
- [`SPEC-038:982-997`](...): AC-26 requires packaged gateway/relay proof before positive cached turns enter canary.
- [`SPEC-039:550-552`](...): retained or positive-credit hybrid requests remain serial until recurrent handoff proof.
- [`continuous-batching-enable-gate.md:125-127`](...): the runbook simultaneously says positive hits stay serial until AC-26 and that the flag enables them, creating conflicting rollout guidance.

Scenario: a live canary provider with the flag enabled and a retained hybrid checkpoint admits a positive cached follow-up before receipt/settlement relay proof exists.

Fix: keep ordinary `.canary` positive-hit admission fenced until an explicit per-tuple packaged AC-26 proof gate is recorded; reserve any pre-proof exercise for an unmistakably test-only harness path. Align SPEC-038, SPEC-039, and the runbook.

The default-off behavior, step-1 serial/materialize fallback, FR-PKV10 ownership, trim/reattach semantics, and checkpoint handling otherwise conform. Spec index validation passed.

Existing-test evidence:

- 90 scheduler tests passed; 4 skipped due unavailable MLX metallib.
- 36 FR-PKV allocator tests passed.
- 6 cache, 4 configuration, and 4 mixed-cache tests passed; mixed-cache tests were skipped where MLX was unavailable.
- `gen_spec_index.py --check` passed.

No malformed payloads were constructed. The read-only `$analyze` workflow was used to structure evidence and separate confirmed behavior from inference.

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

