<div align="center">

<img src="site/assets/icon.png" width="112" alt="MailSift app icon">

# MailSift

**Open source · Local · Semantic search**

Search all your Apple Mail by meaning, on your Mac.

[**Download**](https://github.com/t42ji2ji/mailsift/releases/latest) · [Website](https://mailsift.dorara.app) · [中文](README.zh-TW.md)

</div>

## Features

**Search by meaning.** Describe what you're looking for ("the invoice from the Kyoto hotel") and MailSift finds it, even when the mail uses other words or another language. An on-device model (EmbeddingGemma 2 on Core ML) is combined with keyword search. Search works while indexing is still running, newest mail first.

**Your mailbox, faster.** Inbox, Flagged, Archive, Trash and Spam, grouped by date. Keyboard on the list: `j`/`k` to move, `e` archive, `#` trash, `s` flag, `u` read/unread, `r`/`R` reply, `f` forward.

**Sorted by topic.** Every message is labelled on your Mac by what it's for: work, people, transactions, notifications, dev, newsletters, promotions. Pick a topic above the list to see only that kind of mail. Reorder or hide topics, or add your own with a one-line description, in Settings.

**Clean up by sender.** See who sends you the most, pick senders, and move all their mail to Trash in one step.

**Works with the AI you already use.** Press ⌘J to ask your local [Claude Code](https://code.claude.com/docs/en/setup) or [Codex](https://developers.openai.com/codex/cli) about your mail, using your own login. No extra API key. It searches and reads through MailSift, and can only *propose* changes: you get a list with a checkbox and a reason for each message, untick what to keep, then confirm. It can also start a reply draft for the open message; drafts open in Mail, nothing is ever sent for you. Conversations are kept, so you can pick up an earlier one from the history.

**For your own agents.** The app bundles a `mailsift` command-line tool with an MCP server:

```sh
/Applications/MailSift.app/Contents/Helpers/mailsift mcp      # MCP server on stdio
/Applications/MailSift.app/Contents/Helpers/mailsift search "flight change" --json
```

## Install

Download the `.dmg` from [Releases](https://github.com/t42ji2ji/mailsift/releases/latest) and drag MailSift into Applications. Requires macOS 15+ on Apple Silicon, and Apple Mail set up with your accounts.

MailSift reads Mail's data on disk, so it asks for **Full Disk Access** (System Settings › Privacy & Security). That is also why it's not on the App Store. Actions such as archive or trash are carried out by Mail, so macOS asks once to let MailSift control Mail. The first index downloads the search model (about 570 MB).

## Privacy

Your mail is indexed and searched on your Mac. MailSift goes online only to download the search model from Hugging Face, and when you use the AI panel: then the messages the agent reads go to Anthropic or OpenAI through your own Claude Code or Codex.

## Build from source

Requires Xcode 16 command line tools.

```sh
./build.sh        # builds build/MailSift.app
swift test
```

Replace the signing identities in `build.sh` and `release.sh` with your own.

## License

GPL-3.0. `Sources/EmbedKit` is adapted from [FluidUse](https://github.com/FluidInference/FluidUse) (Apache 2.0, see `Sources/EmbedKit/NOTICE.md`). Claude and OpenAI marks are from Simple Icons (CC0) and are trademarks of their owners.
