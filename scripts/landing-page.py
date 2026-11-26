"""GitHub Pages landing page (docs/index.html) for Pocket Distro: SEO meta, Open Graph, JSON-LD, FAQ. Same generator as heyobi/querly."""
import html, json

BADGE = 'app-store-badge.svg'

CSS = """
:root{--bg:#fff;--fg:#14141a;--muted:#5b5b6b;--card:#f4f5f8;--line:#e3e5ec;--accent:#4f6bff}
@media (prefers-color-scheme:dark){:root{--bg:#0b0b10;--fg:#f2f2f6;--muted:#a4a4b4;--card:#16161e;--line:#262633;--accent:#7d93ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:1040px;margin:0 auto;padding:40px 16px 64px}
header{text-align:center}header img.icon{width:112px;height:112px;border-radius:24px;box-shadow:0 10px 30px rgba(0,0,0,.18)}
h1{font-size:clamp(30px,5vw,46px);line-height:1.15;margin:18px 0 10px;letter-spacing:-.02em}
.lead{font-size:clamp(17px,2.2vw,20px);color:var(--muted);max-width:720px;margin:0 auto 22px}
.badge img{height:54px}
.shots{display:flex;gap:14px;overflow-x:auto;padding:28px 0 8px;scroll-snap-type:x mandatory}
.shots img{height:min(560px,70vh);border-radius:18px;scroll-snap-align:center;flex:none;box-shadow:0 8px 24px rgba(0,0,0,.15)}
h2{font-size:28px;margin:48px 0 12px;letter-spacing:-.01em}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px}
.card b{display:block;margin-bottom:4px}
details{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 18px;margin:10px 0}
summary{font-weight:600;cursor:pointer}
a{color:var(--accent)}code{font:15px ui-monospace,Menlo,monospace;background:var(--card);padding:1px 6px;border-radius:6px}
.wide img{width:100%;border-radius:18px;box-shadow:0 8px 24px rgba(0,0,0,.15)}
footer{color:var(--muted);font-size:14px;margin-top:56px;text-align:center}
"""


def page(app):
    faq_ld = {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
        {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in app['faq']]}
    app_ld = {"@context": "https://schema.org", "@type": "SoftwareApplication", "name": app['name'],
              "operatingSystem": "iOS, iPadOS", "applicationCategory": app['category'],
              "description": app['description'], "url": app['store'], "downloadUrl": app['store'],
              "image": app['site'] + 'icon.png', "screenshot": [app['site'] + s for s, _ in app['shots']],
              "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
              "author": {"@type": "Person", "name": "heyobi", "url": "https://github.com/heyobi"}}
    e = html.escape
    shots = '\n'.join(f'    <img src="{s}" alt="{e(alt)}" loading="lazy">' for s, alt in app['shots'])
    feats = '\n'.join(f'    <div class="card"><b>{e(t)}</b>{e(d)}</div>' for t, d in app['features'])
    faq = '\n'.join(f'  <details><summary>{e(q)}</summary><p>{e(a)}</p></details>' for q, a in app['faq'])
    extra = app.get('extra', '')
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(app['title'])}</title>
<meta name="description" content="{e(app['description'])}">
<meta name="keywords" content="{e(app['keywords'])}">
<link rel="canonical" href="{app['site']}">
<link rel="icon" href="icon.png">
<meta name="apple-itunes-app" content="app-id={app['id']}">
<meta property="og:type" content="website">
<meta property="og:title" content="{e(app['title'])}">
<meta property="og:description" content="{e(app['description'])}">
<meta property="og:url" content="{app['site']}">
<meta property="og:image" content="{app['site']}{app['shots'][0][0]}">
<meta name="twitter:card" content="summary_large_image">
<script type="application/ld+json">{json.dumps(app_ld, ensure_ascii=False)}</script>
<script type="application/ld+json">{json.dumps(faq_ld, ensure_ascii=False)}</script>
<style>{CSS}</style>
</head>
<body>
<main>
<header>
  <img class="icon" src="icon.png" alt="{e(app['name'])} app icon" width="112" height="112">
  <h1>{e(app['h1'])}</h1>
  <p class="lead">{e(app['lead'])}</p>
  <a class="badge" href="{app['store']}"><img src="{BADGE}" alt="Download {e(app['name'])} on the App Store"></a>
