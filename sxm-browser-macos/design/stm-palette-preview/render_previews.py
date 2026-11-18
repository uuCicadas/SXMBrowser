"""Render candidate LUTs against native-exported matrices; do not change app defaults."""
from pathlib import Path
import argparse
import hashlib
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
RGB_XYZ = np.array([[.4124564, .3575761, .1804375],
                    [.2126729, .7151522, .0721750],
                    [.0193339, .1191920, .9503041]])
WHITE = np.array([.95047, 1., 1.08883])


def linear_rgb(rgb):
    return np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)


def rgb_lab(rgb):
    xyz = linear_rgb(rgb) @ RGB_XYZ.T / WHITE
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], axis=-1)


def lab_rgb(lab):
    fy = (lab[..., 0] + 16) / 116
    f = np.stack([fy + lab[..., 1] / 500, fy, fy - lab[..., 2] / 200], axis=-1)
    xyz = np.where(f > 6 / 29, f ** 3, 3 * (6 / 29) ** 2 * (f - 4 / 29)) * WHITE
    rgb = xyz @ np.linalg.inv(RGB_XYZ).T
    return np.where(rgb <= .0031308, rgb * 12.92, 1.055 * np.maximum(rgb, 0) ** (1 / 2.4) - .055)


def make_palette(name, label, colors):
    anchors = np.array([[int(c[i:i + 2], 16) / 255 for i in (1, 3, 5)] for c in colors])
    lab = rgb_lab(anchors)
    positions = (lab[:, 0] - lab[0, 0]) / (lab[-1, 0] - lab[0, 0])
    t = np.linspace(0, 1, 257)
    # Both candidates have the same near-uniform L* span; hue is the comparison.
    target = np.column_stack([7 + 90 * t,
                              np.interp(t, positions, lab[:, 1]),
                              np.interp(t, positions, lab[:, 2])])
    rgb = lab_rgb(target)
    for _ in range(100):
        bad = (rgb.min(axis=1) < 0) | (rgb.max(axis=1) > 1)
        if not bad.any():
            break
        target[bad, 1:] *= .97
        rgb = lab_rgb(target)
    assert np.all((rgb >= 0) & (rgb <= 1))
    stops = [dict(position=float(pos), r=float(c[0]), g=float(c[1]), b=float(c[2]))
             for pos, c in zip(t, rgb)]
    return dict(name=name, label=label, design_anchors=colors, stops=stops)


def sample(stops, t):
    positions = [s['position'] for s in stops]
    return np.stack([np.interp(t, positions, [s[k] for s in stops]) for k in 'rgb'], axis=-1)


def colorize(a, stops, lo, hi):
    t = np.where(np.isfinite(a), (a.astype(np.float64) - lo) / (hi - lo), 0)
    rgb = sample(stops, np.clip(t, 0, 1))
    return np.floor(rgb * 255 + .5).astype(np.uint8)


