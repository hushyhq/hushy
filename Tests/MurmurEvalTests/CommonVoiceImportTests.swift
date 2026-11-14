import Foundation
import Testing

@testable import murmur_eval

@Suite("Common Voice TSV import")
struct CommonVoiceImportTests {
    /// A tiny, hand-built fixture standing in for a real Common Voice TSV: mixes the
    /// spontaneous-release column names with a couple of unusable rows (empty transcript,
    /// missing audio file) so the tolerant parser and filtering can be exercised without a
    /// real download.
    static func writeFixtureTSV() throws -> URL {
        let header = "client_id\taudio_file\tduration_ms\ttranscription\taccents\tage\tgender\tsplit"
        let rows = [
            // speaker A: 4 rows in test split (only 3 should survive a per-speaker cap of 3)
            "spk-a\ta1.mp3\t1000\tHello there [disfluency] friend\tScottish\t30s\tmale_masculine\ttest",
            "spk-a\ta2.mp3\t1000\tSecond clip from speaker a\tScottish\t30s\tmale_masculine\ttest",
            "spk-a\ta3.mp3\t1000\tThird clip from speaker a\tScottish\t30s\tmale_masculine\ttest",
            "spk-a\ta4.mp3\t1000\tFourth clip should be capped\tScottish\t30s\tmale_masculine\ttest",
            // speaker B: different accent, dev split (should count as held-out eligible too)
            "spk-b\tb1.mp3\t1000\tA clip from speaker b <noise>\tIrish\t40s\tfemale_feminine\tdev",
            // speaker C: no accent label at all
            "spk-c\tc1.mp3\t1000\tNo accent label here\t\t\t\ttest",
            // train split: must be excluded from the held-out eval pool
            "spk-d\td1.mp3\t1000\tThis is a training row\tWelsh\t\t\ttrain",
            // empty transcript: must be dropped
            "spk-e\te1.mp3\t1000\t\tWelsh\t\t\ttest",
            // missing audio file column value: must be dropped
            "spk-f\t\t1000\tNo audio file for this row\tWelsh\t\t\ttest",
        ]
        let content = ([header] + rows).joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tsv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func parsesTabSeparatedRowsAndHeader() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        #expect(header == ["client_id", "audio_file", "duration_ms", "transcription", "accents", "age", "gender", "split"])
        #expect(records.count == 9)
        #expect(records[0][0] == "spk-a")
        #expect(records[0][3] == "Hello there [disfluency] friend")
    }

    @Test func resolvesColumnsToleratingSpontaneousNaming() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, _) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        #expect(columns.audioFile == "audio_file")
        #expect(columns.transcript == "transcription")
        #expect(columns.accent == "accents")
        #expect(columns.clientId == "client_id")
        #expect(columns.split == "split")
    }

    @Test func dropsRowsWithoutUsableTranscriptOrAudioFile() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        let rows = records.compactMap { columns.row(from: $0, reportedFiles: []) }
        // 9 input rows minus the empty-transcript row and the missing-audio-file row = 7
        #expect(rows.count == 7)
        #expect(!rows.contains { $0.transcript.isEmpty })
        #expect(!rows.contains { $0.audioFile.isEmpty })
    }

    @Test func excludesReportedAudioFiles() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        let rows = records.compactMap { columns.row(from: $0, reportedFiles: ["a1.mp3"]) }
        #expect(!rows.contains { $0.audioFile == "a1.mp3" })
    }

    @Test func stripsBracketedDisfluencyAndNoiseTagsFromTranscripts() {
        #expect(CommonVoiceImport.normalizeTranscript("Hello there [disfluency] friend") == "Hello there friend")
        #expect(CommonVoiceImport.normalizeTranscript("A clip from speaker b <noise>") == "A clip from speaker b")
        #expect(CommonVoiceImport.normalizeTranscript("Multiple  [um] <breathing> tags [disfluency|uh]") == "Multiple tags")
        #expect(CommonVoiceImport.normalizeTranscript("No tags here") == "No tags here")
    }

    @Test func capsClipsPerSpeaker() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        let rows = records.compactMap { columns.row(from: $0, reportedFiles: []) }
        let heldOut = rows.filter { $0.split == "dev" || $0.split == "test" }
        let sample = CommonVoiceImport.balancedSample(heldOut, limit: 100, perSpeaker: 3, seed: 42)
        let perSpeaker = Dictionary(grouping: sample, by: { $0.clientId ?? "" })
        for (_, clips) in perSpeaker {
            #expect(clips.count <= 3)
        }
        // Speaker A had 4 eligible test-split rows; only 3 should survive the cap.
        #expect(perSpeaker["spk-a"]?.count == 3)
    }

    @Test func excludesTrainSplitFromHeldOutPool() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        let rows = records.compactMap { columns.row(from: $0, reportedFiles: []) }
        let heldOut = rows.filter { $0.split == "dev" || $0.split == "test" }
        #expect(!heldOut.contains { $0.clientId == "spk-d" })
    }

    @Test func balancesAcrossAccentGroupsRoundRobin() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        let rows = records.compactMap { columns.row(from: $0, reportedFiles: []) }
        let heldOut = rows.filter { $0.split == "dev" || $0.split == "test" }
        // Limit to fewer than the total eligible rows so round-robin balancing actually kicks in.
        let sample = CommonVoiceImport.balancedSample(heldOut, limit: 2, perSpeaker: 3, seed: 1)
        let accents = Set(sample.map { $0.accent ?? "unspecified" })
        // With a tight limit, round-robin should pull from more than one accent group rather
        // than exhausting the largest group (Scottish) first.
        #expect(accents.count >= 2)
    }

    @Test func sameSeedProducesSameSample() throws {
        let url = try Self.writeFixtureTSV()
        defer { try? FileManager.default.removeItem(at: url) }
        let (header, records) = try TSV.parse(url)
        let columns = try ResolvedColumns(header: header, kind: .spontaneous)
        let rows = records.compactMap { columns.row(from: $0, reportedFiles: []) }
        let heldOut = rows.filter { $0.split == "dev" || $0.split == "test" }
        let first = CommonVoiceImport.balancedSample(heldOut, limit: 3, perSpeaker: 3, seed: 7).map(\.audioFile)
        let second = CommonVoiceImport.balancedSample(heldOut, limit: 3, perSpeaker: 3, seed: 7).map(\.audioFile)
        #expect(first == second)
    }
}
