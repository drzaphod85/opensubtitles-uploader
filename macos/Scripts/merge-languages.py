#!/usr/bin/env python3
"""Merges the full OpenSubtitles language list (GetSubLanguages, cached in
opensubtitles-languages.json) into app/js/utils/os-lang.json, keeping the
existing entries and adding native names / ISO 639-1 codes where known.
Then copies the result into the macOS resources.
"""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
OSLANG = os.path.join(ROOT, 'app', 'js', 'utils', 'os-lang.json')
DST = os.path.join(HERE, '..', 'Sources', 'OpenSubtitlesUploader', 'Resources', 'os-lang.json')

# native name and real ISO 639-1 code (None when the language has no ISO 639-1 code)
EXTRA = {
    'abk': ('Аҧсуа', 'ab'), 'amh': ('አማርኛ', 'am'), 'arg': ('Aragonés', 'an'), 'asm': ('অসমীয়া', 'as'),
    'ast': ('Asturianu', None), 'aze': ('Azərbaycan dili', 'az'), 'zhc': ('粵語', None), 'chv': ('Чӑвашла', 'cv'),
    'prs': ('دری', None), 'ext': ('Estremeñu', None), 'gla': ('Gàidhlig', 'gd'), 'ibo': ('Igbo', 'ig'),
    'ina': ('Interlingua', 'ia'), 'gle': ('Gaeilge', 'ga'), 'jpe': ('日本語 (bilingual)', None), 'kan': ('ಕನ್ನಡ', 'kn'),
    'kur': ('Kurdî', 'ku'), 'kir': ('Кыргызча', 'ky'), 'lao': ('ລາວ', 'lo'), 'mar': ('मराठी', 'mr'),
    'nav': ('Diné bizaad', 'nv'), 'nep': ('नेपाली', 'ne'), 'sme': ('Davvisámegiella', 'se'), 'ori': ('ଓଡ଼ିଆ', 'or'),
    'pom': ('Português (Moçambique)', None), 'pus': ('پښتو', 'ps'), 'rki': ('ရခိုင်', None), 'sat': ('ᱥᱟᱱᱛᱟᱲᱤ', None),
    'snd': ('سنڌي', 'sd'), 'som': ('Soomaali', 'so'), 'wen': ('Serbsce', None), 'azb': ('تۆرکجه', None),
    'spn': ('Español (España)', None), 'spl': ('Español (Latinoamérica)', None), 'zgh': ('ⵜⴰⵎⴰⵣⵉⵖⵜ', None),
    'tat': ('Татарча', 'tt'), 'tet': ('Tetun', None), 'tok': ('toki pona', None), 'tuk': ('Türkmençe', 'tk'),
    'uzb': ('Oʻzbek', 'uz'), 'wel': ('Cymraeg', 'cy'), 'zul': ('isiZulu', 'zu'),
}

with open(OSLANG, encoding='utf-8') as f:
    local = json.load(f)
with open(os.path.join(HERE, 'opensubtitles-languages.json'), encoding='utf-8') as f:
    api = json.load(f)

codes = {v['code'] for v in local.values()}
added = 0
for row in api:
    code = row['SubLanguageID']
    if code in codes:
        continue
    native, iso = EXTRA.get(code, (None, None))
    entry = {'code': code}
    if native:
        entry['native'] = native
    if iso:
        entry['iso6391'] = iso
    local[row['LanguageName']] = entry
    added += 1

ordered = {k: local[k] for k in sorted(local, key=str.casefold)}
for path in (OSLANG, DST):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(ordered, f, ensure_ascii=False, indent=4)
        f.write('\n')
print('added %d languages, total %d' % (added, len(ordered)))
