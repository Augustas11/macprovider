import AppKit
import Darwin
import SwiftTerm

/// SwiftTerm 1.2.5's LocalProcessTerminalView hides its process handle. Own the
/// public LocalProcess directly so session cleanup can identity-check its PGID.
@MainActor
final class EmbeddedProcessTerminalView: TerminalView, @preconcurrency TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
    // SwiftTerm predates actor annotations. UI callbacks and LocalProcess's
    // default dispatch queue both deliver these delegate calls on the main queue.
    private(set) lazy var process = LocalProcess(delegate: self)
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

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
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
