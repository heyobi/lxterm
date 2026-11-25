import Foundation
import UIKit

/// App Store screenshots (launch argument -shots, scripts/sim-shots.sh): downloads Arch Linux ARM,
/// Ubuntu and Fedora, then plays scenes (tabs in several distributions, the Distributions list,
/// Ports and the browser, saved commands), typing as a user would and waiting for each prompt.
/// For each scene it writes the scene's name to Documents/shots/ready and waits for the script to
/// answer in Documents/shots/next. Needs the network (downloads, pacman, apt).
@MainActor
enum Tour {
    static let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("shots")

    private static func log(_ s: String) {
        let u = dir.appendingPathComponent("tour.log")
        let old = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        try? (old + s + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    /// The last output without escape sequences ends in a prompt: "# " (bash, Alpine's sh) or ">>> ".
    private static func atPrompt(_ s: Session) -> Bool {
        var t = s.tail(600)
        while let r = t.range(of: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", options: .regularExpression) { t.removeSubrange(r) }
        return t.hasSuffix("# ") || t.hasSuffix(">>> ")
    }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private static func waitPrompt(_ s: Session, max: Double = 600) async {
        var n = 0.0
        while !atPrompt(s) && n < max { await sleep(0.5); n += 0.5 }
        await sleep(0.6)
    }

    private static func type(_ s: Session, _ text: String, wait: Bool = true, max: Double = 600) async {
        for ch in text.utf8 { s.sendKeys([ch]); await sleep(0.02) }
        await sleep(0.4)
        if wait { await waitPrompt(s, max: max) }
    }

    private static func hideKeyboard(_ s: Session?) {
        _ = s?.view.resignFirstResponder()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private static func show(_ what: String) { NotificationCenter.default.post(name: .lxTour, object: what) }

    /// One screenshot: the script takes it, then answers.
    private static func shot(_ name: String) async {
        await sleep(1.2)
        try? name.write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        let asked = Date()
        while (try? String(contentsOf: dir.appendingPathComponent("next"), encoding: .utf8)) != name, Date().timeIntervalSince(asked) < 300 {
            await sleep(0.5)
        }
        log("shot \(name)")
    }

    /// A new tab in `d`, shown, its shell at the prompt.
    private static func open(_ store: Store, _ d: Distro) async -> Session? {
        store.newSession(d)
        await sleep(1.5)
        guard let s = store.current else { return nil }
        hideKeyboard(s)
        await waitPrompt(s, max: 120)
        return s
    }

    static func run(_ store: Store) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            let phone = UIDevice.current.userInterfaceIdiom == .phone
            Settings.fontSize = phone ? 12 : 19
            UserDefaults.standard.set("night", forKey: "theme")
            UserDefaults.standard.set(true, forKey: "distroColours")
            NotificationCenter.default.post(name: .lxFontChanged, object: nil)
            guard let deb = store.current else { return }
            await waitPrompt(deb, max: 120)
            hideKeyboard(deb)
            // the distributions, downloaded first (their tabs come later)
            for id in ["arch", "ubuntu", "fedora"] {
                let d = Distro.named(id)
                do { try await d.install { _ in }; log("installed \(id)") } catch { log("FAILED \(id): \(error)") }
            }
            DistroManager.shared.refresh()
            // fastfetch without the host's disk and memory lines
            let cfg = "mkdir -p ~/.config/fastfetch && echo '{\"modules\":[\"title\",\"separator\",\"os\",\"kernel\",\"packages\",\"shell\",\"terminal\",\"cpu\",\"locale\",\"break\",\"colors\"]}' > ~/.config/fastfetch/config.jsonc\r"

            // 1. Arch Linux ARM: its setup runs in the first tab, then pacman installs fastfetch
            if let arch = await open(store, Distro.named("arch")) {
                var n = 0
                while FileManager.default.fileExists(atPath: Distro.named("arch").root.appendingPathComponent(".lxterm-firstrun").path) && n < 1200 {
                    await sleep(1); n += 1
                }
                await waitPrompt(arch)
                await type(arch, "pacman -S --noconfirm fastfetch > /dev/null 2>&1\r", max: 900)
                await type(arch, cfg)
                await type(arch, "clear; fastfetch\r")
                hideKeyboard(arch)
                await shot("arch")
            }

            // 2. the Distributions list
            show("distros")
            await shot("distros")
            show("close")
            await sleep(1)

            // 3. Ubuntu: apt, in Ubuntu's colours (iPad: beside Arch)
            if !phone { UserDefaults.standard.set(true, forKey: "split") }
            if let ub = await open(store, Distro.named("ubuntu")) {
                await type(ub, "apt-get update > /dev/null 2>&1; apt-get install -y --no-install-recommends cowsay 2>&1 | tail -n 3\r", max: 900)
                await type(ub, "clear; head -n 2 /etc/os-release; /usr/games/cowsay -f tux 'apt works on iPhone'\r")
                hideKeyboard(ub)
                await shot("ubuntu")
            }
            UserDefaults.standard.set(false, forKey: "split")

            // 4. Ports: a server in Debian, listed, then opened in the browser
            store.select(0)
            await sleep(1)
            hideKeyboard(deb)
            await type(deb, "clear; cd /root/Files && python3 -m http.server 8000 > /dev/null 2>&1 &\r", wait: false)
            await sleep(8)
            await type(deb, "clear; ls /root/Files/Examples\r")
            hideKeyboard(deb)
            Ports.shared.scan()
            Ports.shared.announced = nil
            show("ports")
            await shot("ports")
            show("close")
            await sleep(1)
            NotificationCenter.default.post(name: .lxOpenBrowser, object: URL(string: "http://localhost:8000/Examples/")!)
            await sleep(5)
            await shot("browser")
            show("close")
            await sleep(1.5)

            // 5. saved commands, Shortcuts and Siri
            show("snippets")
            await shot("shortcuts")
            show("close")
            await sleep(1)

            // 6. Fedora with the key row: tabs in four distributions
            if let fe = await open(store, Distro.named("fedora")) {
                await type(fe, "head -n 2 /etc/os-release; dnf --version | head -n 1; rpm -q bash\r")
                _ = fe.view.becomeFirstResponder()
                await sleep(1.5)
                await shot("keys")
            }
            try? "done".write(to: dir.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
        }
    }
}

extension Notification.Name {
    /// Tour: show a sheet ("distros", "ports", "snippets") or close everything ("close").
    static let lxTour = Notification.Name("lxTour")
}