</header>
<div class="shots">
{shots}
</div>
<h2>{e(app['features_title'])}</h2>
<div class="grid">
{feats}
</div>
{extra}
<h2>Questions</h2>
{faq}
<footer>
  <p><a href="{app['store']}">{e(app['name'])} on the App Store</a> · <a href="{app['repo']}">Source code on GitHub</a> · {app['sibling']}</p>
  <p>{e(app['legal'])}</p>
</footer>
</main>
</body>
</html>
"""


lxterm_app = dict(
    id='6838355342', name='Pocket Distro', category='DeveloperApplication',
    store='https://apps.apple.com/app/id6838355342',
    site='https://pocketdistro.com/', repo='https://github.com/pocketdistro/pocketdistro',
    title='Pocket Distro: real Linux on iPhone and iPad | Debian, Ubuntu, Fedora, AlmaLinux, Arch Linux ARM, apt, dnf, pacman',
    h1='Run real Linux on your iPhone',
    lead='Eight unmodified Linux distributions on a normal, non-jailbroken iPhone and iPad, from the App Store: Debian comes with the app; Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux, openSUSE and Arch Linux ARM are one tap away. Real apt, dnf, zypper, pacman and apk, Python, git, SSH and tmux, servers in a built-in browser, commands from Shortcuts and Siri. Free and open source.',
    description='A real Linux terminal for iPhone and iPad: eight distributions (Debian, Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux, openSUSE, Arch Linux ARM) run unmodified on the device, with their own package managers, Python, git, SSH and tmux. No jailbreak, no cloud machine, no account.',
    keywords='Linux on iPhone, run Linux on iPhone without jailbreak, Debian on iPhone, Ubuntu on iPhone, Fedora on iPhone, AlmaLinux on iPhone, Arch Linux ARM on iPhone, Linux terminal iOS, apt on iPhone, dnf on iPhone, pacman on iPhone, Python pip iPhone, SSH iPhone, tmux iPhone, iSH alternative, a-Shell alternative, command line iPhone',
    shots=[('screens/v101-1-arch.jpg', 'Arch Linux ARM with fastfetch on an iPhone'),
           ('screens/v101-2-distros.jpg', 'The Distributions list: eight distributions, download or open'),
           ('screens/v101-3-ubuntu.jpg', 'Ubuntu in its own colours, with apt'),
           ('screens/v101-4-ports.jpg', 'Ports: a Python server listed with its program'),
           ('screens/v101-7-browser.jpg', 'The built-in browser showing the server'),
           ('screens/v101-5-shortcuts.jpg', 'Saved commands, Shortcuts and Siri'),
           ('screens/v101-6-keys.jpg', 'Fedora with the key row above the keyboard')],
    features_title='Real Linux distributions, not a set of ported commands',
    features=[('Eight distributions', 'Debian comes with the app; Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux, openSUSE and Arch Linux ARM download in seconds. Each is the project\'s own official arm64 image (Arch: its own packages), unmodified and checked before use.'),
              ('Real package managers', 'apt, dnf, zypper, pacman and apk install from the distributions\' own mirrors, maintainer scripts and hooks included.'),
              ('Python, git, SSH, tmux', 'Python and pip (compiled wheels included), git, OpenSSH and tmux; Ctrl-C, Ctrl-Z, fg and bg work as on any Linux machine.'),
              ('Ports and a built-in browser', 'Servers you start, such as python3 -m http.server, Flask or Jupyter, are listed with the program that opened them and open right inside the app.'),
              ('Shortcuts and Siri', 'Run commands and saved commands from the Shortcuts app and Siri, pass text in, send the output to other apps, or run them every day. Seven ready-made tools, from the weather where you are to Hacker News.'),
              ('Files app', '/root/Files is in the Files app\'s Locations, shared by every distribution; open any file in Pocket Distro.'),
              ('Made for the phone', 'Tabs in each distribution\'s colours, a key row with Esc, Ctrl, Tab, arrows and F keys, hardware keyboard shortcuts, saved commands, search in the output, themes and fonts.'),
              ('Private and open source', 'Everything runs on your device; the network is used only when you download a distribution or run a program that needs it. No data is collected. GPL-3.0 on GitHub.')],
    extra="""<h2>On iPad</h2>
