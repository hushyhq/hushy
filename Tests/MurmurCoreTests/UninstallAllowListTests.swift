import Foundation
import Testing
@testable import MurmurCore

/// The check at removal time: a step may remove only a location the planner names in full,
/// whatever the plan in hand says.
@Suite("Uninstall: only named locations are removed")
struct UninstallAllowListTests {
    private let id = UninstallTestHome.bundleIdentifier

    /// A plan with the honest plan's roots and folders, and steps somebody else wrote.
    private func plan(like honest: UninstallPlan, removing targets: [URL]) -> UninstallPlan {
        UninstallPlan(
            roots: honest.roots, allowedRoots: honest.allowedRoots,
            steps: targets.map { UninstallStep(.removeItem($0), .caches, "Not Hushy's") }, kept: [],
            requiredDataMarker: honest.requiredDataMarker, isTestRun: honest.isTestRun)
    }

    private func expectAllRefused(_ report: UninstallReport, count: Int) {
        #expect(report.entries.count == count)
        for entry in report.entries {
            guard case .refused = entry.outcome else {
                Issue.record("\(entry.step.action.label) was not refused: \(entry.outcome)")
                continue
            }
        }
    }

    @Test("the named locations are what the planner emits, and nothing more: standard, a data folder holding the export folder, a test run")
    func namedLocationsMatchThePlanner() throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let library = test.library.path
        let scratch = URL(fileURLWithPath: "/tmp/hushy-fake/custom")
        let children = UninstallPlanner.dataFolderChildren.map(\.name)

