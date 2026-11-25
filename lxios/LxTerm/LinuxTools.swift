import AppIntents
import Foundation

/// Ready-made tools for Shortcuts and Siri (App Shortcuts: there as soon as LxTerm is
/// installed, each with its icon). Each is a small Python script, standard library only,
/// run in Linux (Debian when it is installed, else the default distribution), its argument
/// passed safely and the script given on standard input.
enum LinuxTool: String, AppEnum {
    case weather, site, network, rates, password, define, news

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Tool" }
    static var caseDisplayRepresentations: [LinuxTool: DisplayRepresentation] = [
        .weather: DisplayRepresentation(title: "Weather here", image: .init(systemName: "cloud.sun")),
        .site: DisplayRepresentation(title: "Is the site up?", image: .init(systemName: "checkmark.shield")),
        .network: DisplayRepresentation(title: "My network", image: .init(systemName: "network")),
        .rates: DisplayRepresentation(title: "Exchange rates", image: .init(systemName: "dollarsign.arrow.circlepath")),
        .password: DisplayRepresentation(title: "Strong password", image: .init(systemName: "key")),
        .define: DisplayRepresentation(title: "Define a word", image: .init(systemName: "book")),
        .news: DisplayRepresentation(title: "Hacker News front page", image: .init(systemName: "newspaper")),
    ]

    /// What the argument means, when there is one.
    var argumentDefault: String {
        switch self {
        case .site: return "https://www.apple.com"
        case .rates: return "USD"
        case .password: return "20"
        case .define: return "serendipity"
        default: return ""
        }
    }

    var script: String {
        switch self {
        case .weather: return #"""
        import json, urllib.request
        d = json.load(urllib.request.urlopen("https://wttr.in/?format=j1", timeout=15))
        a, c = d["nearest_area"][0], d["current_condition"][0]
        place = a["areaName"][0]["value"] + ", " + a["country"][0]["value"]
        print(f"{place}: {c['weatherDesc'][0]['value']}, {c['temp_C']}°C (feels {c['FeelsLikeC']}°C)")
        print(f"Wind {c['windspeedKmph']} km/h, humidity {c['humidity']}%")
        for label, day in zip(["Today", "Tomorrow"], d["weather"][:2]):
            print(f"{label}: {day['mintempC']}–{day['maxtempC']}°C")
        """#
        case .site: return #"""
        import socket, ssl, sys, time, urllib.parse, urllib.request, datetime
        url = sys.argv[1].strip()
        if "://" not in url: url = "https://" + url
        t = time.time()
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "LxTerm"}), timeout=15)
            code, final, server = r.status, r.geturl(), r.headers.get("Server", "?")
        except urllib.error.HTTPError as e:
            code, final, server = e.code, url, e.headers.get("Server", "?")
        except Exception as e:
            print(f"DOWN: {url} ({e.__class__.__name__}: {e})"); sys.exit(0)
        ms = round((time.time() - t) * 1000)
        print(f"{'UP' if code < 400 else 'ERROR'}: {code} in {ms} ms, server {server}")
        if final != url: print(f"Redirected to {final}")
        host = urllib.parse.urlparse(final).hostname
        if final.startswith("https://") and host:
            with socket.create_connection((host, 443), timeout=10) as s:
                with ssl.create_default_context().wrap_socket(s, server_hostname=host) as t2:
                    exp = datetime.datetime.strptime(t2.getpeercert()["notAfter"], "%b %d %H:%M:%S %Y %Z")
            left = exp.replace(tzinfo=datetime.timezone.utc) - datetime.datetime.now(datetime.timezone.utc)
            print(f"Certificate valid for {left.days} more days")
        """#
        case .network: return #"""
        import json, urllib.request
        d = json.load(urllib.request.urlopen("https://ipinfo.io/json", timeout=15))
        print(f"IP {d.get('ip')}")
        print(f"{d.get('city')}, {d.get('region')}, {d.get('country')}")
        print(f"Provider: {d.get('org', '?')}")
        print(f"Time zone: {d.get('timezone', '?')}")
        """#
        case .rates: return #"""
        import json, sys, urllib.request
        base = (sys.argv[1].strip() or "USD").upper()
        to = ",".join(c for c in ["USD", "EUR", "GBP", "JPY", "CHF", "CNY", "TRY", "CAD"] if c != base)
        d = json.load(urllib.request.urlopen(f"https://api.frankfurter.app/latest?from={base}&to={to}", timeout=15))
        print(f"1 {base} on {d['date']}:")
        for k, v in d["rates"].items(): print(f"  {k} {v:,.4f}")
        """#
        case .password: return #"""
        import secrets, string, sys
        n = max(8, min(128, int(sys.argv[1] or 20)))
        abc = string.ascii_letters + string.digits + "-_.!@#%+="
        while True:
            p = "".join(secrets.choice(abc) for _ in range(n))
            if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p): break
        print(p)
        """#
        case .define: return #"""
        import json, sys, urllib.parse, urllib.request
        word = sys.argv[1].strip()
        try:
            d = json.load(urllib.request.urlopen(urllib.request.Request("https://api.dictionaryapi.dev/api/v2/entries/en/" + urllib.parse.quote(word), headers={"User-Agent": "LxTerm"}), timeout=15))
        except Exception:
            print(f"No definition found for “{word}”."); sys.exit(0)
        print(word + (f"  {d[0].get('phonetic', '')}" if d[0].get("phonetic") else ""))
        for m in d[0]["meanings"][:3]:
            for x in m["definitions"][:2]:
                print(f"({m['partOfSpeech']}) {x['definition']}")
                if x.get("example"): print(f"   e.g. {x['example']}")
        """#
        case .news: return #"""
        import json, urllib.request
        d = json.load(urllib.request.urlopen("https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=8", timeout=15))
        for i, h in enumerate(d["hits"], 1):
            print(f"{i}. {h['title']} ({h.get('points', 0)} points)")
            print(f"   {h.get('url') or 'https://news.ycombinator.com/item?id=' + h['objectID']}")
        """#
        }
    }
}

/// Runs one of the tools and returns what it printed (Siri reads it out).
struct LinuxToolIntent: AppIntent {
    static var title: LocalizedStringResource = "Linux Tool"
    static var description = IntentDescription("Ready-made tools that run in Linux on this device: the weather where you are, whether a site is up, your network, exchange rates, a strong password, a word's definition, Hacker News.")

    @Parameter(title: "Tool", default: .weather) var tool: LinuxTool
    @Parameter(title: "Argument", description: "The site, currency, password length or word, for the tools that take one.") var argument: String?

    init() {}
    init(_ tool: LinuxTool) { self.tool = tool }

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$tool)") { \.$argument }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard await MainActor.run(body: { Store.prepareEngine() }) else { throw IntentFailure.notReady }
        let d = Distro.debian.installed ? Distro.debian : (Distro.preferred ?? .debian)
        guard d.installed else { throw IntentFailure.notDownloaded(d.name) }
        let arg = (argument ?? "").isEmpty ? tool.argumentDefault : argument!
        let quoted = "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let out = try await Headless.run("python3 - \(quoted)", root: d.builtIn ? nil : d.root.path, seconds: 25, input: tool.script)
        return .result(value: out, dialog: IntentDialog(stringLiteral: out.isEmpty ? String(localized: "Done.") : String(out.prefix(800))))
    }
}
