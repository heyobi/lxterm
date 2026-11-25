# LxTerm 1.0.1 — App Store texts (draft, not published)

## What's New

### en-US
More Linux, one tap away:
• Eight distributions: Debian is built in; Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux, openSUSE and Arch Linux ARM download in seconds, each in its own tabs with its own colours
• Ports: servers you start (Python, Jupyter, Flask) appear in a list and open in the built-in browser
• Shortcuts and Siri: run commands and saved commands, pass text in, chain the output to other apps, run them every day; seven ready-made tools (weather, site check, exchange rates, password, dictionary, Hacker News…)
• Files app: /root/Files is in Locations, and "Open in LxTerm" from any app
• Saved commands, search in the output, F keys, hardware keyboard shortcuts, two terminals side by side on iPad and in landscape
• Fonts, cursor styles, automatic light and dark theme
• Fixes: arrow keys after reopening, smart quotes from the keyboard

### tr
Linux artık bir dokunuş uzağında:
• Sekiz dağıtım: Debian uygulamayla gelir; Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux, openSUSE ve Arch Linux ARM saniyeler içinde iner, her biri kendi sekmelerinde, kendi renkleriyle
• Portlar: başlattığın sunucular (Python, Jupyter, Flask) bir listede görünür, yerleşik tarayıcıda açılır
• Kestirmeler ve Siri: komut ve kayıtlı komut çalıştır, metin gönder, çıktıyı başka uygulamalara aktar, her gün otomatik çalıştır; yedi hazır araç (hava durumu, site kontrolü, döviz kurları, şifre, sözlük, Hacker News…)
• Dosyalar uygulaması: /root/Files Konumlar'da; her uygulamadan "LxTerm'de aç"
• Kayıtlı komutlar, çıktıda arama, F tuşları, donanım klavyesi kısayolları, iPad'de ve yatayda yan yana iki terminal
• Yazı tipleri, imleç biçimleri, otomatik açık/koyu tema
• Düzeltmeler: yeniden açınca ok tuşları, klavyenin akıllı tırnakları

(es-MX, pt-BR, de-DE: the same text, translated.)

## Description — changed parts (en-US; tr and the others translated the same way)

First paragraph:
LxTerm puts a real Linux system on your iPhone: Debian 13 for arm64, unmodified, running right on the device, and Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux, openSUSE and Arch Linux ARM one tap away. Install software with apt, dnf, zypper or pacman, write Python with pip, keep sessions alive in tmux and connect to your servers over SSH. No jailbreak, no cloud machine, no account.

New section after A REAL LINUX SYSTEM:
EIGHT DISTRIBUTIONS
• Debian comes with the app; the others are each project's own official arm64 images, downloaded when you choose them and checked before use
• Every distribution in its own tabs and colours; pick a default, reset or remove any of them

New section:
SHORTCUTS, SIRI AND SERVERS
• Run commands from the Shortcuts app and Siri, pass text in and send the output to other apps, or run them every day with an automation
• Seven ready-made tools: weather where you are, is a site up, your network, exchange rates, a strong password, a word's definition, Hacker News
• Servers you start in the terminal appear under Ports and open in the built-in browser: Python's web server, Jupyter, Flask
• /root/Files is in the Files app, and any file can be opened in LxTerm

MADE FOR THE PHONE gains:
• Saved commands, search in the output, F keys and hardware keyboard shortcuts
• Two terminals side by side on iPad and in landscape
• Themes, fonts, cursor styles, automatic light and dark

Last paragraph:
LxTerm is free and open source (GPL-3.0), with no ads and no in-app purchases. Debian is a registered trademark of Software in the Public Interest, Inc. The other distributions' names are trademarks of their owners. LxTerm is not affiliated with or endorsed by any of these projects.

## Unchanged
Name (LxTerm Shell), subtitle, keywords (no other project's name in them), promo text, privacy answers (still no data collected), age rating.

## Review notes — added
7. Distributions (Settings › Distributions): downloads the official arm64 images of Ubuntu, Alpine, Fedora, AlmaLinux, Rocky Linux and openSUSE from Docker Hub (digests checked), and Arch Linux ARM's packages from its own mirrors, only when the user taps Download. They run in the same interpreter; no code of the app changes.
8. Shortcuts and Siri: the app's App Intents run commands the user chose (or the built-in tools) in that interpreter and return their text output.
