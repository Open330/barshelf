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
- Bitwarden's CLI keeps one session per profile: unlocking here replaces a session
  you unlocked in a terminal, and locking here locks `bw` for both.
- While locked it shows the vault state and when it last synced, and can notify
  you when it hasn't synced for a while.

Needs the Bitwarden CLI (`bw`) installed with Homebrew, npm, volta or bun, logged
in once (`bw login`), and BarShelf 0.7.22 or later.
