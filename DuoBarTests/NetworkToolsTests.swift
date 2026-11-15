import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class NetworkToolsTests: XCTestCase {
    private let wired = NetworkStatus(
        isAvailable: true, isConnected: true, transport: .ethernet,
        interfaceName: "en7", isWiFiPoweredOn: true, ssid: nil, rssi: nil
    )

    // MARK: Adapter names

    func testWiredDetailPrefersTheAdapterName() {
        XCTAssertEqual(NetworkStatusText.detail(for: wired, hasPowerControlError: false, adapterName: "USB 10/100/1000 LAN"), "USB 10/100/1000 LAN")
        XCTAssertEqual(NetworkStatusText.detail(for: wired, hasPowerControlError: false), "en7")
        var wifi = wired
        wifi.transport = .wifi
        wifi.ssid = "Home"
        XCTAssertEqual(NetworkStatusText.detail(for: wifi, hasPowerControlError: false, adapterName: "Wi-Fi"), "Home")
    }

    func testModuleReadsAdapterNamesOnlyWhileOpen() {
        let names = FakeAdapterNameReader(["en7": "USB 10/100/1000 LAN"])
        let module = NetworkModule(reader: FakeWiFiDetailsReader(), addressReader: FakeAddressReader(), adapterNameReader: names, interval: 60)
        spin(0.05)
        XCTAssertEqual(names.reads, 0, "nothing is read with the popover closed")

        module.popoverDidOpen()
        waitUntil { module.adapterName(for: "en7") != nil }
        XCTAssertEqual(module.adapterName(for: "en7"), "USB 10/100/1000 LAN")
        XCTAssertNil(module.adapterName(for: "en0"))
        XCTAssertNil(module.adapterName(for: nil))
        module.popoverDidClose()
    }

    func testRealAdapterReaderNamesTheBuiltInInterfaces() {
        let names = SCNetworkAdapterNameReader().names()
        XCTAssertFalse(names.values.contains(""))
        XCTAssertFalse(names.contains { $0.key == $0.value })
    }

    // MARK: Quoting

    func testQuoting() {
        XCTAssertEqual(ShellQuoting.shell("/tmp/a b"), "'/tmp/a b'")
        XCTAssertEqual(ShellQuoting.shell("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuoting.appleScriptString(#"say "hi" \ now"#), #"say \"hi\" \\ now"#)
        let script = ShellQuoting.privilegedScript("echo 'x'", prompt: "Why")
        XCTAssertEqual(script, #"do shell script "echo 'x'" with prompt "Why" with administrator privileges"#)
    }

    func testOsascriptCancelIsRecognized() {
        XCTAssertEqual(OsascriptPrivilegedRunner.error(fromOutput: "execution error: User canceled. (-128)"), .cancelled)
        XCTAssertEqual(OsascriptPrivilegedRunner.error(fromOutput: "boom"), .failed("boom"))
    }

    // MARK: Flush DNS

    func testFlushDNSNotifiesOnSuccess() {
        let runner = FakePrivilegedRunner(result: .success(()))
        let notifier = FakeNotifier()
        var errors: [String] = []
        let tools = NetworkTools(runner: runner, notifier: notifier, showError: { errors.append($0) })
        tools.flushDNS()
        waitUntil { !notifier.titles.isEmpty }
        XCTAssertEqual(runner.commands, [NetworkTools.flushDNSCommand])
        XCTAssertEqual(notifier.titles, [localized("DNS cache flushed")])
        XCTAssertTrue(errors.isEmpty)
    }

    func testFlushDNSCancelShowsNothingAndFailureShowsError() {
        let notifier = FakeNotifier()
        var errors: [String] = []
        let cancelled = NetworkTools(runner: FakePrivilegedRunner(result: .failure(.cancelled)), notifier: notifier, showError: { errors.append($0) })
        cancelled.flushDNS()
        spin(0.1)
        XCTAssertTrue(notifier.titles.isEmpty)
        XCTAssertTrue(errors.isEmpty)

        let failing = NetworkTools(runner: FakePrivilegedRunner(result: .failure(.failed("nope"))), notifier: notifier, showError: { errors.append($0) })
        failing.flushDNS()
        waitUntil { !errors.isEmpty }
        XCTAssertEqual(errors, ["nope"])
        XCTAssertTrue(notifier.titles.isEmpty)
    }

    // MARK: Hosts editor

    func testHostsEditorSavesThroughOnePrivilegedCommand() {
        let file = FakeHostsFile("127.0.0.1 localhost\n")
        let runner = FakePrivilegedRunner(result: .success(())) { file.contents = file.staged ?? file.contents }
        let model = HostsEditorModel(runner: runner, file: file)
        var saved = 0
        model.onSaved = { saved += 1 }
        model.load()
        XCTAssertFalse(model.canSave, "nothing to save before an edit")

        model.text += "# test\n"
        XCTAssertTrue(model.canSave)
        var done = false
        model.save { done = true }
        waitUntil { done }

        let command = try? XCTUnwrap(runner.commands.first)
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertTrue(command?.hasPrefix("cp '") == true)
        XCTAssertTrue(command?.contains("/etc/hosts && chmod 644 /etc/hosts && ") == true)
        XCTAssertTrue(command?.hasSuffix(NetworkTools.flushDNSCommand) == true)
        XCTAssertEqual(model.original, "127.0.0.1 localhost\n# test\n", "the file is read again after saving")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(file.removed, 1, "the temporary file is removed")
        XCTAssertEqual(saved, 1, "the window closes after saving")
    }

    func testHostsEditorKeepsEditsWhenSavingFails() {
        let file = FakeHostsFile("a\n")
        let model = HostsEditorModel(runner: FakePrivilegedRunner(result: .failure(.failed("denied"))), file: file)
        model.onSaved = { XCTFail("the window stays open when saving fails") }
        model.load()
        model.text = "b\n"
        var done = false
        model.save { done = true }
        waitUntil { done }
        XCTAssertEqual(model.text, "b\n")
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.errorMessage)

        model.revert()
        XCTAssertEqual(model.text, "a\n")
        XCTAssertNil(model.errorMessage)
    }

    func testHostsEditorCancelKeepsEditsWithoutError() {
        let file = FakeHostsFile("a\n")
        let model = HostsEditorModel(runner: FakePrivilegedRunner(result: .failure(.cancelled)), file: file)
        model.load()
        model.text = "b\n"
        var done = false
        model.save { done = true }
        waitUntil { done }
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.errorMessage)
    }

    func testRenderWiredDetailAndEditor() throws {
        let model = HostsEditorModel(runner: FakePrivilegedRunner(result: .success(())), file: FakeHostsFile("127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1\tlocalhost\n"))
        model.load()
        let view = HostsEditorView(model: model).frame(width: 520, height: 320)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-HostsEditor.png"), options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.01) }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class FakeAdapterNameReader: NetworkAdapterNameReading, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String: String]
    private var count = 0

    init(_ values: [String: String]) { self.values = values }

    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }

    func names() -> [String: String] {
        lock.lock(); count += 1; lock.unlock()
        return values
    }
}

final class FakePrivilegedRunner: PrivilegedCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<Void, PrivilegedCommandError>
    private let onRun: () -> Void
    private var recorded: [String] = []

    init(result: Result<Void, PrivilegedCommandError>, onRun: @escaping () -> Void = {}) {
        self.result = result
        self.onRun = onRun
    }

    var commands: [String] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ command: String, prompt: String, completion: @escaping @Sendable (Result<Void, PrivilegedCommandError>) -> Void) {
        lock.lock(); recorded.append(command); lock.unlock()
        let result = result
        let onRun = onRun
        DispatchQueue.global().async {
            if case .success = result { onRun() }
            completion(result)
        }
    }
}

@MainActor
final class FakeNotifier: NetworkToolsNotifying {
    private(set) var titles: [String] = []
    func notify(title: String) { titles.append(title) }
}

final class FakeHostsFile: HostsFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: String
    private var _staged: String?
    private var _removed = 0

    init(_ contents: String) { _contents = contents }

    var contents: String {
        get { lock.lock(); defer { lock.unlock() }; return _contents }
        set { lock.lock(); _contents = newValue; lock.unlock() }
    }
    var staged: String? { lock.lock(); defer { lock.unlock() }; return _staged }
    var removed: Int { lock.lock(); defer { lock.unlock() }; return _removed }

    func read() throws -> String { contents }

    func writeTemporary(_ contents: String) throws -> URL {
        lock.lock(); _staged = contents; lock.unlock()
        return URL(fileURLWithPath: "/tmp/duobarplus-hosts-test.txt")
    }

    func removeTemporary(_ url: URL) {
        lock.lock(); _removed += 1; lock.unlock()
    }
}
