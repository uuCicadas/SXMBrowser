"""Reproduce the modest Blue Violet revision from its immutable before snapshot."""
import hashlib
import json
from pathlib import Path
import struct
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / 'stm-palette-preview'))
import render_previews as r
from design_cobalt import monotone_curve


def main():
    catalog = json.loads((HERE / 'before-palettes.json').read_text())
    blue = next(p for p in catalog['palettes'] if p['name'] == 'blueViolet')
    original = blue['stops']
    t = np.array([s['position'] for s in original])
    lab = r.rgb_lab(r.sample(original, t))
    target = lab.copy()
    # Raise low/mid tones by at most 2.51 L*, keeping the black/white endpoints.
    positions = [0, .18, .45, .7, .9, 1]
    lightness = [4, 14.5, 40.5, 71.5, 90.3, 98]
    target[:, 0] = monotone_curve(t, positions, lightness)
    # A perceptual chroma reduction; hue remains fixed. No RGB clipping.
    target[:, 1:] *= .97
    rgb = r.lab_rgb(target)
    assert np.all((rgb >= 0) & (rgb <= 1))
    blue['stops'] = [dict(position=float(v), r=float(c[0]), g=float(c[1]), b=float(c[2]))
                     for v, c in zip(t, rgb)]

    dense = np.linspace(0, 1, 4097)
    old_lab = r.rgb_lab(r.sample(original, dense))
    new_rgb = r.sample(blue['stops'], dense)
    new_lab = r.rgb_lab(new_rgb)
    assert np.all(np.diff(r.linear_rgb(new_rgb) @ r.RGB_XYZ[1]) > 0)
    chroma_before = np.linalg.norm(old_lab[:, 1:], axis=1)
    chroma_after = np.linalg.norm(new_lab[:, 1:], axis=1)
    colored = chroma_before > 1
    reduction = 100 * (1 - chroma_after[colored] / chroma_before[colored])
    assert np.all((reduction > 2.9) & (reduction < 3.1))
    assert np.max(np.abs(new_lab[[0, -1], 0] - old_lab[[0, -1], 0])) < 1e-6
    assert np.min(new_lab[:, 0] - old_lab[:, 0]) > -1e-6
    fingerprint = hashlib.sha256(b''.join(
        struct.pack('<d', s[k]) for s in blue['stops'] for k in ['position', 'r', 'g', 'b']
    )).hexdigest()
    native = ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    # Do not overwrite concurrent changes to unrelated palettes.
    current = json.loads(native.read_text())
    for entry in current['palettes']:
        if entry['name'] == 'blueViolet':
            entry['stops'] = blue['stops']
    native.write_text(json.dumps(current, indent=2) + '\n')
    (HERE / 'after-blue-violet.json').write_text(json.dumps(blue, indent=2) + '\n')
    report = dict(
        description='Blue Violet: slightly brighter shadows and stronger low-tone separation',
        lightness_positions=positions, lightness_values=lightness,
        perceptual_chroma_multiplier=.97,
        chroma_reduction_percent_range=[float(reduction.min()), float(reduction.max())],
        max_lightness_lift=float(np.max(new_lab[:, 0] - old_lab[:, 0])),
        lightness_endpoints_preserved=True, luminance_strictly_increasing=True,
        in_srgb_without_clipping=True, blue_violet_fingerprint=fingerprint,
        other_palettes_unchanged=all(
            p == next(q for q in catalog['palettes'] if q['name'] == p['name'])
            for p in current['palettes'] if p['name'] != 'blueViolet'
        ),
    )
    assert report['other_palettes_unchanged']
    (HERE / 'palette-validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
