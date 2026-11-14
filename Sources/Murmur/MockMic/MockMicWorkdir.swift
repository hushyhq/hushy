#if DEBUG
import Foundation

/// The two helper modes `scripts/mock-mic.sh` uses around macOS `say`: list the jobs to speak, then
/// stitch the spoken parts into meeting clips and write their `clips.json`.
enum MockMicWorkdir {
    static let leadIn = 1.5
    static let gap = 0.6
    /// The player stops at 60 s; leave room for the tail.
    static let longestClip = 55.0

    static func writeJobs(to work: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: work.appendingPathComponent("parts"), withIntermediateDirectories: true)
        let jobs = MockMicSayPlan.standard.jobs
        try MockMicSayPlan.tsv(jobs).write(to: work.appendingPathComponent("jobs.tsv"), atomically: true, encoding: .utf8)
        print("mock-mic: \(jobs.count) clips to speak")
        return MockMicExit.ok
    }

    static func assemble(in work: URL) throws -> Int32 {
        let plan = MockMicSayPlan.standard
        var durations: [String: Double] = [:]
        for job in plan.jobs { durations[job.path] = try MockMicAudio.duration(of: work.appendingPathComponent(job.path)) }
        for clip in plan.dictation where durations["\(clip.id).wav", default: 0] > longestClip {
            throw MockMicAudioError(description: "\(clip.id) is longer than \(Int(longestClip)) s")
        }
        let manifest = try plan.manifest(durations: durations, leadIn: leadIn, gap: gap)
        for meeting in manifest.meetings { try writeMeeting(meeting, plan: plan, work: work) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: work.appendingPathComponent("clips.json"))
        print("mock-mic: wrote clips.json with \(manifest.dictation.count) dictation clips and \(manifest.meetings.count) meetings")
        return MockMicExit.ok
    }

    private static func writeMeeting(_ meeting: MockMicManifest.Meeting, plan: MockMicSayPlan, work: URL) throws {
        let parts = try meeting.turns.indices.map {
            try MockMicAudio.readMono(work.appendingPathComponent(MockMicSayPlan.partPath(meeting.id, $0)))
        }
        let samples = MockMicAudio.assemble(parts: parts, turns: meeting.turns)
        let seconds = Double(samples.count) / MockMicAudio.rate
        guard seconds <= longestClip else {
            throw MockMicAudioError(description: "\(meeting.id) is \(Int(seconds)) s; the player stops at 60 s. Trim its script.")
        }
        try MockMicAudio.writeWAV(samples, to: work.appendingPathComponent("\(meeting.id).wav"))
    }
}
#endif