<div class="shots">
    <img src="screens/v101-ipad-arch.jpg" alt="iPad: Arch Linux ARM with fastfetch" loading="lazy">
    <img src="screens/v101-ipad-ubuntu.jpg" alt="iPad: Ubuntu and Debian side by side" loading="lazy">
    <img src="screens/v101-ipad-distros.jpg" alt="iPad: the Distributions list" loading="lazy">
</div>
<h2>How it works</h2>
<p>iOS does not let apps generate machine code, so Pocket Distro brings its own AArch64 interpreter and a Linux system-call layer: real <code>fork</code> and <code>execve</code>, pipes, signals, job control, sockets and a terminal with Linux's line discipline. Every distribution's binaries run inside it as they would on an arm64 machine, and its continuous integration installs real packages with each package manager on every change. Package tools are sped up (on AlmaLinux, dnf starts in about 0.4 seconds) and heavy computing is slower than on a computer; an accelerated engine (the same core as WebAssembly in WebKit) makes long jobs several times faster in Debian tabs. The code is open source on <a href="https://github.com/pocketdistro/pocketdistro">GitHub</a>.</p>""",
    faq=[('Can I run Linux on an iPhone without a jailbreak?', 'Yes. Install Pocket Distro from the App Store and open it: Debian 13 for arm64 starts on the phone itself in a few seconds, and seven more distributions are one tap away. No jailbreak, no sideloading, no remote server.'),
         ('Which Linux distributions can I run on iPhone?', 'Debian 13 (included), Ubuntu 26.04 LTS, Alpine Linux, Fedora, AlmaLinux 10, Rocky Linux 10, openSUSE Tumbleweed and Arch Linux ARM, each from its official arm64 image or repositories, unmodified.'),
         ('How do I use apt, dnf or pacman on my iPhone?', 'Open a tab in the distribution and use its package manager as usual: apt install htop in Debian or Ubuntu, dnf install htop in Fedora, AlmaLinux or Rocky Linux, pacman -S htop in Arch Linux ARM.'),
         ('Can I run Python and pip on iPhone?', 'Yes. Python 3 is installed in Debian; pip installs packages from PyPI, including compiled ones such as polars, because Pocket Distro runs real Linux arm64 binaries.'),
         ('Can I run a web server or Jupyter on iPhone?', 'Yes. Start it in a tab and it appears under Ports; open it in the built-in browser. It keeps running while Pocket Distro is open.'),
         ('How is Pocket Distro different from iSH and a-Shell?', 'iSH emulates a 32-bit x86 PC running Alpine; a-Shell offers commands ported to iOS. Pocket Distro runs the distributions\' own 64-bit ARM programs unmodified, with their package managers and archives.'),
         ('Is it fast?', 'Programs run in an interpreter, because iOS allows no JIT, with the package tools sped up: on AlmaLinux, dnf starts in about 0.4 seconds. Shell work, scripts, editors, git and Python are comfortable; heavy computing is slower than on a computer.'),
         ('Is Pocket Distro free?', 'Yes, free with no ads or purchases, and open source under the GPL-3.0.')],
    sibling='<a href="https://heyobi.github.io/pgnotebook/">Tuple: PostgreSQL on iPhone</a>',
    legal='Debian is a registered trademark of Software in the Public Interest, Inc.; the other distributions\' names are trademarks of their owners. Pocket Distro is not affiliated with or endorsed by any of these projects. Linux is a registered trademark of Linus Torvalds.',
)

open('docs/index.html', 'w', encoding='utf-8', newline=chr(10)).write(page(lxterm_app))
print('ok')
