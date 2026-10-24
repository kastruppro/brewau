# brewau — logoregler (kompakt)

## 1. Logoet
- **Idé:** bobler stiger inde i en lukket ramme. Rammen er privilegiegrænsen omkring `_brewau`,
  boblerne er bryggen, der arbejder af sig selv og vokser, mens de stiger.
- **Versioner:** vandret (primær) · stablet · symbol · ordmærke · lille symbol (16–32 px) · app-ikon.
- **Masterfiler:** `final/*.svg` (bygges af `build_logo.py final`). Varianter og PNG'er: `exports/`.
  Web/favicon: `exports/web/`. macOS-ikonstørrelser: `exports/macos/`.

| Fil | Brug |
|---|---|
| `brewau-horizontal.svg` / `-reversed.svg` | Primært logo på lys / mørk baggrund |
| `brewau-stacked.svg` / `-reversed.svg` | Smalle, høje flader |
| `brewau-symbol.svg` / `-reversed.svg` | Symbol fra 32 px og op |
| `brewau-symbol-small.svg` | Symbol under 32 px (tykkere ramme, to bobler) |
| `brewau-wordmark.svg` | Kun hvor symbolet allerede står tæt på |
| `brewau-app-icon.svg` / `-small.svg` | macOS-app-ikon (1024-gitter, 824-flise) / 16–32 px |
| `brewau-favicon-source.svg` | Kilde til favicon og web-ikoner |

## 2. Frirum
Hold et frirum på **1 × den største boble** (44 enheder på 256-gitteret ≈ 21 % af symbolets højde) hele
vejen rundt. Frirummet skalerer med logoet.

## 3. Minimumsstørrelse
| Version | Skærm | Tryk |
|---|---|---|
| Vandret | 120 px bred | 30 mm bred |
| Stablet | 64 px bred | 16 mm bred |
| Symbol | 32 px (under det: `-small`) | 8 mm (under det: `-small`, min. 5 mm) |

## 4. Farver
| Navn | Rolle | HEX | RGB | CMYK (startværdi) | Pantone |
|---|---|---|---|---|---|
| Kedel | Ramme, ordmærke, flise | `#12343B` | 18 52 59 | 69 12 0 77 | skal matches |
| Malt | Bobler (kun accent) | `#F2A33A` | 242 163 58 | 0 33 76 5 | skal matches |
| Skum | Lys flade, omvendt ramme | `#F6F1E7` | 246 241 231 | 0 2 6 4 | papirfarve |

CMYK er en direkte omregning, ikke en trykprofil. Lav en prøve, før der trykkes. Pantone skal matches mod en
fysisk farvebog.

**Kontrast:** Kedel/hvid 13,3:1 · Skum/Kedel 11,8:1 · Malt/Kedel 6,4:1 · **Malt/hvid 2,1:1**. Brug aldrig
Malt til tekst på lys baggrund. I logoet er Malt kun accent inde i en ramme med høj kontrast.

**Godkendte kombinationer:** fuld farve på hvid/Skum · Skum + Malt på Kedel · sort på hvid · hvid på sort
eller foto (rolig flade).

## 5. Typografi
- Ordmærket er konstrueret (stamme 20, skål 52/31 på et 100-enheders x-højde-gitter, w-diagonaler på 75°).
  Det er ikke en font. Skriv det aldrig med tastaturet.
- Brødtekst og UI: systemfonten (SF Pro) via SwiftUI, så logoet ikke skal matche en font-licens.

## 6. Undgå
Stræk eller klem · andre farver end paletten · rotation · skygger, konturer, gradienter · flere eller flyttede
bobler · bobler uden ramme · rammen uden bobler · andre indbyrdes størrelser i lockups · det store symbol under
32 px · travle baggrunde uden flise.

## 7. Overdragelse
- **Test:** `svg_audit` uden advarsler på alle masterfiler (symboler og ikoner 100/100, lockups og ordmærke 98–99,
  kun info-noter; w'ets diagonaler ligger på præcis 75°). Set ved
  16/24/32/64 px, i én farve, omvendt og i mockups (`board/slides/`).
- **Kendt begrænsning:** ravfarvede bobler på hvid er svage ved små størrelser. Derfor ligger favicon og web-ikoner
  på en Kedel-flise, og der er en egen lille version.
- **Åbent:** varemærkesøgning (ikke udført) · Pantone-match · menu bar-skabelonbillede (sort, monokromt, ud fra
  `brewau-symbol-small.svg`) laves sammen med `app/Icon.swift`.
