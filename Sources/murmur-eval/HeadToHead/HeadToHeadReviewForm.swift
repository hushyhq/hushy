import Foundation

/// Renders the blind human review form for gate 12: one self-contained HTML file (inline CSS
/// and JavaScript, no external resources, no network) that shows each pair as "Output A" /
/// "Output B" with A / B / Tie radios, keeps a draft in the browser's localStorage, and saves
/// the finished votes as a JSON file (`HeadToHeadVoteFile`) via a download link. The page
/// contains no product name and no unblinding key; `murmur-eval head-to-head --votes` does the
/// unblinding from the seed the form embeds.
enum HeadToHeadReviewForm {
    static func render(_ blinded: [BlindedPair], seed: UInt64) -> String {
        let cards = blinded.enumerated().map { index, pair in card(index: index, pair: pair) }.joined(separator: "\n")
        let ids = blinded.map { "\"\(jsString($0.id))\"" }.joined(separator: ",")
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Blind dictation review</title>
            <style>
            \(css)
            </style>
            </head>
            <body>
            <header>
              <h1>Blind dictation review</h1>
              <p>The same paragraph was dictated into two products. For each pair, pick the output you would rather paste <em>as-is</em>: faithful to what was evidently said (nothing dropped or invented — check names, numbers and "not"s), cleaned of speech disfluencies, punctuated like typed text. Pick <strong>Tie</strong> when both are equally usable or differ only in trivial punctuation. You are not told which product is which; please do not try to guess.</p>
              <label>Your name or initials <input id="reviewer" type="text" placeholder="e.g. RK" autocomplete="off"></label>
              <p class="progress"><span id="done">0</span> / \(blinded.count) answered · seed \(seed) · draft saves automatically in this browser</p>
            </header>
            <main>
            \(cards)
            </main>
            <footer>
              <button id="save" type="button">Save votes as JSON</button>
              <p class="hint">Saves <code>votes-&lt;name&gt;.json</code> to your Downloads folder. Send that file back; it contains only your A/B/Tie choices.</p>
              <details><summary>If the download button does nothing, copy this instead</summary><textarea id="json" readonly rows="8"></textarea></details>
            </footer>
            <script>
            const SEED = \(seed);
            const IDS = [\(ids)];
            \(script)
            </script>
            </body>
            </html>
            """
    }

    private static func card(index: Int, pair: BlindedPair) -> String {
        let id = escape(pair.id)
        let name = "choice-\(index)"
        return """
            <section class="pair" data-id="\(id)">
              <h2>Pair \(index + 1) <span class="id">\(id)</span></h2>
              <div class="outputs">
                <div class="output"><h3>Output A</h3><pre>\(escape(pair.a))</pre></div>
                <div class="output"><h3>Output B</h3><pre>\(escape(pair.b))</pre></div>
              </div>
              <div class="choices">
                <label><input type="radio" name="\(name)" value="A"> A is better</label>
                <label><input type="radio" name="\(name)" value="tie"> Tie</label>
                <label><input type="radio" name="\(name)" value="B"> B is better</label>
              </div>
            </section>
            """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func jsString(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    private static let css = """
        :root { color-scheme: light dark; --line: #8884; --accent: #2f6fed; }
        body { font: 16px/1.5 -apple-system, system-ui, sans-serif; margin: 0; padding: 0 16px 80px; max-width: 1100px; margin-inline: auto; }
        header { padding: 24px 0 8px; border-bottom: 1px solid var(--line); }
        h1 { font-size: 22px; margin: 0 0 8px; }
        h2 { font-size: 16px; margin: 0 0 8px; }
        h3 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; margin: 0 0 6px; opacity: .7; }
        .id { font-weight: normal; opacity: .5; font-size: 13px; margin-left: 8px; }
        .progress { opacity: .7; font-size: 14px; }
        label input[type=text] { font: inherit; padding: 4px 8px; margin-left: 8px; }
        .pair { padding: 20px 0; border-bottom: 1px solid var(--line); }
        .pair.answered h2::before { content: "✓ "; color: var(--accent); }
        .outputs { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        @media (max-width: 720px) { .outputs { grid-template-columns: 1fr; } }
        .output pre { white-space: pre-wrap; font: inherit; margin: 0; padding: 12px; border: 1px solid var(--line); border-radius: 8px; min-height: 3em; }
        .choices { display: flex; gap: 24px; margin-top: 12px; flex-wrap: wrap; }
        .choices label { cursor: pointer; }
        footer { position: sticky; bottom: 0; background: Canvas; padding: 12px 0; border-top: 1px solid var(--line); }
        button { font: inherit; padding: 8px 16px; border-radius: 8px; border: 1px solid var(--accent); background: var(--accent); color: white; cursor: pointer; }
        .hint { font-size: 13px; opacity: .7; margin: 8px 0 0; }
        textarea { width: 100%; font: 12px/1.4 ui-monospace, monospace; }
        """

    private static let script = """
        const KEY = 'h2h-draft-' + SEED;
        const reviewer = document.getElementById('reviewer');
        const done = document.getElementById('done');
        const jsonBox = document.getElementById('json');
        function collect() {
          const votes = [];
          document.querySelectorAll('.pair').forEach(section => {
            const checked = section.querySelector('input[type=radio]:checked');
            section.classList.toggle('answered', !!checked);
            if (checked) votes.push({ id: section.dataset.id, choice: checked.value });
          });
          return { reviewer: reviewer.value.trim(), seed: SEED, votes };
        }
        function refresh() {
          const data = collect();
          done.textContent = data.votes.length;
          const text = JSON.stringify(data, null, 2);
          jsonBox.value = text;
          try { localStorage.setItem(KEY, text); } catch (e) {}
          return data;
        }
        function restore() {
          let saved = null;
          try { saved = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) {}
          if (!saved) return;
          reviewer.value = saved.reviewer || '';
          (saved.votes || []).forEach(v => {
            const section = document.querySelector('.pair[data-id="' + CSS.escape(v.id) + '"]');
            if (!section) return;
            const radio = section.querySelector('input[value="' + v.choice + '"]');
            if (radio) radio.checked = true;
          });
        }
        document.addEventListener('change', refresh);
        document.addEventListener('input', refresh);
        document.getElementById('save').addEventListener('click', () => {
          const data = refresh();
          if (!data.reviewer) { alert('Please enter your name or initials first.'); reviewer.focus(); return; }
          if (data.votes.length < IDS.length && !confirm('Only ' + data.votes.length + ' of ' + IDS.length + ' pairs answered. Save anyway?')) return;
          const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
          const a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = 'votes-' + data.reviewer.replace(/[^A-Za-z0-9_-]+/g, '_') + '.json';
          document.body.appendChild(a); a.click(); a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 1000);
        });
        restore();
        refresh();
        """
}
