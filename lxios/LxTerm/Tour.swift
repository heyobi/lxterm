import Foundation
import UIKit

/// App Store screenshots (launch argument -shots, scripts/sim-shots.sh): types commands into the
/// first shell as a user would, waits until the output has been quiet for a while, writes the
/// scene's name to Documents/shots/ready and waits for the script to answer in
/// Documents/shots/next before the next scene.
@MainActor
enum Tour {
    private struct Scene {
        let name: String?                 // nil: preparation, no screenshot
        let keys: [String]
        let quiet: TimeInterval           // seconds without output that mean "done"
        var keyboard = false
        var theme: String? = nil
    }

    private static let scenes: [Scene] = [
        Scene(name: nil, keys: ["apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq fastfetch >/dev/null 2>&1; clear\r"], quiet: 12),
        Scene(name: "fetch", keys: ["fastfetch\r"], quiet: 5),
        Scene(name: "python", keys: ["clear\r", "python3\r", "import statistics, platform\r",
                                     "platform.machine(), platform.system()\r",
                                     "data = [12, 7, 3, 21, 8, 15]\r",
                                     "statistics.mean(data), sorted(data)\r",
                                     "{w: len(w) for w in 'apt pip ssh tmux'.split()}\r"], quiet: 4),
        Scene(name: nil, keys: ["exit()\r", "clear\r"], quiet: 2),
        Scene(name: "tmux", keys: ["tmux new-session \\; split-window -v top \\; select-pane -t 0\r",
                                   "ls -l --color=always /usr/bin | head -n 8\r"], quiet: 5),
        Scene(name: nil, keys: ["tmux kill-server\r", "clear\r"], quiet: 3),
        Scene(name: "keys", keys: ["curl -sI https://deb.debian.org | head -n 4\r"], quiet: 5, keyboard: true),
        Scene(name: "theme", keys: ["clear\r", "ls -la --color=always /\r"], quiet: 4, theme: "solarized"),
    ]

    static func run(_ store: Store) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let s = store.current else { return }
            _ = s.view.resignFirstResponder()
            for scene in scenes {
                if let t = scene.theme {
                    UserDefaults.standard.set(t, forKey: "theme")
                    NotificationCenter.default.post(name: .lxFontChanged, object: nil)
                }
                if scene.keyboard { _ = s.view.becomeFirstResponder() } else { _ = s.view.resignFirstResponder() }
                for k in scene.keys {
                    for ch in k.utf8 { s.sendKeys([ch]); try? await Task.sleep(nanoseconds: 25_000_000) }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
                let start = Date()
                while Date().timeIntervalSince(s.lastOutput) < scene.quiet && Date().timeIntervalSince(start) < 1200 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
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
