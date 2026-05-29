# Coordinator Test Faults

Small test-only helpers for exercising failure modes that are hard to
reproduce with real providers.

## WS-death-mid-inference

`DeadMidInferenceRelay` returns a buyer relay that reports
`ws.ErrRelayClosed` after the request has been accepted. Coordinator
tests use it to assert `provider_disconnected` fast-fail and failover
behavior.

This helper is compiled only with the `testfaults` build tag. Normal
production builds include only the empty package marker and cannot import
the fault relay by accident.

## Slow-consumer

`SlowReader` wraps an `io.Reader` and sleeps between reads. Integration
tests can attach it to a buyer HTTP client to prove one slow SSE
consumer does not starve unrelated requests.

## Coordinator-OOM / panic

`PanicHandler` is a controlled panic endpoint for fault-injection tests.
It is only compiled when the `testfaults` build tag is present.
