import AppKit
import Darwin
import SwiftTerm

/// Own the PTY channel and descriptor; SwiftTerm 1.2.5 LocalProcess cannot
/// coordinate channel shutdown with closing its original master descriptor.
@MainActor
final class EmbeddedProcessTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
    // SwiftTerm predates actor annotations; terminal callbacks run on the main queue.
    private(set) lazy var process = EmbeddedTerminalProcess(delegate: self)
    var onTermination: ((Int32?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
    }

    func startProcess(executable: String, args: [String], environment: [String], currentDirectory: String? = nil) {
        if let currentDirectory {
            // 1.2.5 cannot chdir in the forked child. A positional-argument
            // trampoline avoids parent-process chdir and shell interpolation;
            // exec preserves the PTY leader and its process group.
            process.startProcess(executable: "/bin/sh",
                                 args: ["-c", "cd -- \"$1\" || exit 1; shift; exec \"$@\"", "malibu-terminal", currentDirectory, executable] + args,
                                 environment: environment)
        } else {
            process.startProcess(executable: executable, args: args, environment: environment)
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        feed(byteArray: slice)
    }

    func getWindowSize() -> winsize {
        let terminal = getTerminal()
        return winsize(ws_row: UInt16(clamping: terminal.rows), ws_col: UInt16(clamping: terminal.cols),
                       ws_xpixel: UInt16(clamping: Int(max(0, frame.width))),
                       ws_ypixel: UInt16(clamping: Int(max(0, frame.height))))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard process.running else { return }
        var size = getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func processDidExit(exitCode: Int32?) {
        onTermination?(exitCode)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        // SwiftTerm invokes this delegate for OSC 52 received from terminal
        // output. Only explicit user Copy may write the system pasteboard;
        // TerminalView.copy(_:) handles that selection action independently.
    }
}

/// Use SwiftTerm's forkpty helper, but keep descriptor ownership in the IO
/// cleanup handler. DispatchIO.close alone does not close a borrowed descriptor.
@MainActor
final class EmbeddedTerminalProcess {
    private weak var delegate: EmbeddedProcessTerminalView?
    private var channel: DispatchIO?
    private var monitor: DispatchSourceProcess?
    private(set) var childfd: Int32 = -1
    private(set) var shellPid: pid_t = 0
    private(set) var running = false

    init(delegate: EmbeddedProcessTerminalView) { self.delegate = delegate }

    func startProcess(executable: String, args: [String], environment: [String]) {
        guard shellPid == 0 else { return }
        var size = delegate?.getWindowSize() ?? winsize()
        guard let (pid, descriptor) = PseudoTerminalHelpers.fork(andExec: executable,
            args: [executable] + args, env: environment, desiredWindowSize: &size) else { return }
        shellPid = pid
        childfd = descriptor
        running = true
        let io = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: .main) { _ in
            // Runs only after all channel operations relinquish the descriptor.
            // Capture the original master, never the mutable childfd sentinel.
            _ = Darwin.close(descriptor)
        }
        channel = io
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: Int.max, queue: .main) { [weak self] done, data, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.delegate?.dataReceived(slice: Array(data)[...]) }
                if done || error != 0 { self.closeIO() }
            }
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.monitor?.cancel()
                self.monitor = nil
                self.reapExitedChild(pid)
            }
        }
        monitor = source
        source.resume()
    }

    private func reapExitedChild(_ pid: pid_t) {
        switch Self.pollChildExit(pid) {
        case .pending:
            // An exit notification can precede a waitable status; signals can
            // also interrupt waitpid. Yield instead of losing that status or
            // blocking AppKit while waiting for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.reapExitedChild(pid)
            }
        case .finished(let status):
            running = false
            // Let EOF drain buffered terminal output before closing IO.
            delegate?.processDidExit(exitCode: status)
        }
    }

    enum ChildExitPoll: Equatable {
        case pending
        case finished(Int32?)
    }

    static func pollChildExit(
        _ pid: pid_t,
        wait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { waitpid($0, $1, $2) }
    ) -> ChildExitPoll {
        var status: Int32 = 0
        let result = wait(pid, &status, WNOHANG)
        let waitError = errno
        if result == 0 || (result == -1 && waitError == EINTR) { return .pending }
        return .finished(result == pid ? status : nil)
    }

    func send(data: ArraySlice<UInt8>) {
        guard running, let channel else { return }
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: .main) { _, _, _ in }
    }

    func closeIO() {
        guard let channel else { return }
        self.channel = nil
        childfd = -1
        channel.close(flags: .stop)
    }

    deinit {
        channel?.close(flags: .stop)
        monitor?.cancel()
    }
}
