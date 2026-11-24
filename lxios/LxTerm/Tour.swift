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
        // fastfetch with Debian's small logo and no host-dependent lines (the simulator's disk and memory)
        Scene(name: nil, steps: [("mkdir -p ~/.config/fastfetch && echo '{\"logo\":{\"source\":\"debian_small\"},\"modules\":[\"title\",\"separator\",\"os\",\"kernel\",\"packages\",\"shell\",\"terminal\",\"cpu\",\"locale\",\"break\",\"colors\"]}' > ~/.config/fastfetch/config.jsonc\r", .prompt)]),
        Scene(name: "fetch", steps: [("clear\r", .prompt), ("fastfetch\r", .prompt)]),
        Scene(name: "python", steps: [("clear\r", .prompt), ("python3\r", .prompt),
                                      ("import statistics, platform\r", .prompt),
                                      ("platform.machine(), platform.system()\r", .prompt),
                                      ("data = [12, 7, 3, 21, 8, 15]\r", .prompt),
                                      ("statistics.mean(data), sorted(data)\r", .prompt),
                                      ("{w: len(w) for w in 'apt pip ssh tmux'.split()}\r", .prompt)]),
        Scene(name: nil, steps: [("exit()\r", .prompt), ("clear\r", .prompt)]),
        Scene(name: "tmux", steps: [("tmux new-session \\; split-window -v 'nano /etc/os-release' \\; select-pane -t 0\r", .seconds(8)),
                                    ("uname -sm; python3 --version; tmux -V\r", .seconds(4))]),
        Scene(name: nil, steps: [("tmux kill-server\r", .seconds(4)), ("clear\r", .prompt)]),
        Scene(name: "keys", steps: [("id; echo $SHELL; uname -sm\r", .prompt)], keyboard: true),
        Scene(name: "theme", steps: [("clear\r", .prompt), ("ls -la --color=always /\r", .prompt)], theme: "solarized"),
    ]

    /// The last output without escape sequences ends in a prompt: bash's "# " or Python's ">>> ".
    private static func atPrompt(_ s: Session) -> Bool {
        var t = s.tail(400)
        while let r = t.range(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", options: .regularExpression) { t.removeSubrange(r) }
        return t.hasSuffix("# ") || t.hasSuffix(">>> ")
    }

    private static func hideKeyboard(_ s: Session) {
        _ = s.view.resignFirstResponder()
        s.view.window?.endEditing(true)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    static func run(_ store: Store) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            guard let s = store.current else { return }
            // a font that fits fastfetch's two columns on a phone
            Settings.fontSize = UIDevice.current.userInterfaceIdiom == .phone ? 12 : 20
            NotificationCenter.default.post(name: .lxFontChanged, object: nil)
            var waited = 0
            while !atPrompt(s) && waited < 120 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
            hideKeyboard(s)
            for scene in scenes {
                if let t = scene.theme {
                    UserDefaults.standard.set(t, forKey: "theme")
                    NotificationCenter.default.post(name: .lxFontChanged, object: nil)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if scene.keyboard { _ = s.view.becomeFirstResponder() } else { hideKeyboard(s) }
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
                if !scene.keyboard { hideKeyboard(s); try? await Task.sleep(nanoseconds: 900_000_000) }
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
