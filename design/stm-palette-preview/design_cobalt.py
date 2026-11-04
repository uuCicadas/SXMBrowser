"""B5 is generated from independent L/C/h parameters, not sampled paper colors."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import render_previews as r
from revise_structure import strip


def monotone_curve(t, positions, values):
    """Monotone cubic Hermite interpolation for increasing lightness anchors."""
    x, y = np.array(positions, float), np.array(values, float)
    h = np.diff(x)
    slopes = np.diff(y) / h
    m = np.zeros_like(y)
    for i in range(1, len(y) - 1):
        w1, w2 = 2 * h[i] + h[i - 1], h[i] + 2 * h[i - 1]
        m[i] = (w1 + w2) / (w1 / slopes[i - 1] + w2 / slopes[i])
    m[0] = np.clip(((2 * h[0] + h[1]) * slopes[0] - h[0] * slopes[1]) / (h[0] + h[1]), 0, 3 * slopes[0])
    m[-1] = np.clip(((2 * h[-1] + h[-2]) * slopes[-1] - h[-1] * slopes[-2]) / (h[-1] + h[-2]), 0, 3 * slopes[-1])
    i = np.clip(np.searchsorted(x, t, side='right') - 1, 0, len(x) - 2)
    u = (t - x[i]) / h[i]
    return ((2 * u ** 3 - 3 * u ** 2 + 1) * y[i]
            + (u ** 3 - 2 * u ** 2 + u) * h[i] * m[i]
            + (-2 * u ** 3 + 3 * u ** 2) * y[i + 1]
            + (u ** 3 - u ** 2) * h[i] * m[i + 1])


def independent_cobalt():
    # No reference palette or image is an input to this function.
    t = np.linspace(0, 1, 257)
    positions = [0, .18, .45, .7, .9, 1]
    lightness_anchors = [4, 13, 38, 70, 90, 98]
    L = monotone_curve(t, positions, lightness_anchors)
    hue = np.radians(295 - 20 * t * t * (3 - 2 * t))
    chroma = 64 * (t / .6) ** 1.5 * ((1 - t) / .4)
    lab = np.column_stack([L, chroma * np.cos(hue), chroma * np.sin(hue)])
    low, high = np.zeros(len(t)), np.ones(len(t))
    for _ in range(32):
        mid = (low + high) / 2
        probe = lab.copy()
        probe[:, 1:] *= mid[:, None]
        rgb = r.lab_rgb(probe)
        inside = ((rgb >= 0) & (rgb <= 1)).all(axis=1)
        low = np.where(inside, mid, low)
        high = np.where(inside, high, mid)
    lab[:, 1:] *= (low * .94)[:, None]
    rgb = r.lab_rgb(lab)
    assert np.all((rgb >= 0) & (rgb <= 1))
    return dict(
        name='cobalt_v5', label='钴蓝',
        provenance='Independently parameterized design responding to the user preference for deep blue. No paper colorbar or prior palette is used as an input to the palette generator. No claim of worldwide uniqueness.',
        design=dict(lightness_positions=positions, lightness_values=lightness_anchors,
                    lightness_interpolation='Monotone cubic Hermite',
                    hue_formula='h_ab(t) = 295 - 20*t*t*(3-2*t) degrees',
                    chroma_formula='C_ab(t) = 64*(t/0.6)^1.5*((1-t)/0.4)',
                    gamut='Radial chroma reduction at fixed L/h with 6% margin',
                    intent='Darker lower midtones, concentrated cobalt upper midtones, later pale highlights'),
        stops=[dict(position=float(v), r=float(c[0]), g=float(c[1]), b=float(c[2])) for v, c in zip(t, rgb)])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('matrix_dir', type=Path)
    args = parser.parse_args()
    saved = r.OUT / 'saved/B4-deep-blue'
    retained_manifest = json.loads((saved / 'manifest.json').read_text())
    for filename, digest in retained_manifest['files_sha256'].items():
        assert hashlib.sha256((saved / filename).read_bytes()).hexdigest() == digest
    # B4 is loaded only for the comparison panel, after B5's independent generator.
    revised = independent_cobalt()
    previous = json.loads((saved / 'palette.json').read_text())['palettes'][0]
    (r.OUT / 'candidate_B5_cobalt.json').write_text(json.dumps(
        dict(schemaVersion=1, palettes=[revised]), ensure_ascii=False, indent=2) + '\n')
    t = np.linspace(0, 1, 4097)
    rgb = r.sample(revised['stops'], t)
    L = r.rgb_lab(rgb)[:, 0]
    assert np.all(np.diff(r.linear_rgb(rgb) @ r.RGB_XYZ[1]) > 0)
    target = monotone_curve(t, revised['design']['lightness_positions'], revised['design']['lightness_values'])
    assert np.max(np.abs(L - target)) < .02
    exported = json.loads((args.matrix_dir / 'matrices.json').read_text())
    baseline = json.loads((r.OUT / 'validation.json').read_text())
    selected = [next(x for x in exported if x['key'] == key) for key in ['Au1110164_Z_raw', 'Au1110365_Z_raw']]
    matrices = [np.fromfile(args.matrix_dir / (x['key'] + '.f32'), dtype='<f4').reshape(x['height'], x['width']) for x in selected]
    for item, original in zip(selected, baseline['inputs']):
        assert hashlib.sha256(Path(item['path']).read_bytes()).hexdigest() == original['sha256']
    board = Image.new('RGB', (1280, 1204), '#F4F4F1')
    draw = ImageDraw.Draw(board)
    ink, muted = '#22282C', '#62696C'
    draw.text((54, 25), '新方案 B5 · 钴蓝', font=r.font(33), fill=ink)
    draw.text((54, 75), '墨靛暗部 — 钴蓝主体 — 近白高光；低中段更深，浅色高光较晚出现。', font=r.font(19), fill=muted)
    draw.text((54, 110), '相同数据 / Forward / Raw / Full min–max / 无降噪、锐化或背景校正', font=r.font(17), fill=muted)
    draw.line((54, 145, 1226, 145), fill='#D8DAD7', width=1)
    for col, palette in enumerate([previous, revised]):
        x, size = [54, 666][col], 560
        draw.text((x, 162), ['已保留 B4 · 深蓝', '新方案 B5 · 钴蓝'][col], font=r.font(23), fill=ink)
        board.paste(strip(r.sample(palette['stops'], np.linspace(0, 1, 280)), 280, 15), (x + 260, 171))
        draw.text((x + 260, 190), '低', font=r.font(13), fill=muted)
        draw.text((x + 525, 190), '高', font=r.font(13), fill=muted)
        for row, (item, matrix, crop) in enumerate(zip(selected, matrices, [(0, 0, 512, 512), (0, 0, 512, 218)])):
            label = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域'][row]
            draw.text((x, [218, 819][row]), label, font=r.font(17), fill=muted)
            pixels = r.colorize(matrix, palette['stops'], item['vmin'], item['vmax'])
            if col == 0:
                old = np.array(Image.open(r.OUT / ('paper_deep_blue_v4_' + item['key'] + '.png')).convert('RGB'))
                assert np.array_equal(old, pixels)
            else:
                Image.fromarray(pixels).save(r.OUT / ('cobalt_v5_' + item['key'] + '.png'))
            im = Image.fromarray(pixels).crop(crop)
            height = round(im.height / im.width * size)
            y = [245, 855][row]
            board.paste(im.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
    draw.text((54, 1110), 'B5 使用独立定义的明度、色相和色度参数生成，未从论文色条或 B4 色表重采样。', font=r.font(17), fill=muted)
    draw.text((54, 1140), '低中段的细微明暗变化更收敛，中高段更突出；这是显示层次调整，不改变原始数据。', font=r.font(17), fill=muted)
    draw.text((54, 1170), '下图仅显示前 218 条完整扫描线。B4 已保存；AFM grey 保持不变，应用默认尚未切换。', font=r.font(17), fill=muted)
    board.save(r.OUT / 'preview_B5_cobalt.png')
    native = r.ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    assert hashlib.sha256(native.read_bytes()).hexdigest() == baseline['native_palette_catalog_sha256']
    report = dict(status='preview_only_no_app_defaults_changed',
                  B4_snapshot_hashes_verified=True,
                  floating_point_luminance_strictly_increasing=True,
                  lightness_curve_error_max=float(np.max(np.abs(L - target))),
                  generation_uses_reference_palette=False,
                  same_raw_data_direction_crop_and_numerical_range=True,
                  prior_B4_pixel_equality=True, input_sha256_verified=True,
                  production_palette_catalog_unchanged=True)
    (r.OUT / 'validation_B5.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
