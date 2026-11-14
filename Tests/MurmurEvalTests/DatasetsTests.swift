import Foundation
import Testing

@testable import murmur_eval
@testable import MurmurCore

/// Coverage for the `mls-*` (Multilingual LibriSpeech) dataset cases that replaced FLEURS as
/// the backing data source for `murmur-eval multilang wer` — every FLEURS config's
/// datasets-server `/rows` endpoint 500s with "Parquet error: Scan size limit exceeded", so
/// `Dataset.multilangDatasets` now points at MLS per-language configs instead. See
/// `Datasets.swift` and `.claude/DECISIONS.md` ("Multi-language dictation") for the full story.
@Suite("Multilang dataset source (MLS)")
struct DatasetsTests {
    @Test func multilangDatasetsAreTheFourMLSLanguages() {
        #expect(Dataset.multilangDatasets == [.mlsSpanish, .mlsFrench, .mlsGerman, .mlsItalian])
    }

    @Test func rawValuesMatchTheLanguageFlagsMultilangRunnerParses() {
        // MultilangRunner.wer builds `Dataset(rawValue: "mls-\(lang)")` from `--languages es,fr,de,it`.
        #expect(Dataset(rawValue: "mls-es") == .mlsSpanish)
        #expect(Dataset(rawValue: "mls-fr") == .mlsFrench)
        #expect(Dataset(rawValue: "mls-de") == .mlsGerman)
        #expect(Dataset(rawValue: "mls-it") == .mlsItalian)
    }

    @Test func sourceConfigsMatchHuggingFaceDatasetServerConfigs() {
        #expect(Dataset.mlsSpanish.source.dataset == "facebook/multilingual_librispeech")
        #expect(Dataset.mlsSpanish.source.config == "spanish")
        #expect(Dataset.mlsSpanish.source.split == "test")

        #expect(Dataset.mlsFrench.source.config == "french")
        #expect(Dataset.mlsGerman.source.config == "german")
        #expect(Dataset.mlsItalian.source.config == "italian")
    }

    @Test func licenseIsRecordedForProvenance() {
        for dataset in Dataset.multilangDatasets {
            #expect(dataset.license.contains("CC-BY-4.0"))
        }
    }

    @Test func summaryNamesTheLanguage() {
        #expect(Dataset.mlsSpanish.summary.contains("Spanish"))
        #expect(Dataset.mlsFrench.summary.contains("French"))
        #expect(Dataset.mlsGerman.summary.contains("German"))
        #expect(Dataset.mlsItalian.summary.contains("Italian"))
    }

    @Test func transcriptFieldIsExtractedFromMLSRows() {
        // MLS rows use the "transcript" key, already in `Dataset.transcripts(from:)`'s generic
        // fallback list — this pins that down so a future edit to that list can't silently break
        // MLS parsing without a test failing.
        let row: [String: Any] = [
            "transcript": "y las almas buscando algún alivio se revuelven ansiosas",
            "speaker_id": "1234",
            "audio_duration": 16.27,
        ]
        let extracted = Dataset.mlsSpanish.transcripts(from: row)
        #expect(extracted?.0 == "y las almas buscando algún alivio se revuelven ansiosas")
        #expect(extracted?.1 == nil)
    }

    @Test func rowsWithoutATranscriptFieldAreRejected() {
        let row: [String: Any] = ["speaker_id": "1234"]
        #expect(Dataset.mlsFrench.transcripts(from: row) == nil)
    }

    @Test func doesNotUseDeterministicSpreadSampling() {
        // MLS test splits are a few thousand rows and already shuffled/representative; a
        // sequential scan from offset 0 is fine (matches librispeechClean/Other's treatment)
        // and is simpler/faster than the stratified-sample path peoplesSpeech opts into.
        for dataset in Dataset.multilangDatasets {
            #expect(!dataset.usesDeterministicSampling)
        }
    }

    @Test func directoryAndManifestPathsAreDerivedFromRawValue() {
        let root = URL(fileURLWithPath: "/tmp/murmur-eval-tests-\(UUID().uuidString)")
        #expect(Dataset.mlsSpanish.directory(root: root).lastPathComponent == "mls-es")
        #expect(Dataset.mlsSpanish.manifest(root: root).lastPathComponent == "manifest.json")
    }
}

