# Meeting-extract data: licence ledger

Read 2026-11-06 from primary sources (licence pages, dataset cards, papers, the dataset's own repository). This is a reading of the published terms, not legal advice. Every row in the data carries `source`, `licence` and `commercial_safe`; this file is where those values come from.

Founder rule: public data before teachers; research-only licences are fine for now, but every row is tagged so a commercial release can drop them. `commercial_safe: false` rows must not reach the weights of a shipped model without a decision.

## Summary

| Source | Licence as published | Used | Commercial-safe | Row tag |
|---|---|---|---|---|
| AMI Meeting Corpus (manual annotations 1.6.2) | CC BY 4.0 | yes, gold | yes, with attribution | `ami` |
| ICSI Meeting Corpus (Edinburgh release, ICSIplus) | CC BY 4.0 | yes, gold | yes, with attribution. The LDC copy has other terms; we use only the Edinburgh one | `icsi` |
| NOTSOFAR-1 (train set transcripts) | CC BY 4.0 (since 2026-06-22; challenge-only before) | yes, input only | yes, with attribution | `notsofar` |
| ELITR Minuting Corpus (English) | CC BY-NC-SA 4.0 | yes, heuristic gold | no (research only, share-alike) | `elitr` |
| QMSum Committee meetings | Annotations MIT. Canadian House of Commons transcripts: non-commercial. Welsh Senedd: unclear | yes, heuristic gold | no | `qmsum-committee` |
| MeetingBank | HF card CC BY-NC-SA 4.0; Zenodo says CC BY 4.0; the authors say research only | yes, input only | no | `meetingbank` |
| QMSum Product and Academic | Annotations MIT; transcripts are AMI and ICSI | no (we read AMI and ICSI directly) | n/a | none |
| MeetingQA | CC BY-NC-SA 4.0 | no (questions are derived from AMI; we do not copy its labels) | no | none |
| MediaSum | "research purpose only", no licence file; NPR and CNN copyright | no | no | none |
| DialogSum | CC BY-NC-SA 4.0 | no (everyday dialogues, not meetings) | no | none |
| FAME (synthetic meetings) | paper says CC BY-SA 4.0, repo says MIT, GPT-generated | no | unclear | none |
| zarnite/zarn-meeting-to-actions and other small synthetic HF sets | row-level `apache-2.0` notice on one, others unverified; vendor-made | no | unclear | none |

Share-alike licences (NC-SA, BY-SA) are rated research only here, because whether they reach trained weights is unsettled.

## Per source

### AMI Meeting Corpus
- Terms: "The AMI corpus and its annotations are released under the Creative Commons Attribution 4.0 license agreement (also called CC BY 4.0)." https://groups.inf.ed.ac.uk/ami/corpus/license.shtml. The download page lists manual annotations v1.6.2 and automatic annotations v1.5.1 as "license altered to CC BY 4.0" and says "All of the signals and transcription, and some of the annotations" are CC BY 4.0 (https://groups.inf.ed.ac.uk/ami/download/). The licence page is the more authoritative text and covers the annotations zip. The `LICENCE.txt` inside our local copy (`Evals/runs/public/ami/extracted/LICENCE.txt`) states CC BY 4.0.
- Fit: the scenario meetings are role play (a team designing a remote control). The abstractive summaries list decisions, actions and problems, and annotators linked each sentence to the dialogue acts that support it (`abstractive/*.abssumm.xml`, `extractive/*.summlink.xml`).
- File: `ami_public_manual_1.6.2.zip` (22.9 MB, NXT XML), already extracted at `Evals/runs/public/ami/extracted`. Not copied into the data folder.
- Attribution: "Contains data from the AMI Meeting Corpus (University of Edinburgh / AMI Consortium), CC BY 4.0, https://groups.inf.ed.ac.uk/ami/corpus/. Text segmented, re-chunked and re-labelled by Hushy." Cite Carletta et al., MLMI 2005. The licence requires credit, a licence link and a note that we changed the material.

### ICSI Meeting Corpus
- Terms: "The ICSI corpus and its annotations are released under the Creative Commons Attribution 4.0 license agreement (also called CC BY 4.0)." https://groups.inf.ed.ac.uk/ami/icsi/license.shtml. The LDC copy (LDC2004T04) is "LDC User Agreement for Non-Members", a different release with different terms. We use only the Edinburgh files.
- Caveat: the `ICSIplus/Contributions` folders are third-party. We use only `Summarization` (abstractive and extractive, with summary links). Its per-contribution licence was not checked separately. Treat as CC BY 4.0 with that open point.
- Fit: real research-group meetings, speakers pseudonymous (we relabel them `Speaker 1..N`). Summaries have DECISIONS, PROGRESS and PROBLEMS headings and no ACTIONS. ICSI action-item annotations (Gruenstein 2005, Purver 2007) are not in the public release.
- File: `ICSI_plus_NXT.zip` (55.5 MB) from https://groups.inf.ed.ac.uk/ami/ICSICorpusAnnotations/.
- Attribution: "Contains data from the ICSI Meeting Corpus (International Computer Science Institute; Edinburgh release), CC BY 4.0." Cite Janin et al., ICASSP 2003.

### NOTSOFAR-1
- Terms: the HF card now reads "The data is licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0)" (https://huggingface.co/datasets/microsoft/NOTSOFAR). The GitHub README and `DATA_LICENSE` agree. Before 2026-06-22 it was licensed "exclusively for use in the NOTSOFAR challenge event" (changed in https://huggingface.co/datasets/microsoft/NOTSOFAR/discussions/1). We fetched on 2026-11-06, after the change. Dev set 2 was removed by Microsoft as challenge-only; we never use dev or eval splits.
- Fit: poor. Short (about 6 minutes), role-played or topic-prompted conversations with few decisions. Used as input-only, good for negatives. Participants use first-name aliases.
- Files: `gt_transcription.json` and `gt_meeting_metadata.json` for 72 meetings in `benchmark-datasets/train_set/240825.1_train/MTG/` (15 MB, no audio).
- Attribution: "NOTSOFAR-1 dataset, Microsoft, CC BY 4.0." Cite Vinnikov et al., Interspeech 2024.

### ELITR Minuting Corpus
- Terms: "Creative Commons - Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)", https://lindat.mff.cuni.cz/repository/items/8594c726-8ea4-476e-8c66-e9afb85b06e0 (handle http://hdl.handle.net/11234/1-4692). Research only.
- Fit: English computer-science project meetings, de-identified (`PERSON13`, `[ORGANIZATION1]`). Minutes are free-form bullets, not typed records. 49 of the 120 English meetings also have transcript-to-minutes alignments.
- Use: heuristic gold only (see the research doc). Participants consented and the text was de-identified by the authors.
- Attribution: Nedoluzhko et al., LREC 2022, plus the CC BY-NC-SA 4.0 notice.

### QMSum (Committee family only)
- Terms: repository LICENSE is MIT (Yale-LILY), covering the annotations only. The paper says the transcripts "are public and open to use according to the regulation" (NAACL 2021). The Canadian House of Commons notice excludes "reproduction, distribution or use for commercial purpose of financial gain" (https://www.ourcommons.ca/en/important-notices). The Welsh Senedd pages conflict (Open Government Licence on the open-data page, a non-commercial wording on the copyright page), so this is unclear and treated as research only.
- Use: the 36 committee meetings, as input and with heuristic gold from decision-style queries. Its AMI and ICSI families are not used, because we read AMI and ICSI directly and QMSum's copies would duplicate scorecard meetings.
- Attribution: Zhong et al., NAACL 2021.

### MeetingBank
- Terms conflict. HF `huuuyeah/meetingbank` card: `license: cc-by-nc-sa-4.0`. Zenodo record 7989108: `cc-by-4.0`. The paper (ACL 2023) says "Our dataset is intended for research purposes only." We follow the stricter reading: research only.
- Fit: city council agenda items, ASR text with no speaker labels. Input-only. The `summary` field is an agenda line, kept in `notes.agenda_summary`, not a record.
- File: `train.json`, `validation.json`, `test.json` from HF `huuuyeah/meetingbank` (115 MB total). We sample 1,500 chunks.
- Attribution: Hu et al., ACL 2023.

### Not used, with reasons
- QMSum Product and Academic: duplicate AMI and ICSI.
- MeetingQA (adobe-research/meetingqa): CC BY-NC-SA 4.0 in the repo. 7,735 questions over 166 AMI meetings. Not copied. If we want `open_question` gold we can re-derive questions from AMI's own dialogue-act labels, which is CC BY.
- MediaSum: interviews, NPR and CNN copyright, "research purpose only".
- DialogSum: everyday dialogues, CC BY-NC-SA 4.0.
- FAME: synthetic, GPT-written, licence statements disagree.
- Small synthetic action-item sets on Hugging Face (zarnite/zarn-meeting-to-actions has the same four fields we want, 1,200 rows, but is vendor-synthetic with an unverified licence): not used as training gold. A candidate for evaluating the extraction format only.
- AliMeeting4MUG: Mandarin, data licence not found.
- No public set exists with typed `change` or `open_question` records on real English meetings, and ICSI action-item annotations are no longer public. We found no meeting dataset with all four kinds.

## Open points
- The licence text inside the AMI and ICSI zips was read for AMI (CC BY 4.0) but not compared line by line with the web pages for ICSI.
- Per-contribution licences under `ICSIplus/Contributions` were not checked.
- A lawyer should look at share-alike and non-commercial rows before any of them reach a shipped model.
