# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: **Security › Report a vulnerability** on this
repository. Don't open a public issue for them. You'll get a reply within a week.

## What the app protects, and how

- **Sign-in token:** stored in the iOS Keychain, on this device only (it isn't included in backups or
  synced). Signing out ends the server session and removes the token, the Hidden PIN and all local data
  for the account.
- **Hidden (the server's Locked Folder):** the PIN is stored behind Face ID / passcode. When the album
  locks (on leaving the app), cached thumbnails, previews and originals of hidden items are deleted.
- **Network:** HTTPS is used whenever the server offers it. Plain HTTP is allowed only to private home
  network addresses, short local names and Tailscale MagicDNS names (`*.ts.net`), which Tailscale encrypts.
  Sign-in over plain HTTP on a home network sends the password unencrypted on that network: use HTTPS
  if the network isn't trusted.
- **No tracking:** there's no analytics or tracking code. Besides your own server, the app only uses
  the system's map service (maps and place search), and opens a maps app or website when you ask it to.
- **Logs** never contain passwords or tokens. The in-app log may contain file names and item ids; it
  leaves the phone only when you share it.

## Automated checks

Every push runs [CodeQL](https://codeql.github.com) (static analysis, Swift),
[gitleaks](https://github.com/gitleaks/gitleaks) (secrets in the code and its history) and
[OSV-Scanner](https://google.github.io/osv-scanner/) (known vulnerabilities in dependencies).
