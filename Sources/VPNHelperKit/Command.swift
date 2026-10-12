import Foundation

/// Runs a system tool and collects its output. Never through a shell: the
/// arguments go to execve as they are, so nothing in them is interpreted.
public enum Command {
    public struct Output: Sendable {
        public var status: Int32
        public var text: String
        public var ok: Bool { status == 0 }
    }

    struct Failed: Error, LocalizedError {
        var tool: String
        var output: String
        var errorDescription: String? { "\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
    }

    /// - Parameters:
    ///   - input: written to stdin, then stdin is closed.
    ///   - timeout: the tool is killed after this long.
    @discardableResult
    public static func run(_ tool: String, _ args: [String], input: String? = nil, timeout: Double = 15) async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let inPipe = Pipe()
            p.standardInput = input != nil ? inPipe : FileHandle.nullDevice

            // Read output concurrently so a chatty tool cannot block on a full pipe.
            let collected = Collected()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { collected.append(d) }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                collected.append(rest)
                cont.resume(returning: Output(status: proc.terminationStatus, text: collected.string))
            }
            do {
                try p.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: Output(status: -1, text: "cannot run \(tool): \(error.localizedDescription)"))
                return
            }
            if let input {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
