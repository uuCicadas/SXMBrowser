"""Increase B's chroma while preserving its hue and lightness; render from data."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import render_previews as r


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('matrix_dir', type=Path)
    args = parser.parse_args()
    catalog = json.loads((r.OUT / 'candidate_palettes.json').read_text())
    previous = next(p for p in catalog['palettes'] if p['name'] == 'slate_teal')
    t = np.linspace(0, 1, 257)
    old_lab = r.rgb_lab(r.sample(previous['stops'], t))
    target = old_lab.copy()
    target[:, 1:] *= 1.4
    rgb = r.lab_rgb(target)
    assert np.all((rgb >= 0) & (rgb <= 1)), 'Do not clip: clipping would change lightness and hue.'
    revised = dict(name='slate_teal_v2', label='青墨 · 增色版',
                   parent='slate_teal', lab_chroma_multiplier=1.4,
                   stops=[dict(position=float(pos), r=float(c[0]), g=float(c[1]), b=float(c[2]))
                          for pos, c in zip(t, rgb)])
    dense_rgb = r.sample(revised['stops'], np.linspace(0, 1, 4097))
    dense_lab = r.rgb_lab(dense_rgb)
    assert np.all(np.diff(r.linear_rgb(dense_rgb) @ r.RGB_XYZ[1]) > 0)
    assert np.max(np.abs(dense_lab[:, 0] - np.linspace(7, 97, 4097))) < .01
    (r.OUT / 'candidate_B2_saturated.json').write_text(json.dumps(
        dict(schemaVersion=1, palettes=[revised]), ensure_ascii=False, indent=2) + '\n')

    exported = json.loads((args.matrix_dir / 'matrices.json').read_text())
    keys = ['Au1110164_Z_raw', 'Au1110365_Z_raw']
    selected = [next(d for d in exported if d['key'] == key) for key in keys]
    matrices = [np.fromfile(args.matrix_dir / (d['key'] + '.f32'), dtype='<f4')
                .reshape(d['height'], d['width']) for d in selected]
    crops = [(0, 0, 512, 512), (0, 0, 512, 218)]
    board = Image.new('RGB', (1280, 1150), '#F4F4F1')
    draw = ImageDraw.Draw(board)
    ink, muted = '#22282C', '#62696C'
    draw.text((54, 25), 'B2 · 青墨增色版', font=r.font(33), fill=ink)
    draw.text((54, 75), '蓝青色更鲜明：提高色彩浓度，保持原来的色相与明暗层次。', font=r.font(19), fill=muted)
    draw.text((54, 110), '相同数据 / Forward / Raw / Full min–max / 无降噪或锐化', font=r.font(17), fill=muted)
    draw.line((54, 145, 1226, 145), fill='#D8DAD7', width=1)
    for col, palette in enumerate([previous, revised]):
        x, size = [54, 666][col], 560
        draw.text((x, 162), ['上一版 B', 'B2 · 饱和度提高'][col], font=r.font(23), fill=ink)
        grad = np.repeat(r.sample(palette['stops'], np.linspace(0, 1, 280))[None, ...], 15, axis=0)
        board.paste(Image.fromarray(np.floor(grad * 255 + .5).astype(np.uint8)), (x + 260, 171))
        draw.text((x + 260, 190), '低', font=r.font(13), fill=muted)
        draw.text((x + 525, 190), '高', font=r.font(13), fill=muted)
        for row, (d, a, crop) in enumerate(zip(selected, matrices, crops)):
            label = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域'][row]
            draw.text((x, [218, 819][row]), label, font=r.font(17), fill=muted)
            pixels = r.colorize(a, palette['stops'], d['vmin'], d['vmax'])
            if col == 0:
                prior = Image.open(r.OUT / ('slate_teal_' + d['key'] + '.png')).convert('RGB')
                assert np.array_equal(pixels, np.array(prior)), 'Old B must be identical.'
            else:
                Image.fromarray(pixels).save(r.OUT / ('slate_teal_v2_' + d['key'] + '.png'))
            rendered = Image.fromarray(pixels).crop(crop)
            height = round(rendered.height / rendered.width * size)
            y = [245, 855][row]
            board.paste(rendered.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
    draw.text((54, 1110), 'AFM 保持 Basic gray。下图仅展示前 218 条完整扫描线；左右色阶范围完全一致。', font=r.font(17), fill=muted)
    board.save(r.OUT / 'preview_B2_saturated.png')
    original_report = json.loads((r.OUT / 'validation.json').read_text())
    for d, original in zip(selected, original_report['inputs']):
        assert hashlib.sha256(Path(d['path']).read_bytes()).hexdigest() == original['sha256']
    report = dict(status='preview_only_no_app_defaults_changed', lab_chroma_multiplier=1.4,
                  in_srgb_gamut_without_clipping=True, luminance_strictly_increasing=True,
                  max_L_error=float(np.max(np.abs(dense_lab[:, 0] - np.linspace(7, 97, 4097)))),
                  previous_B_pixels_unchanged=True, raw_input_hashes_verified=True)
    (r.OUT / 'validation_B2.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
