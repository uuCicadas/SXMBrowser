"""B6: turn the independently designed B5 toward violet at equal L* and chroma."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import render_previews as r
from revise_structure import strip


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('matrix_dir', type=Path)
    args = parser.parse_args()
    previous = json.loads((r.OUT / 'candidate_B5_cobalt.json').read_text())['palettes'][0]
    t = np.linspace(0, 1, 257)
    lab = r.rgb_lab(r.sample(previous['stops'], t))
    angle = np.radians(12)
    target = lab.copy()
    target[:, 1] = lab[:, 1] * np.cos(angle) - lab[:, 2] * np.sin(angle)
    target[:, 2] = lab[:, 1] * np.sin(angle) + lab[:, 2] * np.cos(angle)
    rgb = r.lab_rgb(target)
    assert np.all((rgb >= 0) & (rgb <= 1)), 'No clipping or extra desaturation allowed.'
    revised = dict(
        name='blue_violet_v6', label='蓝紫', parent='cobalt_v5',
        provenance='A user-requested hue adjustment to the independently parameterized B5; no paper colorbar used.',
        design=dict(lab_hue_rotation_degrees=12,
                    lightness='Unchanged from B5 at every palette anchor',
                    chroma='Unchanged from B5 at every palette anchor',
                    gamut='Within sRGB without clipping or additional chroma compression'),
        stops=[dict(position=float(v), r=float(c[0]), g=float(c[1]), b=float(c[2])) for v, c in zip(t, rgb)])
    (r.OUT / 'candidate_B6_blue_violet.json').write_text(json.dumps(
        dict(schemaVersion=1, palettes=[revised]), ensure_ascii=False, indent=2) + '\n')
    dense = np.linspace(0, 1, 4097)
    dense_rgb = r.sample(revised['stops'], dense)
    new_lab = r.rgb_lab(dense_rgb)
    old_lab = r.rgb_lab(r.sample(previous['stops'], dense))
    assert np.all(np.diff(r.linear_rgb(dense_rgb) @ r.RGB_XYZ[1]) > 0)
    L_error = float(np.max(np.abs(new_lab[:, 0] - old_lab[:, 0])))
    C_error = float(np.max(np.abs(np.linalg.norm(new_lab[:, 1:], axis=1) - np.linalg.norm(old_lab[:, 1:], axis=1))))
    assert L_error < .02 and C_error < .02
    exported = json.loads((args.matrix_dir / 'matrices.json').read_text())
    baseline = json.loads((r.OUT / 'validation.json').read_text())
    selected = [next(x for x in exported if x['key'] == key) for key in ['Au1110164_Z_raw', 'Au1110365_Z_raw']]
    matrices = [np.fromfile(args.matrix_dir / (x['key'] + '.f32'), dtype='<f4').reshape(x['height'], x['width']) for x in selected]
    for item, original in zip(selected, baseline['inputs']):
        assert hashlib.sha256(Path(item['path']).read_bytes()).hexdigest() == original['sha256']

    board = Image.new('RGB', (1280, 1170), '#F4F4F1')
    draw = ImageDraw.Draw(board)
    ink, muted = '#22282C', '#62696C'
    draw.text((54, 25), 'B6 · 蓝紫', font=r.font(33), fill=ink)
    draw.text((54, 75), '在钴蓝基础上向紫色偏移，保留同样的明暗层次和色彩浓度。', font=r.font(19), fill=muted)
    draw.text((54, 110), '相同数据 / Forward / Raw / Full min–max / 无降噪、锐化或背景校正', font=r.font(17), fill=muted)
    draw.line((54, 145, 1226, 145), fill='#D8DAD7', width=1)
    for col, palette in enumerate([previous, revised]):
        x, size = [54, 666][col], 560
        draw.text((x, 162), ['上一版 B5 · 钴蓝', '调整后 B6 · 蓝紫'][col], font=r.font(23), fill=ink)
        board.paste(strip(r.sample(palette['stops'], np.linspace(0, 1, 280)), 280, 15), (x + 260, 171))
        draw.text((x + 260, 190), '低', font=r.font(13), fill=muted)
        draw.text((x + 525, 190), '高', font=r.font(13), fill=muted)
        for row, (item, matrix, crop) in enumerate(zip(selected, matrices, [(0, 0, 512, 512), (0, 0, 512, 218)])):
            label = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域'][row]
            draw.text((x, [218, 819][row]), label, font=r.font(17), fill=muted)
            pixels = r.colorize(matrix, palette['stops'], item['vmin'], item['vmax'])
            if col == 0:
                old = np.array(Image.open(r.OUT / ('cobalt_v5_' + item['key'] + '.png')).convert('RGB'))
                assert np.array_equal(old, pixels)
            else:
                Image.fromarray(pixels).save(r.OUT / ('blue_violet_v6_' + item['key'] + '.png'))
            im = Image.fromarray(pixels).crop(crop)
            height = round(im.height / im.width * size)
            y = [245, 855][row]
            board.paste(im.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
    draw.text((54, 1110), 'B6 沿用自主方案 B5 的明度与色度，仅调整色相；明暗仍连续递增。', font=r.font(17), fill=muted)
    draw.text((54, 1140), '下图仅显示前 218 条完整扫描线。B4 保留方案不变；AFM grey 不变，应用默认尚未切换。', font=r.font(17), fill=muted)
    board.save(r.OUT / 'preview_B6_blue_violet.png')
    saved = r.OUT / 'saved/B4-deep-blue'
    for name, digest in json.loads((saved / 'manifest.json').read_text())['files_sha256'].items():
        assert hashlib.sha256((saved / name).read_bytes()).hexdigest() == digest
    native = r.ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    assert hashlib.sha256(native.read_bytes()).hexdigest() == baseline['native_palette_catalog_sha256']
    report = dict(status='preview_only_no_app_defaults_changed',
                  lab_hue_rotation_degrees=12,
                  lightness_difference_max=L_error, chroma_difference_max=C_error,
                  floating_point_luminance_strictly_increasing=True,
                  in_srgb_without_clipping_or_desaturation=True,
                  B4_snapshot_hashes_verified=True, prior_B5_pixel_equality=True,
                  input_sha256_verified=True, production_palette_catalog_unchanged=True)
    (r.OUT / 'validation_B6.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