def font(size):
    return ImageFont.truetype('/System/Library/Fonts/Hiragino Sans GB.ttc', size)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('matrix_dir', type=Path)
    args = parser.parse_args()
    native_catalog_path = ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    native_catalog = json.loads(native_catalog_path.read_text())
    original = {p['name']: p for p in native_catalog['palettes']}
    candidates = [
        make_palette('paper_gold', '文献棕金', ['#100F0D', '#341312', '#65241B', '#916A24', '#C7B264', '#FBFAE9']),
        make_palette('slate_teal', '青墨', ['#101921', '#294D62', '#497984', '#86AAA5', '#C0D2BD', '#F7F4E6'])
    ]
    (OUT / 'candidate_palettes.json').write_text(json.dumps(dict(schemaVersion=1, palettes=candidates), ensure_ascii=False, indent=2) + '\n')
    exported = json.loads((args.matrix_dir / 'matrices.json').read_text())
    selected = [next(d for d in exported if d['key'] == key)
                for key in ['Au1110164_Z_raw', 'Au1110365_Z_raw']]
    matrices = [np.fromfile(args.matrix_dir / (d['key'] + '.f32'), dtype='<f4').reshape(d['height'], d['width']) for d in selected]
    # Verify parity with the production renderer, including image orientation.
    for d, a in zip(selected, matrices):
        for name in ['gray', 'flame']:
            expected = np.array(Image.open(args.matrix_dir / (d['key'] + '_' + name + '.png')).convert('RGB'))
            rendered = colorize(a, original[name]['stops'], d['vmin'], d['vmax'])
            assert np.array_equal(expected, rendered), f'Native renderer parity failed: {d["key"]}/{name}'
    checks = {}
    for p in candidates:
        rgb = sample(p['stops'], np.linspace(0, 1, 4097))
        luminance = linear_rgb(rgb) @ RGB_XYZ[1]
        lightness = rgb_lab(rgb)[:, 0]
        assert np.all(np.diff(luminance) > 0), p['name']
        checks[p['name']] = dict(luminance_strictly_increasing=True,
                                  L_min=float(lightness.min()), L_max=float(lightness.max()),
                                  L_linear_max_error=float(np.abs(lightness - np.linspace(7, 97, 4097)).max()))
    old_l = rgb_lab(sample(original['flame']['stops'], np.array([.337254, .666666])))[:, 0]
    checks['flame_reversal_L'] = old_l.tolist()
    crops = [(0, 0, 512, 512), (0, 0, 512, 218)]
    bg, ink, muted = '#F4F4F1', '#22282C', '#62696C'
    xs, size = [54, 666], 560
    for idx, p in enumerate(candidates):
        board = Image.new('RGB', (1280, 1150), bg)
        draw = ImageDraw.Draw(board)
        title = ['A · 文献棕金', 'B · 青墨'][idx]
        description = ['参考 Guo et al., Nature Materials (2014), Fig. 4；重建色阶，并非作者原始 LUT。',
                       '自主设计：低饱和蓝青色，连续增加亮度，用于日常 STM 结构观察。'][idx]
        draw.text((54, 25), title, font=font(33), fill=ink)
        draw.text((54, 75), description, font=font(19), fill=muted)
        draw.text((54, 110), '相同数据 / Forward / Raw / Full min–max / 无降噪或锐化', font=font(17), fill=muted)
        draw.line((54, 145, 1226, 145), fill='#D8DAD7', width=1)
        for col, palette in enumerate([original['flame'], p]):
            x = xs[col]
            draw.text((x, 162), ['现有 Flame', '候选 · ' + p['label']][col], font=font(23), fill=ink)
            grad = np.repeat(sample(palette['stops'], np.linspace(0, 1, 280))[None, ...], 15, axis=0)
            board.paste(Image.fromarray(np.floor(grad * 255 + .5).astype(np.uint8)), (x + 260, 171))
            draw.text((x + 260, 190), '低', font=font(13), fill=muted)
            draw.text((x + 525, 190), '高', font=font(13), fill=muted)
            for row, (d, a, crop) in enumerate(zip(selected, matrices, crops)):
                y = [245, 855][row]
                label_y = [218, 819][row]
                labels = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域']
                draw.text((x, label_y), labels[row], font=font(17), fill=muted)
                rgb = colorize(a, palette['stops'], d['vmin'], d['vmax'])
                rendered = Image.fromarray(rgb).crop(crop)
                height = round(rendered.height / rendered.width * size)
                # Nearest-neighbour display resizing avoids creating interpolated data detail.
                board.paste(rendered.resize((size, height), Image.Resampling.NEAREST), (x, y))
                draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
                if col == 1:
                    Image.fromarray(rgb).save(OUT / (p['name'] + '_' + d['key'] + '.png'))
        draw.text((54, 1110), 'AFM 保持 Basic gray。下图仅展示前 218 条完整扫描线；A/B 色阶范围完全一致。', font=font(17), fill=muted)
        board.save(OUT / ('preview_A_paper_gold.png' if idx == 0 else 'preview_B_slate_teal.png'))
    source_info = []
    for d, crop in zip(selected, crops):
        source_info.append(dict(**d, sha256=hashlib.sha256(Path(d['path']).read_bytes()).hexdigest(), preview_crop=crop))
    report = dict(
        status='preview_only_no_app_defaults_changed',
        native_renderer_parity='Exact RGB equality for both samples in gray and flame',
        native_palette_catalog_sha256=hashlib.sha256(native_catalog_path.read_bytes()).hexdigest(),
        afm_gray_stops=original['gray']['stops'],
        checks=checks, inputs=source_info,
        literature=[
            dict(reference='Guo et al., Nature Materials 13, 184–189 (2014)', figure='4',
                 url='https://www.phy.pku.edu.cn/xzli/articles/Nature_Materials_13_2_184-189_2014.pdf',
                 use='Warm dark-brown/gold/ivory style reference; LUT independently reconstructed and lightness regularized'),
            dict(reference='Peng et al., Nature Communications 9, 122 (2018)', figure='1',
                 url='https://www.nature.com/articles/s41467-017-02635-5', use='Additional visual reference reviewed'),
            dict(reference='Tian et al., Nature Communications 15, 7834 (2024)', figure='1',
                 url='https://www.nature.com/articles/s41467-024-52131-w', use='Additional visual reference reviewed')])
    (OUT / 'validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(checks, ensure_ascii=False, indent=2))
    print('Native renderer parity passed. Two candidate boards saved to', OUT)


if __name__ == '__main__':
    main()