        let standard = try UninstallPlanner.removableLocations(for: test.roots()).map(\.path)
        #expect(standard == ["\(library)/Application Support/Hushy"]
            + children.map { "\(library)/Application Support/Hushy/\($0)" }
            + [
                "\(library)/Application Support/FluidAudio/Models/parakeet-one",
                "\(library)/Application Support/FluidAudio/Models/parakeet-two",
                "\(library)/Caches/\(id)",
                "\(library)/HTTPStorages/\(id)",
                "\(library)/HTTPStorages/\(id).binarycookies",
                "\(library)/Cookies/\(id).binarycookies",
                "\(library)/WebKit/\(id)",
                "\(library)/Preferences/\(id).plist",
                "\(library)/Saved Application State/\(id).savedState",
            ])
        let testRun = try UninstallPlanner.removableLocations(for: test.roots(support: scratch, overridden: true))
        #expect(testRun.map(\.path) == children.map { "\(scratch.path)/\($0)" })
        // A name that is not one plain folder name is never a location.
        let odd = try UninstallPlanner.removableLocations(for: test.roots(speech: ["..", "nested/160ms", "/Users/someone/Elsewhere"]))
        #expect(!odd.contains { $0.path.contains("FluidAudio") || $0.path.contains("Elsewhere") })

        for roots in [
            test.roots(), test.roots(export: test.support.appendingPathComponent("Exports", isDirectory: true)),
            test.roots(support: scratch, overridden: true),
        ] {
            let removed = try UninstallPlanner.plan(for: roots).steps.compactMap { $0.fileURL?.path }
            let named = Set(try UninstallPlanner.removableLocations(for: roots).map(\.path))
            #expect(!removed.isEmpty)
            #expect(Set(removed).isSubset(of: named), "\(Set(removed).subtracting(named))")
        }
    }

    @Test("another app's files deep inside the Library are refused at removal time, whatever built the plan")
    func refusesOtherAppsLocationsOnAFakeDisk() async throws {
        let home = "/Users/someone"
        let library = "\(home)/Library"
        let test = try UninstallTestHome()
        defer { test.remove() }
        var roots = test.roots()
        roots.home = URL(fileURLWithPath: home)
        roots.supportDirectory = URL(fileURLWithPath: "\(library)/Application Support/Hushy")
        roots.exportDirectory = URL(fileURLWithPath: "\(home)/Documents/Hushy")
        let honest = try UninstallPlanner.plan(for: roots)
        let wrong = [
            "\(library)/Caches/com.apple.Safari",
            "\(library)/Preferences/com.apple.finder.plist",
            "\(library)/Caches/\(id).other",
            "\(library)/Preferences/\(id).helper.plist",
            "\(library)/Saved Application State/com.apple.finder.savedState",
            "\(library)/Containers/com.apple.mail/Data",
            "\(library)/Application Support/Other App",
            "\(library)/Application Support/FluidAudio",
            "\(library)/Application Support/FluidAudio/Models",
            "\(library)/Application Support/FluidAudio/Models/someone-elses-model",
            "\(library)/Application Support/Hushy/Audio/one.wav",
            "\(library)/Application Support/Hushy/not-hushys.txt",
        ]
        let present = Dictionary(uniqueKeysWithValues: wrong.map { ($0, UninstallItemKind.folder) })
        let disk = FakeUninstallFileSystem(present)
        let log = UninstallOperationLog()

        let report = await UninstallExecutor(fileSystem: disk, operations: log.operations)
            .run(plan(like: honest, removing: wrong.map { URL(fileURLWithPath: $0) }))

        expectAllRefused(report, count: wrong.count)
        #expect(disk.removed.isEmpty)
        #expect(disk.remaining == Set(wrong))
    }

    @Test("on a real folder, another app's cache and settings file are refused and stay where they are")
    func refusesOtherAppsLocationsOnDisk() async throws {
        let test = try UninstallTestHome()
        defer { test.remove() }
        let safari = try test.write("Library/Caches/com.apple.Safari/Cache.db")
        let finder = try test.write("Library/Preferences/com.apple.finder.plist")
        let honest = try UninstallPlanner.plan(for: test.roots())
        let wrong = [safari.deletingLastPathComponent(), finder]

        let report = await UninstallExecutor(fileSystem: LocalUninstallFileSystem(), operations: UninstallOperationLog().operations)
            .run(plan(like: honest, removing: wrong))

        expectAllRefused(report, count: wrong.count)
        #expect(test.exists(safari))
        #expect(test.exists(finder))
    }

    @Test("a test run removes only the named files in its folder, not anything else put there")
    func testRunRefusesUnnamedFiles() async throws {
        let folder = "/tmp/hushy-fake/custom"
        let test = try UninstallTestHome()
        defer { test.remove() }
        let honest = try UninstallPlanner.plan(for: test.roots(support: URL(fileURLWithPath: folder), overridden: true))
        let wrong = ["\(folder)/someone-elses.txt", "\(folder)/Audio/one.wav", "\(folder)/Projects"]
        var present = Dictionary(uniqueKeysWithValues: wrong.map { ($0, UninstallItemKind.file) })
        present[folder] = .folder
        present["\(folder)/murmur.sqlite"] = .file
        let disk = FakeUninstallFileSystem(present)

        let report = await UninstallExecutor(fileSystem: disk, operations: UninstallOperationLog().operations)
            .run(plan(like: honest, removing: wrong.map { URL(fileURLWithPath: $0) }))

        expectAllRefused(report, count: wrong.count)
        #expect(disk.removed.isEmpty)
    }

    @Test("the data folder is not removed, even empty, once the export folder leads to it")
    func emptyDataFolderIsCheckedAgainstTheExportFolder() async throws {
        let folder = "/tmp/hushy-fake/custom"
        let test = try UninstallTestHome()
        defer { test.remove() }
        let roots = test.roots(support: URL(fileURLWithPath: folder), overridden: true)
        let honest = try UninstallPlanner.plan(for: roots)
        let step = try #require(honest.steps.last)
        #expect(step.action == .removeFolderIfEmpty(URL(fileURLWithPath: folder)))
        // Built with the export folder elsewhere; by removal time it is a link to the data folder.
        let plan = UninstallPlan(
            roots: roots, allowedRoots: honest.allowedRoots, steps: [step], kept: [],
            requiredDataMarker: nil, isTestRun: true)
        let disk = FakeUninstallFileSystem([folder: .folder, test.export.path: .link])
        disk.realPaths = [test.export.path: folder]

        let report = await UninstallExecutor(fileSystem: disk, operations: UninstallOperationLog().operations).run(plan)

        #expect(report.entries.map(\.outcome) == [.refused(.touchesExportFolder(folder))])
        #expect(disk.removed.isEmpty)
    }
}
