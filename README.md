# Headroom AI

A macOS menu bar app that shows how much of your rate limit is left across many
Claude Code and Codex accounts at once — the five-hour window, the weekly one,
per-model limits, and when each resets.

It exists because both CLIs only ever show the account you happen to be logged
into. With a dozen subscriptions, finding a usable one means switching accounts
and checking, over and over.

![The panel with nine accounts connected](Screenshots/panel.png)

## What it shows

Each account gets a cell with one line per limit window the provider reports:
its label, how much is used, and when it comes back. Colour appears only when
something needs attention — amber past 80%, red at 100% — so a quiet row is a
healthy row.

The menu bar carries one indicator per provider, because running out of Claude
Code is not helped by Codex sitting idle. What the number means is yours to
choose in Settings:

| Setting | Answers |
| --- | --- |
| Best account | How full the emptiest account is — where you would switch to |
| Busiest account | How full the fullest one is — what is about to run out |
| Accounts with room | How many are still under 80% |

Whichever you pick, the icon fills the same way: full means nothing left.

## A populated window to look at

Running with `HEADROOM_DEMO=1` fills the panel with nine invented accounts
covering every state it can be in — fresh, busy, over the amber line,
exhausted, signed out and stale. It neither reads nor writes the account store
and never polls, so it cannot disturb real accounts. This is how the
screenshot above was taken.

    make app
    HEADROOM_DEMO=1 ".build/Headroom AI.app/Contents/MacOS/Headroom"

## Requirements

macOS 14 or later and a Swift 6 toolchain. No third-party dependencies.

## Build and run

    make app
    open ".build/Headroom AI.app"

    swift test

## Adding accounts

Click the menu bar icon, then **Add account**, and pick a provider. Your browser
opens; sign in there. There is nothing to type — the account is identified and
labelled by the email address its provider reports.

Signing in here creates its own token pair. It does **not** touch the accounts
you are logged into in the `claude` or `codex` CLI, and those logins do not
touch this app's.

Adding a **Codex** account needs port 1455 free, because that is the only
redirect address OpenAI accepts for this flow. It cannot run while
`codex login` is waiting.

Tokens are stored in `~/Library/Application Support/Headroom/accounts.json`
with `0600` permissions and refreshed automatically, so you sign in once per
account.

### If an account reports no usage

An Anthropic login can belong to more than one organisation — a subscription
and an API Console team, say — and the token is issued for one of them. Only
the subscription organisation reports these limits; a token issued for an API
organisation is refused with `oauth_not_allowed_for_organization`. The app says
which organisation it got, and whether that login has a subscription at all.

## Releasing a signed build

`make app` signs ad hoc, which is fine on the machine that built it and
refused as "unidentified developer" everywhere else. A build other people can
open has to be signed with a Developer ID certificate and notarised by Apple.

Store the notarisation credentials once — the password is an app-specific one
from appleid.apple.com, not your Apple ID password:

    xcrun notarytool store-credentials headroom-notary \
      --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>

Then:

    make release

That builds, signs with the hardened runtime and a secure timestamp, packages a
DMG, submits it for notarisation, waits, staples the ticket to the DMG and
verifies the result. Stapling is what lets the first launch work without a
network connection.

Set `TEAM_ID` and `SIGN_ID` in the Makefile to your own certificate.

## Launch at login

System Settings → General → Login Items → add `Headroom AI.app`.

## What this is not

This is an unofficial tool. It talks to the same endpoints the official CLIs
use, with the same OAuth client, and identifies itself as the CLI does. Neither
Anthropic nor OpenAI publishes or supports these endpoints, so they can change
or start refusing this at any time. Use it accordingly.

It reads usage only. It never sends prompts, never spends any limit, and stores
nothing beyond the tokens it needs and two preferences.

## Credits

The shape of both providers' APIs and the OAuth flows were worked out with help
from [claude-swap](https://github.com/realiti4/claude-swap) and
[codex-check](https://github.com/Leask/codex-check), both MIT licensed.

## Licence

MIT — see [LICENSE](LICENSE).
