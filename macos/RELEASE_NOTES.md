The app is now **signed with a Developer ID and notarized by Apple**, so it opens like any other app, without the "cannot verify the developer" dialog. It can also be installed with Homebrew.

**Install**

```bash
brew install --cask drzaphod85/tap/opensubtitles-uploader
```

or download the DMG below and drag *OpenSubtitles Uploader* to Applications. Requires macOS 14 (Sonoma) or later; universal binary (Apple silicon and Intel).

**New in 1.1.0**

- **Queue for several subtitles.** Drop several files or a whole folder and every subtitle is paired with its video (same name, same `S01E02` tag; one video can serve several languages). The queue appears above the form, select a row to edit it, and **Upload All** (⇧⌘↩) uploads the queue item by item with a summary at the end. This is the batch upload requested in the original project's issue #14.
- **Check before upload** (⇧⌘K): asks OpenSubtitles whether a subtitle is already in the database without uploading it, for one item or the whole queue.
- **Upload History** (Window › Upload History, ⇧⌘H): everything uploaded from this Mac, with links to the subtitle pages.
- **Notifications** when an upload or a whole queue has finished and the app is in the background.
- Subtitles with short names such as `Movie.2020.srt` now find their video; language and marker tags (`.en`, `.pt-BR`, `.forced`) are ignored when matching.

**Good to know**

- The IMDb title search and the backdrop image need your own free TMDB API key: paste it in *Settings › General › The Movie Database* (there is a Verify button). Everything else works without it.
- Based on [Jean van Kasteel's OpenSubtitles Uploader](https://github.com/vankasteelj/opensubtitles-uploader) (GPL-3.0). See [macos/README.md](https://github.com/drzaphod85/opensubtitles-uploader/blob/master/macos/README.md) for details.
