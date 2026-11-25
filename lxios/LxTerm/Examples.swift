import Foundation

/// Example scripts for Shortcuts, put once in the shared folder (/root/Files/Examples, also
/// Files › LxTerm › Examples). Never overwritten: they are the user's to change or delete.
enum Examples {
    static let files: [String: String] = [
        "README.md": """
        # LxTerm examples for Shortcuts

        Each script here is also a saved command in LxTerm (… › Saved Commands), so it is in the
        Shortcuts app and works with Siri by its name. Change them, copy them, delete them: they
        are yours, and LxTerm never puts them back.

        ## Exchange rates — rates.py
        Fetches today's rates (frankfurter.app, the European Central Bank's, no key needed).
        Shortcut: **Run Saved Command** (Exchange rates) → **Show Notification** with the result.
        Daily: Automation › Time of Day › 09:00 › Run Immediately, the same two actions.

        ## Note by voice — note.py
        Adds a line, with the date and time, to /root/Files/notes.md (open it in Files).
        Shortcut: **Dictate Text** → **Run Saved Command** (Save a note), with Input set to the
        dictated text. Then say to Siri: "LxTerm Save a note".

        ## Text statistics — textstats.py
        Words, lines, characters and reading time of a text.
        Shortcut: **Get Clipboard** → **Run Saved Command** (Text statistics), Input: Clipboard →
        **Show Result**. Works from the share sheet too: make the shortcut accept Text.

        ## Weather — a one-line command
        curl -s 'wttr.in/Istanbul?format=3'
        Shortcut: **Run Saved Command** (Weather) → **Speak Text**.

        ## Your own
        Write a script here (python3, bash, anything installed), save it as a command such as
        `python3 /root/Files/Examples/mine.py`, and it appears in Shortcuts. Input given in
        Shortcuts arrives on the script's standard input. iOS gives such actions about 30 seconds.
        """,
        "rates.py": """
        #!/usr/bin/env python3
        # Today's exchange rates from frankfurter.app (the European Central Bank's), no key needed.
        import json, sys, urllib.request

        base = sys.argv[1] if len(sys.argv) > 1 else "USD"
        to = "EUR,TRY,GBP,JPY"
        with urllib.request.urlopen(f"https://api.frankfurter.app/latest?from={base}&to={to}", timeout=15) as r:
            data = json.load(r)
        print(f"1 {base} on {data['date']}:")
        for cur, value in data["rates"].items():
            print(f"  {cur} {value:,.2f}")
        """,
        "note.py": """
        #!/usr/bin/env python3
        # Adds the text on standard input (or the arguments) to /root/Files/notes.md, dated.
        import datetime, sys

        text = " ".join(sys.argv[1:]) or sys.stdin.read().strip()
        if not text:
            print("Nothing to save.")
            sys.exit(0)
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        with open("/root/Files/notes.md", "a") as f:
            f.write(f"- {stamp} — {text}\\n")
        print(f"Saved: {text}")
        """,
        "textstats.py": """
        #!/usr/bin/env python3
        # Words, lines, characters and reading time of the text on standard input.
        import sys

        text = sys.stdin.read()
        words = len(text.split())
        print(f"{words} words, {len(text.splitlines())} lines, {len(text)} characters")
        print(f"About {max(1, round(words / 230))} min to read")
        """,
    ]

    /// The saved commands that go with them (Tools.swift's defaults).
    static var snippets: [Snippet] { [
        Snippet(id: UUID(uuidString: "6C5A1E00-0000-4000-8000-000000000002")!, title: String(localized: "Exchange rates"), command: "python3 /root/Files/Examples/rates.py"),
        Snippet(id: UUID(uuidString: "6C5A1E00-0000-4000-8000-000000000003")!, title: String(localized: "Save a note"), command: "python3 /root/Files/Examples/note.py"),
        Snippet(id: UUID(uuidString: "6C5A1E00-0000-4000-8000-000000000004")!, title: String(localized: "Text statistics"), command: "python3 /root/Files/Examples/textstats.py"),
    ] }

    static func install(in shared: URL) {
        let fm = FileManager.default
        let flag = "examplesInstalled"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let dir = shared.appendingPathComponent("Examples", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files {
            let u = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path) { try? Data((text + "\n").utf8).write(to: u) }
        }
        if UserDefaults.standard.data(forKey: "snippets") != nil {    // (a list from before: the examples added to it)
            var list = Snippets.all
            for s in snippets where !list.contains(where: { $0.command == s.command }) { list.append(s) }
            Snippets.all = list
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}
