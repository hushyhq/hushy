import Foundation
@testable import Murmur
import Testing

@Suite("SingleInstance")
struct SingleInstanceTests {
    private typealias App = SingleInstance.RunningApp

    @Test func yieldsToTheBundledAppAlreadyRunning() {
        let running = [App(pid: 10, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy"),
                       App(pid: 20, bundleIdentifier: nil, executableName: "Murmur")]
        #expect(SingleInstance.instanceToYieldTo(currentPID: 20, running: running)?.pid == 10)
    }

    @Test func yieldsToAnUnbundledDebugBuild() {
        let running = [App(pid: 11, bundleIdentifier: nil, executableName: "Murmur")]
        #expect(SingleInstance.instanceToYieldTo(currentPID: 99, running: running)?.pid == 11)
    }

    @Test func ignoresItselfAndUnrelatedApps() {
        let running = [App(pid: 5, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy"),
                       App(pid: 6, bundleIdentifier: "com.apple.Safari", executableName: "Safari"),
                       App(pid: 7, bundleIdentifier: "com.example.HushyHelper", executableName: "HushyHelper")]
        #expect(SingleInstance.instanceToYieldTo(currentPID: 5, running: running) == nil)
    }

    // MARK: Pill previews

    @Test("a real Hushy does not yield to a pill preview, whichever started first")
    func previewIsNotAnotherHushy() {
        let preview = App(pid: 30, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy", isPillPreview: true)
        #expect(SingleInstance.instanceToYieldTo(currentPID: 40, running: [preview]) == nil)
        let unbundled = App(pid: 31, bundleIdentifier: nil, executableName: "Murmur", isPillPreview: true)
        #expect(SingleInstance.instanceToYieldTo(currentPID: 40, running: [unbundled]) == nil)
    }

    @Test("with a preview open, a second real Hushy still yields to the first real one")
    func realInstancesStillYield() {
        let running = [App(pid: 30, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy", isPillPreview: true),
                       App(pid: 10, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy")]
        #expect(SingleInstance.instanceToYieldTo(currentPID: 40, running: running)?.pid == 10)
    }

    @Test("a Hushy process is a preview only when it was launched with the preview flag")
    func markedFromLaunchArguments() {
        let hushy = App(pid: 30, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy")
        #expect(SingleInstance.marked(hushy) { _ in ["/Applications/Hushy.app/Contents/MacOS/Hushy", "--pill-preview"] }.isPillPreview)
        #expect(!SingleInstance.marked(hushy) { _ in ["/Applications/Hushy.app/Contents/MacOS/Hushy"] }.isPillPreview)
        #expect(!SingleInstance.marked(hushy) { _ in ["/Applications/Hushy.app/Contents/MacOS/Hushy", "--snapshots", "/tmp/x"] }.isPillPreview)
    }

    @Test("a process whose arguments cannot be read counts as a real Hushy, and other apps are never asked")
    func unreadableArgumentsAreNotAPreview() {
        let hushy = App(pid: 30, bundleIdentifier: "app.hushy.Hushy", executableName: "Hushy")
        #expect(!SingleInstance.marked(hushy) { _ in nil }.isPillPreview)
        var asked = false
        let safari = App(pid: 6, bundleIdentifier: "com.apple.Safari", executableName: "Safari")
        let marked = SingleInstance.marked(safari) { _ in asked = true; return ["Safari", "--pill-preview"] }
        #expect(!asked)
        #expect(!marked.isPillPreview)
    }

    // MARK: Launch arguments of another process

    @Test("the system's argument buffer is read as the arguments, not the path or the environment")
    func parsesArgumentBuffer() {
        var bytes: [UInt8] = [3, 0, 0, 0]
        bytes += Array("/Applications/Hushy.app/Contents/MacOS/Hushy".utf8) + [0, 0, 0, 0]
        for argument in ["Hushy", "--pill-preview", "--loop"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("HOME=/Users/someone".utf8) + [0]
        #expect(ProcessArguments.parse(bytes) == ["Hushy", "--pill-preview", "--loop"])
        #expect(ProcessArguments.parse([]) == nil)
        #expect(ProcessArguments.parse([9, 0, 0, 0, 65, 0, 66, 0]) == nil, "fewer arguments than the count promises")
    }

    @Test("this process's own arguments can be read back")
    func readsOwnArguments() throws {
        let own = try #require(ProcessArguments.of(pid: getpid()))
        #expect(own.first == CommandLine.arguments.first)
        #expect(own.count == CommandLine.arguments.count)
        #expect(ProcessArguments.of(pid: -1) == nil)
    }
}
