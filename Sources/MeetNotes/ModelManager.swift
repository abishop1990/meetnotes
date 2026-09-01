import Foundation

final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var present: Bool = Transcriber.modelPresent
    @Published var progress: Double? = nil
    @Published var error: String? = nil

    private var session: URLSession?

    func refresh() { present = Transcriber.modelPresent }

    func download() {
        guard progress == nil else { return }
        error = nil
        progress = 0
        let cfg = URLSessionConfiguration.default
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: Settings.modelDownloadURL).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = Settings.modelURL
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.progress = nil; self.present = true }
        } catch {
            DispatchQueue.main.async { self.progress = nil; self.error = error.localizedDescription }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { self.progress = nil; self.error = error.localizedDescription }
    }
}
