import Foundation
import Darwin

@MainActor public final class RemoteEngine {
    var process: Process?, child: Int32 = 0
    public init() {}
    public var running: Bool { process?.isRunning == true }
    public func stop() {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier, child = self.child
        if child > 0 { kill(-child, SIGTERM); kill(child, SIGTERM) }
        kill(-pid, SIGTERM); p.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if child > 0, kill(-child, 0) == 0 { kill(-child, SIGKILL) }
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
    public func run(executable: URL, request: [String: Any], temporary: URL,
                    event: @escaping ([String: Any]) -> Void) async throws {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary); process = nil; child = 0 }
        let payload = try RemoteJSON.data(request)
        var buffer = Data(), reportedError = false
        let p = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process = p; p.executableURL = executable; p.standardInput = input; p.standardOutput = output; p.standardError = errors
        var env = ProcessInfo.processInfo.environment; env.removeValue(forKey: "OLLAMA_API_KEY")
        env["TMPDIR"] = temporary.path + "/"; env["AUDIOBOOK_FFMPEG"] = request["ffmpeg"] as? String; env["AUDIOBOOK_FFPROBE"] = request["ffprobe"] as? String
        p.environment = env; p.qualityOfService = .userInitiated
        // One serial reader prevents termination from overtaking the last result event.
        do { try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do { try p.run(); try input.fileHandleForWriting.write(contentsOf: payload); try input.fileHandleForWriting.close() }
                catch { stop(); continuation.resume(throwing: RemoteError("Не удалось запустить движок")); return }
                DispatchQueue.global().async {
                    // Drain stderr concurrently so a full pipe cannot stall generation. Never log raw secrets.
                    DispatchQueue.global().async { while !errors.fileHandleForReading.availableData.isEmpty {} }
                    while true {
                        let data = output.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        DispatchQueue.main.sync {
                            buffer.append(data)
                            while let newline = buffer.firstIndex(of: 10) {
                                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                                guard let object = try? RemoteJSON.object(Data(line)) else { continue }
                                if object["type"] as? String == "child" { self.child = (object["pid"] as? NSNumber)?.int32Value ?? 0 }
                                if object["type"] as? String == "error" { reportedError = true }
                                event(object)
                            }
                        }
                    }
                    p.waitUntilExit()
                    DispatchQueue.main.async {
                        if p.terminationStatus == 0 && !reportedError { continuation.resume() }
                        else { continuation.resume(throwing: RemoteError("Обработка книги не завершена. Проект и прогресс сохранены.")) }
                    }
                }
            }
        }, onCancel: { Task { @MainActor in self.stop() } })
        } catch {
            if Task.isCancelled { await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { c.resume() } }; throw CancellationError() }
            throw error
        }
        if Task.isCancelled {
            // Let process-group cancellation finish before releasing the exclusive engine reservation.
            await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { c.resume() } }
            throw CancellationError()
        }
    }
}
