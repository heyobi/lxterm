"""GitHub Pages landing page (docs/index.html) for LxTerm: SEO meta, Open Graph, JSON-LD, FAQ. Same generator as heyobi/querly."""
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
    id='6838355342', name='LxTerm Shell', category='DeveloperApplication',
    store='https://apps.apple.com/app/id6838355342',
    site='https://heyobi.github.io/lxterm/', repo='https://github.com/heyobi/lxterm',
    title='LxTerm: a real Linux terminal on iPhone and iPad | Debian, apt, Python, pip, SSH, tmux',
    h1='Run real Linux on your iPhone',
    lead='LxTerm runs Debian 13 for arm64 on a normal, non-jailbroken iPhone and iPad: install software with apt, run Python with pip, keep sessions in tmux and connect over SSH. Offline, private, free and open source.',
    description='A real Linux terminal for iPhone and iPad: Debian 13 arm64 runs unmodified on the device, with apt, bash, Python 3 and pip, git, SSH, tmux, nano and job control. No jailbreak, no cloud machine, no account.',
    keywords='Linux on iPhone, run Linux on iPhone without jailbreak, Debian on iPhone, Linux terminal iOS, apt on iPhone, Python pip iPhone, SSH client with Linux iPhone, tmux iPhone, bash shell iPad, iSH alternative, a-Shell alternative, command line iPhone',
    shots=[('screens/iphone-1-fetch.jpg', 'fastfetch in Debian 13 on an iPhone'),
           ('screens/iphone-2-python.jpg', 'The Python 3 REPL'),
           ('screens/iphone-3-tmux.jpg', 'tmux with nano in a split pane'),
           ('screens/iphone-4-keys.jpg', 'The key row with Esc, Ctrl, Tab and arrows above the keyboard'),
           ('screens/iphone-5-theme.jpg', 'The Solarized theme')],
    features_title='A real Linux system, not a set of ported commands',
    features=[('Debian 13, unmodified', "Debian's own arm64 programs, exactly as Debian builds them: glibc, bash, coreutils, dpkg and apt."),
              ('apt works', 'Thousands of packages from Debian\'s archive are one command away: git, vim, htop, ssh and more.'),
              ('Python and pip', 'Python 3 comes installed; pip installs Linux packages from PyPI, including compiled libraries such as polars.'),
              ('tmux and job control', 'Ctrl-C, Ctrl-Z, fg and bg work as on any Linux machine; split panes in tmux.'),
              ('SSH and git', 'Connect to your servers with OpenSSH and clone repositories over https or ssh.'),
              ('Made for the phone', 'A native app with tabs, a key row (Esc, Ctrl, Tab, arrows, symbols), themes and adjustable font size. Your terminal is there when you come back.'),
              ('iPad', 'A full-size terminal with a hardware keyboard or the on-screen one.'),
              ('Private and offline', 'Everything runs on your device; the network is used only when you run apt, pip, ssh or curl. No data is collected.')],
    extra="""<h2>On iPad</h2>
<div class="shots">
    <img src="screens/ipad-1-fetch.jpg" alt="iPad: fastfetch in Debian 13" loading="lazy">
    <img src="screens/ipad-3-tmux.jpg" alt="iPad: tmux with nano" loading="lazy">
    <img src="screens/ipad-4-keys.jpg" alt="iPad: the key row above the keyboard" loading="lazy">
</div>
<h2>How it works</h2>
<p>iOS does not let apps generate machine code, so LxTerm brings its own AArch64 interpreter and a Linux system-call layer: real <code>fork</code> and <code>execve</code>, pipes, signals, job control and a terminal with Linux's line discipline. Debian's binaries run inside it as they would on an arm64 machine. Heavy number crunching is slower than on a computer; everyday command-line work, scripting and learning Linux feel at home. The code is open source on <a href="https://github.com/heyobi/lxterm">GitHub</a>.</p>""",
    faq=[('Can I run Linux on an iPhone without a jailbreak?', 'Yes. Install LxTerm from the App Store and open it: Debian 13 for arm64 starts on the phone itself in a few seconds, with no jailbreak, no sideloading and no remote server.'),
         ('How do I use apt on my iPhone?', 'Open LxTerm and type apt update, then apt install followed by a package name, for example apt install htop. Packages come from Debian\'s own mirrors.'),
         ('Can I run Python and pip on iPhone?', 'Yes. Python 3 is installed; add pip with apt install python3-pip and install packages from PyPI, including compiled ones such as polars, because LxTerm runs real Linux arm64 binaries.'),
         ('Does LxTerm have SSH and tmux?', 'Yes. tmux is installed, and OpenSSH is one apt install away (apt install openssh-client). Ctrl-C, Ctrl-Z and job control work as on Linux.'),
         ('How is LxTerm different from iSH and a-Shell?', 'iSH emulates a 32-bit x86 PC running Alpine; a-Shell offers commands ported to iOS. LxTerm runs Debian\'s own 64-bit ARM programs unmodified, with apt and Debian\'s whole package archive.'),
         ('Is it fast?', 'Programs run in an interpreter, because iOS allows no JIT. Shell work, scripts, editors, git and Python are comfortable; heavy computing such as large compiles is slower than on a computer.'),
         ('Is LxTerm free?', 'Yes, free with no ads or purchases, and open source under the GPL-3.0.')],
    sibling='<a href="https://heyobi.github.io/pgnotebook/">Tuple: PostgreSQL on iPhone</a> · <a href="https://heyobi.github.io/querly/">Querly: CSV and DuckDB on iPhone</a>',
    legal='Debian is a registered trademark of Software in the Public Interest, Inc. LxTerm is not affiliated with or endorsed by the Debian Project. Linux is a registered trademark of Linus Torvalds.',
)

open('docs/index.html', 'w', encoding='utf-8').write(page(lxterm_app))
print('ok')
