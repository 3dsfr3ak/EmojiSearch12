# EmojiSearch12

Emoji-Suche für die Stock-Tastatur unter **iOS 12** (Jailbreak) – wie ab iOS 14, mit Suchleiste oberhalb der Emojis.

<p align="center"><img src="docs/screenshot.png" width="320" alt="Emoji-Suche nach „katze“ in der Spotlight-Suche unter iOS 12"></p>

- Suchleiste „Emoji suchen“ oben in der Emoji-Tastatur
- Such-Panel mit Ergebnisreihe und Buchstabentasten im Layout der Tastatursprache (QWERTZ, AZERTY, QWERTY, Kyrillisch, Griechisch, Hebräisch, Arabisch …)
- **Offline:** Unicode Emoji 18.0 und CLDR 48.2 Stichwörter, 143 Sprachen
- Sucht in der Sprache der zuletzt benutzten Tastatur, Englisch als Fallback
- Zeigt nur Emojis, die der installierte Emoji-Font darstellen kann, neuere Emojis über [EmojiPort](https://github.com/PoomSmart) eingeschlossen

## Installation
Das `.deb` aus den [Releases](../../releases) per Sileo, Zebra, Cydia, Filza oder `dpkg -i` installieren, dann respringen.

Abhängigkeiten: `mobilesubstrate` (bzw. libhooker/Substitute), `preferenceloader`. Nur rootful.

Getestet auf einem iPhone 5s mit iOS 12.5.8 (libhooker). Das Paket enthält nur `arm64`, daher wird es auf A12-Geräten (iPhone XS/XR) in Apples eigenen Apps vermutlich nicht geladen.

## Bedienung
1. In der Emoji-Tastatur auf „Emoji suchen“ tippen.
2. Suchbegriff eingeben. Groß-/Kleinschreibung und Akzente sind egal („uber“ findet „über“), Wortteile werden gefunden („katze“ findet „Hauskatze“).
3. Auf ein Ergebnis tippen, um es einzufügen. Das Panel bleibt offen.
4. `☺︎` führt zurück zur Emoji-Liste. Bei nicht-lateinischen Sprachen wechselt `ABC`/`🌐` zwischen Sprachlayout und QWERTY.

Hautfarben-Varianten werden nicht gelistet, nur das Basis-Emoji. Emojis aus der Suche landen nicht unter „Häufig benutzt“.

## Einstellungen
Einstellungen → EmojiSearch12:
- **Logging** (Standard: aus): Diagnose-Meldungen in die Systemkonsole (Mac: App „Konsole“, Filter `EmojiSearch12`). Prozesse ohne Sandbox wie der SpringBoard schreiben zusätzlich nach `/var/mobile/Library/Logs/EmojiSearch12.log`. Wirkt ohne Respring.

## Selbst bauen
Benötigt macOS mit den Xcode Command Line Tools und `ldid`. Theos und dpkg sind nicht nötig.

```bash
tools/fetch_deps.sh
```

```bash
CC=/Library/Developer/CommandLineTools/usr/bin/clang ./build.sh
```

`fetch_deps.sh` lädt das iPhoneOS 12.4 SDK ([theos/sdks](https://github.com/theos/sdks)), die CLDR-Annotationen (npm-Pakete `cldr-annotations-full` und `cldr-annotations-derived-full`) und `emoji-test.txt` von unicode.org nach `deps/`. Das `.deb` landet in `build/`.

| Pfad | Inhalt |
|---|---|
| `src/Tweak.m` | Tweak: Hooks, Such-Engine, UI |
| `tools/gen_emoji_data.py` | erzeugt die Such-Daten pro Sprache |
| `tools/mkdeb.py` | baut das `.deb` (dpkg-deb-Ersatz) |
| `tools/make_icon.m` | erzeugt das Einstellungs-Icon |
| `prefs/` | PreferenceLoader-Seite |

## Lizenz
Code: [MIT](LICENSE). Die mitgelieferten Emoji-Daten stammen aus Unicode CLDR und den Unicode Emoji-Daten und stehen unter der [Unicode License v3](LICENSE-Unicode.txt).
