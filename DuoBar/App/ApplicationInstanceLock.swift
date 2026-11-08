import Darwin
import Foundation

/// Prevents independently launched copies of DuoBar from each installing a menu-bar item.
final class ApplicationInstanceLock {
    private let lockFileName: String
    private var fileDescriptor: Int32 = -1

    init(lockFileName: String = "com.huglab.duobarplus.instance.lock") {
        self.lockFileName = lockFileName
    }

    func acquire() -> Bool {
        guard fileDescriptor == -1 else { return true }

        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(lockFileName, isDirectory: false)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        return true
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}
