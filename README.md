![Xray showing a searchable grid of imported X bookmarks](Documentation/xray-header.png)

# Xray

[![macOS 15.6 or later](https://badgen.net/badge/macOS/15.6%2B/black?icon=apple)](https://www.apple.com/macos/)
[![Swift 5](https://badgen.net/badge/Swift/5/orange)](https://www.swift.org/)
[![MIT license](https://badgen.net/badge/license/MIT/blue)](LICENSE)

Xray is a native macOS app for keeping, searching, and organizing a local
library of your X bookmarks. It imports bookmarks from a browser session or a
JSON file, stores them in SQLite, and can generate local text and image
embeddings for semantic search.

Xray is not affiliated with X Corp.

## What it does

- Imports bookmarks directly from `x.com/i/bookmarks` with the included userscript.
- Preserves text, authors, quoted posts, articles, links, images, and video previews.
- Searches exact text, fields, topics, and grouped boolean expressions.
- Generates text and image embeddings on-device with MLX and Qwen3 models.
- Optionally generates primary and secondary topics through OpenAI or OpenRouter.
- Keeps the bookmark library and generated embeddings in a local SQLite database.

## Requirements

- macOS 15.6 or later
- An Apple silicon Mac for the MLX embedding models
- Xcode with the macOS 15.6 SDK or later
- A userscript manager such as [Violentmonkey](https://violentmonkey.github.io/)
  for direct browser capture
- An OpenAI or OpenRouter API key only if you want automatic topic generation

## Build and run

1. Clone the repository:

   ```sh
   git clone https://github.com/alexeyalbert/xray.git
   cd xray
   ```

2. Open `Xray.xcodeproj` in Xcode. Swift Package Manager will resolve the
   dependencies from the checked-in `Package.resolved` file.
3. Select the `Xray` scheme and the `My Mac` destination.
4. If Xcode reports a signing error, choose your development team under
   **Xray target > Signing & Capabilities**. The app uses the macOS App Sandbox.
5. Build and run with **Product > Run**.
6. Complete the first-launch setup. The local Qwen3 text and image embedding
   models are downloaded from Hugging Face into Xray's Application Support
   directory. Topic generation can be skipped.

You can replay the setup later from **Xray > Replay Onboarding**.

## Import bookmarks

### Stream from the browser

1. Install a userscript manager. Violentmonkey is the recommended option.
2. Create a new userscript, replace its contents with
   [`Xray Bookmarks Exporter Userscript/xray-bookmarks-exporter.user.js`](Xray%20Bookmarks%20Exporter%20Userscript/xray-bookmarks-exporter.user.js),
   and save it.
3. Open or reload `https://x.com/i/bookmarks` while signed in.
4. In Xray, open **Settings > Debug** and enable the toolbar info button.
5. Choose **Bookmarks > Start Browser Import Receiver**.
6. Open the info button in Xray and copy its receiver URL and session token
   into the userscript panel.
7. Select **Connect to Xray**, then **Start capture**.

The receiver listens on localhost and accepts batches only when they include
the current session token. The script can pause, resume, retry interrupted
batches, and stop after it reaches bookmarks that are already in the library.

### Import a JSON file

The userscript can save an Xray-compatible JSON file instead of opening a
localhost connection. After capture finishes, download the file and choose
**Bookmarks > Import from file** in Xray. Existing post IDs are skipped rather
than duplicated.

## How it works

The userscript observes the bookmark timeline responses already made by your
signed-in X browser tab. It normalizes those responses and either sends them
to Xray in batches over localhost or writes them to a JSON export. It does not
ask for or handle your X password.

Xray stores imported posts in SQLite. Text embeddings are generated with
`Qwen3-Embedding-0.6B-8bit`; image embeddings use
`Qwen3-VL-Embedding-2B-8bit`. Both models run locally through MLX. Search can
combine ordinary text and field operators with those stored vectors, while
the feed keeps bookmark order available as a separate result mode.

Topic generation is independent of embeddings. When enabled, Xray sends the
post text and a limited set of available public media to the selected API and
saves the returned topics in the local database. OpenRouter requests ask for
Zero Data Retention routing.

## Privacy

- Imported posts, topics, and embeddings are stored under Xray's sandboxed
  Application Support directory. They are not uploaded to an Xray-operated
  service.
- Local embedding inference stays on the Mac. Model files are downloaded from
  Hugging Face when you install them.
- Images and video previews are fetched from the source URLs recorded in the
  imported bookmark data when Xray needs to display or process them.
- Topic generation is optional. If enabled, post text and selected public
  media are sent directly to OpenAI or OpenRouter. OpenRouter requests include
  a Zero Data Retention routing preference, but the provider's own terms and
  policies still apply.
- API keys and the browser-import session token are stored in the macOS
  Keychain. Ordinary preferences are stored in `UserDefaults`.
- Browser streaming is local to your Mac and token-protected. JSON export mode
  stores its bookmark buffer in the userscript manager until you clear it.
- Xray does not include an analytics or telemetry service.

Review the source before importing sensitive data, and keep exported JSON
files private: they contain the bookmark content captured from your account.

## Search

Plain terms search post content. Quoted strings and backticks group phrases;
backticks are useful for multi-word topics. Field operators include
`topic:`, `p_topic:`, and `s_topic:`. Full subqueries can be combined with
`&&` and `||`. The search controls in the toolbar list the currently supported
operators and semantic-search thresholds.

Examples:

```text
topic:`graphic design`
p_topic:technology && `machine learning`
user:username || s_topic:photography
```

## Acknowledgments

The bookmark userscript is based on
[prinsss/twitter-web-exporter](https://github.com/prinsss/twitter-web-exporter),
created by prin and distributed under the MIT License. Its original copyright
and license text are preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

Xray is available under the [MIT License](LICENSE). Third-party packages and
derived work remain subject to their respective license notices.
