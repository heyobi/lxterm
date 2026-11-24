import Foundation
import UIKit

/// App Store screenshots (launch argument -shots, scripts/sim-shots.sh): types commands into the
/// first shell as a user would, waiting after each one for the shell's (or Python's) prompt, writes
/// the scene's name to Documents/shots/ready and waits for the script to answer in
/// Documents/shots/next before the next scene. Needs no network (fastfetch is in the root).
@MainActor
enum Tour {
    private enum Wait { case prompt, seconds(Double) }
    private struct Scene {
        let name: String?                 // nil: between scenes, no screenshot
        let steps: [(String, Wait)]
        var keyboard = false
        var theme: String? = nil
    }

    private static let scenes: [Scene] = [
        Scene(name: "fetch", steps: [("clear\r", .prompt), ("fastfetch\r", .prompt)]),
        Scene(name: "python", steps: [("clear\r", .prompt), ("python3\r", .prompt),
                                      ("import statistics, platform\r", .prompt),
                                      ("platform.machine(), platform.system()\r", .prompt),
                                      ("data = [12, 7, 3, 21, 8, 15]\r", .prompt),
                                      ("statistics.mean(data), sorted(data)\r", .prompt),
                                      ("{w: len(w) for w in 'apt pip ssh tmux'.split()}\r", .prompt)]),
        Scene(name: nil, steps: [("exit()\r", .prompt), ("clear\r", .prompt)]),
        Scene(name: "tmux", steps: [("tmux new-session \\; split-window -v top \\; select-pane -t 0\r", .seconds(8)),
                                    ("ls -l --color=always /usr/bin | head -n 8\r", .seconds(4))]),
        Scene(name: nil, steps: [("tmux kill-server\r", .seconds(4)), ("clear\r", .prompt)]),
        Scene(name: "keys", steps: [("uname -sm; nproc; head -n 3 /proc/meminfo\r", .prompt)], keyboard: true),
        Scene(name: "theme", steps: [("clear\r", .prompt), ("ls -la --color=always /\r", .prompt)], theme: "solarized"),
    ]

    /// The last output without escape sequences ends in a prompt: bash's "# " or Python's ">>> ".
    private static func atPrompt(_ s: Session) -> Bool {
        var t = s.tail(400)
        while let r = t.range(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", options: .regularExpression) { t.removeSubrange(r) }
        return t.hasSuffix("# ") || t.hasSuffix(">>> ")
    }

    static func run(_ store: Store) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            guard let s = store.current else { return }
            var waited = 0
            while !atPrompt(s) && waited < 120 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
            _ = s.view.resignFirstResponder()
            for scene in scenes {
                if let t = scene.theme {
                    UserDefaults.standard.set(t, forKey: "theme")
                    NotificationCenter.default.post(name: .lxFontChanged, object: nil)
                }
                if scene.keyboard { _ = s.view.becomeFirstResponder() } else { _ = s.view.resignFirstResponder() }
                for (keys, wait) in scene.steps {
                    for ch in keys.utf8 { s.sendKeys([ch]); try? await Task.sleep(nanoseconds: 20_000_000) }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    switch wait {
                    case .seconds(let n):
                        try? await Task.sleep(nanoseconds: UInt64(n * 1e9))
                    case .prompt:
                        var n = 0
                        while !atPrompt(s) && n < 600 { try? await Task.sleep(nanoseconds: 250_000_000); n += 1 }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                guard let name = scene.name else { continue }
                try? name.write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
                let asked = Date()
                while (try? String(contentsOf: dir.appendingPathComponent("next"), encoding: .utf8)) != name,
                      Date().timeIntervalSince(asked) < 300 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            try? "done".write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        }
    }
}
