import Darwin
import Foundation

enum ProcessRunnerError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "已有任务正在运行"
        }
    }
}

final class ProcessRunner {
    enum Stream {
        case standardOutput
        case standardError
    }

    private final class RunContext {
        let id = UUID()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let lock = NSLock()
        var outputBuffer = ""
        var errorBuffer = ""
        var outputEnded = false
        var errorEnded = false
        var exitCode: Int32?
        var finished = false
    }

    private let callbackQueue: DispatchQueue
    private let stateLock = NSLock()
    private var active: RunContext?
    private var lineHandler: ((String, Stream) -> Void)?
    private var finishHandler: ((Int32) -> Void)?

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    var isRunning: Bool {
        stateLock.withLock { active != nil }
    }

    func start(
        executable: URL,
        arguments: [String],
        extraPathDirectories: [URL] = [],
        onLine: @escaping (String, Stream) -> Void,
        onFinish: @escaping (Int32) -> Void
    ) throws {
        let context = RunContext()

        try stateLock.withLock {
            guard active == nil else { throw ProcessRunnerError.alreadyRunning }
            active = context
            lineHandler = onLine
            finishHandler = onFinish
        }

        context.process.executableURL = executable
        context.process.arguments = arguments
        context.process.standardOutput = context.outputPipe
        context.process.standardError = context.errorPipe

        var environment = ProcessInfo.processInfo.environment
        let paths = extraPathDirectories.map(\.path) + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            environment["PATH"] ?? "/usr/bin:/bin"
        ]
        environment["PATH"] = paths.joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        context.process.environment = environment

        context.outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak context] handle in
            guard let self, let context else { return }
            self.receive(handle.availableData, stream: .standardOutput, context: context)
        }
        context.errorPipe.fileHandleForReading.readabilityHandler = { [weak self, weak context] handle in
            guard let self, let context else { return }
            self.receive(handle.availableData, stream: .standardError, context: context)
        }
        context.process.terminationHandler = { [weak self, weak context] process in
            guard let self, let context else { return }
            self.processTerminated(context: context, exitCode: process.terminationStatus)
        }

        do {
            try context.process.run()
        } catch {
            context.outputPipe.fileHandleForReading.readabilityHandler = nil
            context.errorPipe.fileHandleForReading.readabilityHandler = nil
            stateLock.withLock {
                if active?.id == context.id {
                    active = nil
                    lineHandler = nil
                    finishHandler = nil
                }
            }
            throw error
        }
    }

    func cancel() {
        guard let context = stateLock.withLock({ active }) else { return }
        if context.process.isRunning { context.process.interrupt() }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self, weak context] in
            guard let self, let context, self.isCurrent(context), context.process.isRunning else { return }
            context.process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self, weak context] in
            guard let self, let context, self.isCurrent(context), context.process.isRunning else { return }
            kill(context.process.processIdentifier, SIGKILL)
        }
    }

    private func receive(_ data: Data, stream: Stream, context: RunContext) {
        var lines: [String] = []
        var shouldFinish = false

        context.lock.withLock {
            guard !context.finished else { return }
            if data.isEmpty {
                switch stream {
                case .standardOutput: context.outputEnded = true
                case .standardError: context.errorEnded = true
                }
            } else if let chunk = String(data: data, encoding: .utf8) {
                switch stream {
                case .standardOutput:
                    context.outputBuffer.append(chunk)
                    lines = Self.completeLines(from: &context.outputBuffer)
                case .standardError:
                    context.errorBuffer.append(chunk)
                    lines = Self.completeLines(from: &context.errorBuffer)
                }
            }
            shouldFinish = context.exitCode != nil && context.outputEnded && context.errorEnded
        }

        emit(lines, stream: stream, context: context)
        if shouldFinish { finish(context) }
    }

    private func processTerminated(context: RunContext, exitCode: Int32) {
        var shouldFinish = false
        context.lock.withLock {
            guard !context.finished else { return }
            context.exitCode = exitCode
            shouldFinish = context.outputEnded && context.errorEnded
        }

        if shouldFinish {
            finish(context)
        } else {
            // Never wait indefinitely for a descendant that inherited a pipe.
            // Every subsequent run gets brand-new pipes and buffers.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) { [weak self, weak context] in
                guard let self, let context else { return }
                self.finish(context)
            }
        }
    }

    private func finish(_ context: RunContext) {
        var remainingOutput: [String] = []
        var remainingError: [String] = []
        var code: Int32 = -1

        context.lock.withLock {
            guard !context.finished else { return }
            context.finished = true
            code = context.exitCode ?? -1
            if !context.outputBuffer.isEmpty { remainingOutput = [context.outputBuffer] }
            if !context.errorBuffer.isEmpty { remainingError = [context.errorBuffer] }
            context.outputBuffer = ""
            context.errorBuffer = ""
        }

        context.outputPipe.fileHandleForReading.readabilityHandler = nil
        context.errorPipe.fileHandleForReading.readabilityHandler = nil

        let handlers: (((String, Stream) -> Void)?, ((Int32) -> Void)?) = stateLock.withLock {
            guard active?.id == context.id else { return (nil, nil) }
            active = nil
            let handlers = (lineHandler, finishHandler)
            lineHandler = nil
            finishHandler = nil
            return handlers
        }

        callbackQueue.async {
            remainingOutput.filter { !$0.isEmpty }.forEach { handlers.0?($0, .standardOutput) }
            remainingError.filter { !$0.isEmpty }.forEach { handlers.0?($0, .standardError) }
            handlers.1?(code)
        }
    }

    private func emit(_ lines: [String], stream: Stream, context: RunContext) {
        guard !lines.isEmpty else { return }
        let handler = stateLock.withLock { active?.id == context.id ? lineHandler : nil }
        callbackQueue.async {
            lines.filter { !$0.isEmpty }.forEach { handler?($0, stream) }
        }
    }

    private func isCurrent(_ context: RunContext) -> Bool {
        stateLock.withLock { active?.id == context.id }
    }

    private static func completeLines(from buffer: inout String) -> [String] {
        let parts = buffer.components(separatedBy: .newlines)
        guard parts.count > 1 else { return [] }
        buffer = parts.last ?? ""
        return parts.dropLast().filter { !$0.isEmpty }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
