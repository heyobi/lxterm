# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

- GitHub: **Security › Report a vulnerability** on this repository (private advisory), or
- email: **support@pocketdistro.com** with "security" in the subject.

Include what you found, how to reproduce it and which version or TestFlight build you used. You will get an answer within a week; fixes go to TestFlight first and to the App Store with the next release. We credit reporters who want to be named.

## What is in scope

Pocket Distro runs Linux programs inside the iOS app's own sandbox: the distributions' programs are interpreted, they cannot reach outside the app's storage, and the app's own code is fixed at build time. Problems we want to hear about include:

- a way for a program in a distribution to read or write outside the app's container, or to run host code it brought;
- the download path accepting an image, layer or package whose digest or signature does not match (images are checked against their SHA-256 digests; Arch Linux ARM packages also by pacman's signatures);
- archive unpacking writing outside the distribution's folder;
- the Shortcuts, Files or Ports integrations exposing data to other apps beyond what the user chose;
- the translated libraries or the fast start making a program behave differently from the interpreter in a way that affects security.

## Out of scope

- Vulnerabilities in the distributions' own packages: report them to the distribution (fixes reach you through its package manager, as on any machine).
- Root inside a distribution: every tab runs as root by design, inside the app's sandbox.

## Supported versions

The current App Store version and the newest TestFlight build.
