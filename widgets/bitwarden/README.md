# Bitwarden

Your Bitwarden vault from the menu bar: unlock from the card, search item names,
and copy a username, password or verification code. Copies are marked concealed
and cleared from the clipboard after 30 seconds.

- **Unlock** asks for your master password in BarShelf's own prompt. BarShelf
  passes it to the Bitwarden CLI through stdin and keeps only the session the CLI
  returns, in memory. The widget never sees the password, the session, or any
  secret: it gets item names, usernames, hosts and opaque handles.
- The vault locks again after 10 minutes without a vault action from you
  (refreshes don't count), an hour after unlocking at most, when the screen locks,
  when the Mac sleeps, when BarShelf quits, and when the widget is disabled,
  removed or its permission revoked. Locking clears a copied password that is
  still on the clipboard.
- **Touch ID** (optional): tick "Reopen with Touch ID for the next 8 hours" in the
  password prompt. After an idle lock, screen lock or sleep the card then shows
  **Unlock with Touch ID** (and **Use Password**). BarShelf keeps the session
  sealed to your Mac's Secure Enclave, in memory only; only a current fingerprint
  can open it. In the meantime the Bitwarden CLI stays unlocked. **Lock**, quitting
  BarShelf, a fingerprint change, or 8 hours since you typed the password lock
  Bitwarden fully.
- BarShelf signs in to Bitwarden once, in its own CLI profile, separate from the
  `bw` you use in Terminal: unlocking or locking in BarShelf never ends your
  terminal session, and the other way round. The first time, the card shows
  **Sign In** (server and email are filled in from your terminal `bw`; a
  two-step code is asked for if your account uses one; an account without
  two-step login, which Bitwarden then checks by emailed code as a new device,
  signs in with its API key instead). Each unlock then syncs BarShelf's copy of
  the vault, and the card's last sync and server are BarShelf's. To switch
  accounts or servers, press **Sign Out…** on the locked card (BarShelf 0.7.30+):
  after you confirm, BarShelf locks the vault and signs its own profile out;
  your terminal `bw` stays signed in.
- While locked it shows the vault state and when it last synced, and can notify
  you when it hasn't synced for a while.

Needs the Bitwarden CLI (`bw`) installed with Homebrew, npm, volta or bun, logged
in once (`bw login`), and BarShelf 0.7.22 or later (Touch ID: 0.7.23; own sign-in: 0.7.27).
