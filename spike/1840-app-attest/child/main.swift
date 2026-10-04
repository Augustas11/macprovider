import Foundation

// Sleeps so a parent can inspect this process with SecCode. The spike app
// passes `--spike-sleep 5`. A missing argument keeps the process alive long
// enough for a manual check. This file stays top-level code because swiftc
// treats a file named main.swift as the program entry.
var seconds = 30
let arguments = CommandLine.arguments
var index = 1
while index < arguments.count {
    if arguments[index] == "--spike-sleep",
       index + 1 < arguments.count,
       let value = Int(arguments[index + 1]),
       value >= 0,
       value <= 3600 {
        seconds = value
        break
    }
    index += 1
}
Thread.sleep(forTimeInterval: TimeInterval(seconds))