/// Coverage for the `edacc-indian`/`edacc-us-control` dataset cases `murmur-eval accent` uses
/// (see `AccentRunner.swift` and `.claude/DECISIONS.md`, "Indian-accent ASR accuracy"): Svarah
/// (`Dataset.svarah`) is gated with no `HF_TOKEN` available, so these carve two accent-matched
/// subsets out of the same ungated `edinburghcstr/edacc` split instead.
@Suite("Accent dataset source (EdAcc Indian/US subsets)")
struct AccentDatasetsTests {
    @Test func bothCasesShareTheSameEdAccSource() {
        #expect(Dataset.edaccIndian.source.dataset == "edinburghcstr/edacc")
        #expect(Dataset.edaccUSControl.source.dataset == "edinburghcstr/edacc")
        #expect(Dataset.edaccIndian.source.config == Dataset.edaccUSControl.source.config)
        #expect(Dataset.edaccIndian.source.split == Dataset.edaccUSControl.source.split)
    }

    @Test func filterAccentSelectsTheRightRowsFromTheSharedSplit() {
        #expect(Dataset.edaccIndian.filterAccent == "Indian English")
        #expect(Dataset.edaccUSControl.filterAccent == "Mainstream US English")
    }

    @Test func otherDatasetsHaveNoAccentFilter() {
        #expect(Dataset.librispeechClean.filterAccent == nil)
        #expect(Dataset.accents.filterAccent == nil)
    }

    @Test func rawValuesRoundTrip() {
        #expect(Dataset(rawValue: "edacc-indian") == .edaccIndian)
        #expect(Dataset(rawValue: "edacc-us-control") == .edaccUSControl)
    }

    @Test func licenseIsRecordedForProvenance() {
        #expect(Dataset.edaccIndian.license.contains("CC-BY-4.0"))
        #expect(Dataset.edaccUSControl.license.contains("CC-BY-4.0"))
    }

    @Test func doesNotUseDeterministicSpreadSampling() {
        // A sequential scan with the accent filter applied is sufficient — EdAcc groups rows by
        // conversation, so a full-split scan (not just an early prefix) already covers many
        // distinct speakers within each accent group.
        #expect(!Dataset.edaccIndian.usesDeterministicSampling)
        #expect(!Dataset.edaccUSControl.usesDeterministicSampling)
    }

    @Test func groupExtractionUsesTheAccentColumn() {
        let row: [String: Any] = ["accent": "Indian English", "l1": "Hindi", "text": "take some notes"]
        #expect(Dataset.edaccIndian.group(from: row) == "Indian English")
    }
}

/// `EvalMetrics.normalizedWords` (used by `corpusWER`) must stay usable for the accented
/// alphabets of es/fr/de/it — it's `CharacterSet.alphanumerics`-based (Unicode-aware), not an
/// ASCII-only splitter, so this pins that down rather than relying on incidental behavior.
@Suite("WER normalization keeps accented letters (multilang)")
struct MultilangNormalizationTests {
    @Test func lowercasesAndStripsPunctuationWhileKeepingAccents() {
        let words = EvalMetrics.normalizedWords("¿Cómo estás? Ça va très bien, günther.")
        #expect(words == ["cómo", "estás", "ça", "va", "très", "bien", "günther"])
    }

    @Test func germanUmlautsAndEszettSurviveNormalization() {
        let words = EvalMetrics.normalizedWords("Straße, Mädchen und Übermut!")
        #expect(words == ["straße", "mädchen", "und", "übermut"])
    }

    @Test func italianAccentsSurviveNormalization() {
        let words = EvalMetrics.normalizedWords("Perché è così, città bella?")
        #expect(words == ["perché", "è", "così", "città", "bella"])
    }

    @Test func corpusWERScoresIdenticalAccentedTextAsZero() {
        let pairs: [(reference: String, hypothesis: String)] = [
            ("Cómo estás günther", "cómo estás günther"),
            ("Ça va très bien", "Ça va très bien"),
        ]
        #expect(EvalMetrics.corpusWER(pairs) == 0)
    }

    @Test func corpusWERPenalizesADroppedAccentedWord() {
        let pairs: [(reference: String, hypothesis: String)] = [
            ("cómo estás günther hoy", "cómo estás hoy"),
        ]
        // 1 deletion out of 4 reference words.
        #expect(EvalMetrics.corpusWER(pairs) == 0.25)
    }
}
