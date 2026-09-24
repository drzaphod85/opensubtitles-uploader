#!/usr/bin/env python3
"""Generate Localizable.strings (.lproj) files from the original app/localization/*.json files.

Usage: python3 Scripts/generate-strings.py  (run from the macos/ folder)
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, '..', '..', 'app', 'localization'))
DST = os.path.normpath(os.path.join(HERE, '..', 'Sources', 'OpenSubtitlesUploader', 'Resources'))

# Map original locale ids to Apple lproj identifiers.
LPROJ = {'pt-br': 'pt-BR', 'zh': 'zh-Hans', 'no': 'nb'}
# Translations of the Mac-only strings live in macos/Localization/<lproj>.json
MAC_L10N = os.path.normpath(os.path.join(HERE, '..', 'Localization'))

# Extra strings used only by the Mac version (English fallback).
EXTRA = {
    "Sign In…": "Sign In…",
    "Sign Out": "Sign Out",
    "Cancel": "Cancel",
    "Open Profile": "Open Profile",
    "Logged in as %@": "Logged in as %@",
    "Appearance": "Appearance",
    "System": "System",
    "Light": "Light",
    "Dark": "Dark",
    "General": "General",
    "Shortcuts": "Shortcuts",
    "About": "About",
    "Choose…": "Choose…",
    "Open…": "Open…",
    "Clear Files": "Clear Files",
    "Search IMDb…": "Search IMDb…",
    "Check for Updates Now": "Check for Updates Now",
    "You are up to date.": "You are up to date.",
    "Unable to check for updates.": "Unable to check for updates.",
    "Download": "Download",
    "Later": "Later",
    "Open in IMDb": "Open in IMDb",
    "Version %@": "Version %@",
    "The application language follows your system preference. You can choose a different language for this app in System Settings › General › Language & Region.": "The application language follows your system preference. You can choose a different language for this app in System Settings › General › Language & Region.",
    "Open Language & Region…": "Open Language & Region…",
    "Source code on GitHub": "Source code on GitHub",
    "Video": "Video",
    "Subtitle": "Subtitle",
    "Not logged in": "Not logged in",
    "Uploading…": "Uploading…",
    "Analyzing video…": "Analyzing video…",
    "No results": "No results",
    "Locked: value is kept between sessions": "Locked: value is kept between sessions",
    "Unlocked: click to keep this value between sessions": "Unlocked: click to keep this value between sessions",
    "Search": "Search",
    "Use HTTPS when talking to OpenSubtitles": "Use HTTPS when talking to OpenSubtitles",
    "Check for updates automatically": "Check for updates automatically",
    "Drop a video and a subtitle file anywhere in this window, or use the Choose… buttons.": "Drop a video and a subtitle file anywhere in this window, or use the Choose… buttons.",
    "Password is stored securely in your Keychain.": "Password is stored securely in your Keychain.",
    "Remove video": "Remove video",
    "Remove subtitle": "Remove subtitle",
    "Look up the IMDb id automatically when a video is added": "Look up the IMDb id automatically when a video is added",
    "Video could not be identified by OpenSubtitles. Metadata was read from the file; set the IMDb id manually.": "Video could not be identified by OpenSubtitles. Metadata was read from the file; set the IMDb id manually.",
    "Install mediainfo or ffprobe (e.g. with Homebrew) to read duration and frame rate from this file type.": "Install mediainfo or ffprobe (e.g. with Homebrew) to read duration and frame rate from this file type.",
    "IMDb id is locked and was kept. Detected: %@": "IMDb id is locked and was kept. Detected: %@",
    "Identification": "Identification",
    "macOS version by": "macOS version by",
    "Original project": "Original project",
    "TMDB API key": "TMDB API key",
    "Verify": "Verify",
    "The key works.": "The key works.",
    "TMDB rejected this key.": "TMDB rejected this key.",
    "Could not reach TMDB.": "Could not reach TMDB.",
    "Get a free key…": "Get a free key…",
    "The Movie Database (TMDB)": "The Movie Database (TMDB)",
    "Used for the IMDb title search and the backdrop image. TMDB asks every user to create their own free key; without one, those two features are disabled.": "Used for the IMDb title search and the backdrop image. TMDB asks every user to create their own free key; without one, those two features are disabled.",
    "Search needs a TMDB API key": "Search needs a TMDB API key",
    "Add your own free TMDB API key in Settings to enable the title search and the backdrop image.": "Add your own free TMDB API key in Settings to enable the title search and the backdrop image.",
    "Open Settings…": "Open Settings…",
    "Queue": "Queue",
    "Upload All": "Upload All",
    "Check": "Check",
    "Check All": "Check All",
    "Ask OpenSubtitles whether this subtitle is already in the database, without uploading": "Ask OpenSubtitles whether this subtitle is already in the database, without uploading",
    "Remove from queue": "Remove from queue",
    "Remove uploaded items": "Remove uploaded items",
    "Reveal in Finder": "Reveal in Finder",
    "Open on OpenSubtitles": "Open on OpenSubtitles",
    "Upload History": "Upload History",
    "Clear History": "Clear History",
    "Remove": "Remove",
    "Date": "Date",
    "Result": "Result",
    "Status": "Status",
    "Uploaded": "Uploaded",
    "Already in database": "Already in database",
    "Ready": "Ready",
    "Checking…": "Checking…",
    "Failed": "Failed",
    "No subtitle file": "No subtitle file",
    "Not checked": "Not checked",
    "%@ of %@ uploaded": "%@ of %@ uploaded",
    "Added %@ items to the queue": "Added %@ items to the queue",
    "Batch upload finished: %@ uploaded, %@ already in the database, %@ failed.": "Batch upload finished: %@ uploaded, %@ already in the database, %@ failed.",
    "Not in the database yet, ready to upload.": "Not in the database yet, ready to upload.",
    "No uploads yet.": "No uploads yet.",
    "%@ uploads": "%@ uploads",
    "This removes the list in this app only; nothing is deleted on OpenSubtitles.": "This removes the list in this app only; nothing is deleted on OpenSubtitles.",
}

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def conv(s):
    # i18n uses %s; Foundation uses %@
    return s.replace('%s', '%@')

with open(os.path.join(SRC, 'en.json'), encoding='utf-8') as f:
    en = json.load(f)

count = 0
for name in sorted(os.listdir(SRC)):
    if not name.endswith('.json'):
        continue
    loc = name[:-5]
    with open(os.path.join(SRC, name), encoding='utf-8') as f:
        data = json.load(f)
    lproj_id = LPROJ.get(loc, loc)
    lproj = lproj_id + '.lproj'
    outdir = os.path.join(DST, lproj)
    mac_extra = {}
    mac_file = os.path.join(MAC_L10N, lproj_id + '.json')
    if os.path.exists(mac_file):
        with open(mac_file, encoding='utf-8') as f:
            mac_extra = json.load(f)
    os.makedirs(outdir, exist_ok=True)
    lines = ['/* Generated from app/localization/%s by Scripts/generate-strings.py — do not edit by hand. */' % name, '']
    for key, val in en.items():
        tr = data.get(key) or val
        lines.append('"%s" = "%s";' % (esc(conv(key)), esc(conv(tr))))
    lines.append('')
    lines.append('/* Strings specific to the macOS version */')
    for key, val in EXTRA.items():
        tr = mac_extra.get(key) or data.get(key) or val
        lines.append('"%s" = "%s";' % (esc(key), esc(tr)))
    with open(os.path.join(outdir, 'Localizable.strings'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    count += 1
print('Generated %d .lproj folders in %s' % (count, DST))
