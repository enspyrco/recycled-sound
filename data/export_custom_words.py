#!/usr/bin/env python3
"""Export custom-words list for iOS Vision OCR (VNRecognizeTextRequest).

Apple's Vision framework accepts a customWords array on each recognition
request. The recognizer biases its decoding toward those tokens, so an
OCR pass that would otherwise read "Oricon" as a stand-alone word gets
nudged toward "Oticon" when "Oticon" is in the bias list. This is the
trick that turns native Vision OCR from "okay" to "the actual fix for
the garbled hearing-aid text" — accuracy improvement at decode time,
not via post-hoc fuzzy matching.

Produces:
  recycled_sound/assets/custom_words.json
    {"words": [...]}  // tokens to bias toward

The Swift Vision plugin reads this asset at startup, parses the words
array, and sets it as `customWords` on every VNRecognizeTextRequest.

Note: VNRecognizeTextRequest customWords are tokens, not phrases. A
multi-word model name like "Nera2 Pro" becomes ["Nera2", "Pro"].
"""

import json
import re
from pathlib import Path

DATA_DIR = Path(__file__).parent
ASSETS_DIR = DATA_DIR.parent / "recycled_sound" / "assets"
CATALOG_PATH = ASSETS_DIR / "device_catalog.json"
OUTPUT_PATH = ASSETS_DIR / "custom_words.json"


# Style codes hearing aids are commonly stamped with — these get the
# recognizer to prefer "RIC" over "RIO" or "BIC" on small stamped text.
STYLE_CODES = [
    "BTE", "RIC", "RITE", "ITE", "CIC", "ITC", "IIC",
    "miniRITE", "miniBTE",
]

# Battery-size tokens that often appear stamped near the door.
BATTERY_TOKENS = [
    "10", "13", "312", "675",
    "PR41", "PR48", "PR70",  # IEC battery codes
    "Li-ion", "Rechargeable",
]

# Product-line model names for each brand. Many of these aren't in our
# 345-device register (which is the Recycled Sound holdings list) but
# DO appear stamped on real-world hearing aids Seray receives. Catching
# them at the OCR-bias layer means we recognise the brand+model from
# a clean read, even before the catalog has the specific device.
#
# *** MIRROR of brand_matcher.dart::modelPatterns ***
# Keep in sync with the Dart constant. Captured 2026-05-12 from
# recycled_sound/lib/features/scanner/data/brand_matcher.dart:228+.
# A future refactor should canonicalize this into a single JSON asset
# read by both the Dart matcher and this Python exporter (task captured).
MODEL_PATTERNS: dict[str, list[str]] = {
    "oticon": [
        "Real", "More", "Intent", "Zircon", "Zeal", "Xceed", "Play", "Own",
        "Opn", "Siya", "Ruby", "Ria",
        "Nera", "Alta", "Agil", "Acto", "Ino", "Dynamo", "Sensei", "Safari",
        "Chili", "Sumo",
    ],
    "phonak": [
        "Audeo", "Audéo", "Naida", "Naída", "Virto", "Infinio", "Sphere",
        "Lumity", "Slim", "Terra",
        "Paradise", "Marvel", "Belong", "Venture", "Bolero", "Sky",
        "Ambra", "Solana", "Cassia", "Dalia", "Baseo", "Exelia",
        "Cerena", "Nathos", "Quest", "Lyric", "Brio", "Cros",
    ],
    "signia": [
        "Pure", "Styletto", "Silk", "Motion", "Insio", "Active",
        "Intuis", "Prompt",
        "Cellion", "Carat", "Orion",
    ],
    "widex": [
        "Moment", "Allure", "Smartric", "Magnify",
        "Evoke", "Beyond", "Unique",
        "Dream", "Super", "Clear",
    ],
    "resound": [
        "Nexia", "Vivia", "Savi", "Omnia", "One", "Key",
        "Linx", "Enzo", "Quattro",
        "Verso", "Enya", "Alera",
    ],
    "starkey": [
        "Genesis", "Omega", "Edge", "Signature", "Evolv",
        "Livio", "Muse", "Halo",
        "Picasso",
    ],
    "unitron": [
        "Vivante", "Smile", "Moxi", "Stride", "Insera", "Blu",
        "Discover", "Tempus",
    ],
    "bernafon": [
        "Encanta", "Alpha", "Viron", "Zerena", "Leox",
        "Juna", "Nevara", "Carista",
    ],
    "beltone": [
        "Envision", "Serene", "Commence", "Achieve", "Imagine",
        "Amaze", "Rely",
        "Boost",
        "Trust", "Legend", "First",
    ],
    "sonic": [
        "Captivate", "Enchant", "Celebrate", "Cheer", "Bliss",
        "Charm", "Radiance",
    ],
}


def tokenize(s: str) -> list[str]:
    """Split a product name into individual word tokens.

    Splits on whitespace and standard delimiters, drops empty fragments,
    keeps alphanumeric+hyphen tokens. Preserves original casing — Vision
    customWords is case-insensitive in matching but case-preserving in
    output, so canonical capitalization helps the user-visible result.
    """
    parts = re.split(r"[\s/\\,()\[\]]+", s.strip())
    return [p for p in parts if p and re.match(r"^[\w\-]+$", p)]


def main() -> None:
    print(f"Loading catalog from {CATALOG_PATH}")
    with open(CATALOG_PATH) as f:
        catalog = json.load(f)

    devices = catalog["devices"]
    print(f"  {len(devices)} devices in catalog")

    # Use a set to dedup while collecting. Final sort gives stable output.
    words: set[str] = set()

    # Brand names — strongest signal. Also the canonical correction for
    # the "uoO/Oricon" misreads observed during 2026-05-07 profiling.
    for d in devices.values():
        if (m := d.get("manufacturer")):
            for tok in tokenize(m):
                words.add(tok)

    # Model strings (the model field, e.g. "miniRITE T")
    for d in devices.values():
        if (m := d.get("model")):
            for tok in tokenize(m):
                if len(tok) >= 2:  # Drop single-char model tokens
                    words.add(tok)

    # Full product names (e.g. "Signia Intuis M 4") — captures terms
    # that appear in the marketing name but not the bare model field
    for d in devices.values():
        if (n := d.get("name")):
            for tok in tokenize(n):
                if len(tok) >= 2:
                    words.add(tok)

    # Style codes and battery tokens — domain bias the recognizer
    # toward the small stamped abbreviations that appear on the device
    # body near the battery door.
    words.update(STYLE_CODES)
    words.update(BATTERY_TOKENS)

    # Brand product-line model names. Many aren't in our register but
    # appear stamped on real-world devices. Also adds the brand name as
    # the canonical capitalisation in case the catalog had it different.
    for brand, models in MODEL_PATTERNS.items():
        words.add(brand.capitalize())
        words.update(models)

    sorted_words = sorted(words, key=lambda w: (w.lower(), w))
    print(f"  {len(sorted_words)} unique tokens")

    output = {
        "version": 1,
        "source": "device_catalog.json + STYLE_CODES + BATTERY_TOKENS",
        "wordCount": len(sorted_words),
        "words": sorted_words,
    }

    OUTPUT_PATH.write_text(json.dumps(output, indent=2, ensure_ascii=False))
    print(f"Wrote {OUTPUT_PATH}")

    # Print a sample so the human can sanity-check
    print("\nSample tokens (first 30):")
    for w in sorted_words[:30]:
        print(f"  {w}")


if __name__ == "__main__":
    main()
