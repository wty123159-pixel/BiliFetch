import Foundation

protocol DownloaderServiceDelegate: AnyObject {
    func downloaderDidReceive(line: String)
    func downloaderDidFinish(exitCode: Int32)
}

final class DownloaderService {
    weak var delegate: DownloaderServiceDelegate?
    private let runner = ProcessRunner()

    var isRunning: Bool { runner.isRunning }

    func start(executable: URL, arguments: [String], toolDirectory: URL?) throws {
        try runner.start(
            executable: executable,
            arguments: arguments,
            extraPathDirectories: [toolDirectory].compactMap { $0 },
            onLine: { [weak self] line, _ in
                self?.delegate?.downloaderDidReceive(line: line)
            },
            onFinish: { [weak self] exitCode in
                self?.delegate?.downloaderDidFinish(exitCode: exitCode)
            }
        )
    }

    func cancel() {
        runner.cancel()
    }
}
