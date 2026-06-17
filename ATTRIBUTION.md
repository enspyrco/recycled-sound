# Third-party asset attribution

## Hearing aid device illustration

`docs/cartoon-mockup/hearing-aid-device.svg` and the rendered
`recycled_sound/assets/capture_guide/hearing_aid_device.png` are derived
from the **Google Noto Emoji** "ear with hearing aid" glyph (U+1F9BB).
The ear was removed to leave the standalone behind-the-ear (BTE) device,
used as the recognizable hearing-aid illustration in the in-app capture
guide.

- Source: https://github.com/googlefonts/noto-emoji
- License: [Creative Commons Attribution 4.0 (CC-BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
- Modifications: ear paths and ear-shading clip groups removed; device
  paths retained unchanged. Original emoji © Google Inc.

## Hearing aid 3D turntable

The turntable frames in `recycled_sound/assets/capture_guide/aid_turntable/`
(`frame_00.png` .. `frame_23.png`) are rendered in Blender from a CC-BY 3D
model, spun 360° about the vertical axis. Used as the real-3D device in the
in-app capture sweep guide (`SweepGuide`).

This work is based on **"Hearing aid / Слуховой аппарат"**
(https://sketchfab.com/3d-models/hearing-aid-454ec7a8a7c74094b2edc206f917e384)
by **Sergey Burov** (https://sketchfab.com/s-burov) licensed under
[CC-BY-4.0](http://creativecommons.org/licenses/by/4.0/).

- Modifications: imported to Blender, lit (three-point + ambient), rendered
  as a 36→24-frame transparent-PNG turntable; frames compressed with
  pngquant. The model geometry/materials are unchanged.
