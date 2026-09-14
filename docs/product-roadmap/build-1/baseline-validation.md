# Build 1 fresh baseline validation

Base: 422fc2f13fc62c1ff8987522f822d9ef856e4a96. These tests exercise preexisting
behavior only; they are not implementation or physical acceptance.

- `swift test --filter 'DurableModelArtifactStoreTests|ModelCatalogEconomicsTests|ModelsSubcommandTests'`
  from phase3-binary: exit 0, **60 XCTest tests, zero failures**. Log:
  baseline-swift.log. The additional Swift Testing runner selected zero tests;
  that line is not counted as evidence. Xcode26.6/Swift6.3.3 on M5 32GiB.
- Native admission discovery agent ran the focused ws/buyer command recorded
  in reviews/admission-discovery.md; both packages passed.
- `xcodegen generate` from phase3-binary/app: exit 0, installed pinned version
  2.45.4. Log baseline-xcodegen.log.
- `xcodebuild test -project Malibu.xcodeproj -scheme Malibu -destination 'platform=macOS' -only-testing:MalibuTests/ModelManagementTests CODE_SIGNING_ALLOWED=NO`
  from phase3-binary/app: exit 0, **96 tests, zero failures** in baseline-xcode.log.

The repo release lock gate requires unavailable Xcode16.4. Swift26.6 pruned
conditional entries from Package.resolved during resolution; original tracked
bytes were restored. No dependency change is part of this task.
