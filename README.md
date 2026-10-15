# Screen Answers

A small floating window in the top-right corner of your Mac. Press **Control + Option + A** and it screenshots your screen, sends it to Claude Opus 5.5, and shows the answers right there. Useful for checking your work on practice tests and homework.

- **Running chat:** every screenshot adds to the same conversation, so you can capture a figure, scroll, then capture the question, and Claude puts them together. **New Chat** starts over.
- **Multiple choice:** shows just the number and letter, like **3.** B. If you've already picked an answer it adds ✅ or ❌.
- **Follow-ups:** type in the box at the bottom, like "explain 4".
- The window stays out of its own screenshots.

## What you need

- A Mac running macOS 14 (Sonoma) or newer
- Apple's free command line tools. If you've never installed them, open **Terminal** and run:
  ```bash
  xcode-select --install
  ```
- Your own **Anthropic API key**, which is separate from a Claude subscription:
  1. Go to [console.anthropic.com](https://console.anthropic.com) and sign up.
  2. **Settings → Billing**: add a few dollars of credit. Each screenshot costs about 2–5 cents.
  3. **API Keys → Create Key**: copy the key (starts with `sk-ant-`). It's only shown once.

## Install

Open **Terminal** and run:

```bash
git clone https://github.com/coopercohen/screen-answers.git ~/ScreenAnswers
```

```bash
cd ~/ScreenAnswers && ./build.sh
```

That creates `ScreenAnswers.app` in the `ScreenAnswers` folder in your home folder.

## First launch

Screen Recording permission is the tricky part, so follow these steps in order:

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Click **+**, choose `ScreenAnswers.app` from your `ScreenAnswers` folder, and make sure its switch is **on**.
3. **Double-click `ScreenAnswers.app` in Finder** to open it. Always open it yourself from Finder, not from Terminal or another app, or macOS may block the screen capture.
4. Paste your API key into the box at the bottom of the window and press **Enter**. It's saved only on your Mac, in `~/.config/screen-answers/api_key`.
5. Press **Control + Option + A**.

There's also an icon in the menu bar for capturing, starting a new chat, showing or hiding the window, changing your key, and quitting.

## Troubleshooting

- **"Couldn't capture the screen":** the permission isn't on for this exact copy of the app. In Settings, remove Screen Answers with **–**, add it again with **+**, then quit and reopen it from Finder.
- **If you rebuild the app** (for example after pulling updates), macOS treats it as a new app. Repeat the permission steps above.
- **"Your API key was rejected":** menu bar icon → **Change API Key…** and paste it again.
- A log is kept at `~/Library/Logs/ScreenAnswers.log`. It never includes your key or screenshots.

## Settings

At the top of `main.swift`:
- `effort`: `"medium"` by default. `"high"` is slower but more careful; `"low"` is faster.
- The system prompt controls how answers are formatted.

After changing anything, run `./build.sh` again and redo the permission steps.
