# Lock initializer descriptor ownership reproduction

The failing initializer assigned its only stored property before throwing. Swift therefore ran `deinit` after the explicit failure close, potentially closing a descriptor another thread had reused. The correction assigns the stored descriptor only after successful lock acquisition.

This isolated reproduction uses only a private temporary directory and an explicit minimal environment. It deliberately reuses the freed descriptor number without overwriting any live descriptor. It proves the prior constructor closes unrelated evidence and the corrected constructor preserves it. The source is independent of the full package; the actual implementation regression additionally exercises `ModelCatalogFileLock`.

Command (save the source below as `/tmp/lock-init-descriptor-proof.swift`):

```sh
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/swift /tmp/lock-init-descriptor-proof.swift
```

Observed exit status: `0`.

```text
Prior constructor closes reused unrelated descriptor: reproduced
Assign-on-success constructor preserves reused descriptor: passed
```

```swift
import Darwin
import Foundation

enum Busy: Error { case held }
final class PriorLock {
    let descriptor: Int32
    init(_ path: String, afterClose: (Int32) -> Void) throws {
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Busy.held }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); afterClose(descriptor); throw Busy.held
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
final class FixedLock {
    let descriptor: Int32
    init(_ path: String, afterClose: (Int32) -> Void) throws {
        let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { throw Busy.held }
        do {
            guard flock(opened, LOCK_EX | LOCK_NB) == 0 else { throw Busy.held }
            descriptor = opened
        } catch { close(opened); afterClose(opened); throw error }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: root) }
let path = root.appendingPathComponent("lock").path
let held = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
precondition(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
defer { close(held) }
let source = open(root.appendingPathComponent("evidence").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
precondition(source >= 0)
defer { close(source) }
var reused: Int32 = -1
let reuse: (Int32) -> Void = { closed in
    reused = fcntl(source, F_DUPFD_CLOEXEC, closed)
    precondition(reused == closed)
}
do { _ = try PriorLock(path, afterClose: reuse); preconditionFailure() } catch {}
precondition(fcntl(reused, F_GETFD) == -1)
print("Prior constructor closes reused unrelated descriptor: reproduced")
do { _ = try FixedLock(path, afterClose: reuse); preconditionFailure() } catch {}
precondition(fcntl(reused, F_GETFD) != -1)
close(reused)
print("Assign-on-success constructor preserves reused descriptor: passed")
```

The coordinated Swift27 run separately passed all seven focused methods in 39.591 seconds, including the actual descriptor regression, previously failing cancellation startup, measured preparation/recommendation owner, contention bounds, exact terminal delta and queued-successor behavior. This focused result does not replace the pending full crash/binding/retention matrix.
