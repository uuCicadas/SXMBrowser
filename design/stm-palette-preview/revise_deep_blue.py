"""B4: a saturated blue path inspired by Hong 2024 Fig.1c, at B3 lightness."""
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
    previous = json.loads((r.OUT / 'candidate_B3_structure.json').read_text())['palettes'][0]
    t = np.linspace(0, 1, 257)
    target_L = r.rgb_lab(r.sample(previous['stops'], t))[:, 0]
    # Reconstruct the simple black / saturated-blue / white path visible in the
    # published bar, rather than copying quantization noise or recovering a LUT.
    q = np.linspace(0, 1, 16385)
    anchors = np.array([[0, 0, 0], [0, 122, 255], [255, 255, 255]]) / 255
    path_rgb = np.column_stack([np.interp(q, [0, .5, 1], anchors[:, k]) for k in range(3)])
    path_L = r.rgb_lab(path_rgb)[:, 0]
    assert np.all(np.diff(path_L) > 0)
    rgb = np.column_stack([np.interp(target_L, path_L, path_rgb[:, k]) for k in range(3)])
    revised = dict(
        name='paper_deep_blue_v4', label='文献深蓝',
        provenance='Original reconstruction of black / saturated blue / cold-white direction visible in Hong et al., Nature 630 (2024), Fig.1c. Not an author LUT.',
        reference_url='https://www.nature.com/articles/s41586-024-07427-8/figures/1',
        reference_anchors=['#000000', '#007AFF', '#FFFFFF'],
        lightness='Matched to B3 at all 257 palette stops; no change to image scale or processing.',
        stops=[dict(position=float(v), r=float(c[0]), g=float(c[1]), b=float(c[2])) for v, c in zip(t, rgb)])
    (r.OUT / 'candidate_B4_deep_blue.json').write_text(json.dumps(
        dict(schemaVersion=1, palettes=[revised]), ensure_ascii=False, indent=2) + '\n')
    dense = np.linspace(0, 1, 4097)
    dense_rgb = r.sample(revised['stops'], dense)
    L = r.rgb_lab(dense_rgb)[:, 0]
    old_L = r.rgb_lab(r.sample(previous['stops'], dense))[:, 0]
    assert np.all(np.diff(r.linear_rgb(dense_rgb) @ r.RGB_XYZ[1]) > 0)
    assert np.max(np.abs(L - old_L)) < .02
    exported = json.loads((args.matrix_dir / 'matrices.json').read_text())
    validation = json.loads((r.OUT / 'validation.json').read_text())
    selected = [next(x for x in exported if x['key'] == k) for k in ['Au1110164_Z_raw', 'Au1110365_Z_raw']]
    matrices = [np.fromfile(args.matrix_dir / (x['key'] + '.f32'), dtype='<f4').reshape(x['height'], x['width']) for x in selected]
    for item, original in zip(selected, validation['inputs']):
        assert hashlib.sha256(Path(item['path']).read_bytes()).hexdigest() == original['sha256']

    board = Image.new('RGB', (1280, 1170), '#F4F4F1')
    draw = ImageDraw.Draw(board)
    ink, muted = '#22282C', '#62696C'
    draw.text((54, 25), 'B4 · 文献深蓝取向', font=r.font(33), fill=ink)
    draw.text((54, 75), '黑蓝 — 饱和亮蓝 — 冷白；保留 B3 的明暗层次，减少中间调的偏青。', font=r.font(19), fill=muted)
    draw.text((54, 110), '相同数据 / Forward / Raw / Full min–max / 无降噪、锐化或背景校正', font=r.font(17), fill=muted)
    draw.line((54, 145, 1226, 145), fill='#D8DAD7', width=1)
    for col, palette in enumerate([previous, revised]):
        x, size = [54, 666][col], 560
        draw.text((x, 162), ['上一版 B3 · 偏青', 'B4 · 深蓝'][col], font=r.font(23), fill=ink)
        board.paste(strip(r.sample(palette['stops'], np.linspace(0, 1, 280)), 280, 15), (x + 260, 171))
        draw.text((x + 260, 190), '低', font=r.font(13), fill=muted)
        draw.text((x + 525, 190), '高', font=r.font(13), fill=muted)
        for row, (item, matrix, crop) in enumerate(zip(selected, matrices, [(0, 0, 512, 512), (0, 0, 512, 218)])):
            label = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域'][row]
            draw.text((x, [218, 819][row]), label, font=r.font(17), fill=muted)
            pixels = r.colorize(matrix, palette['stops'], item['vmin'], item['vmax'])
            if col == 0:
                old = np.array(Image.open(r.OUT / ('cyan_structure_v3_' + item['key'] + '.png')).convert('RGB'))
                assert np.array_equal(old, pixels)
            else:
                Image.fromarray(pixels).save(r.OUT / ('paper_deep_blue_v4_' + item['key'] + '.png'))
            im = Image.fromarray(pixels).crop(crop)
            height = round(im.height / im.width * size)
            y = [245, 855][row]
            board.paste(im.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
    draw.text((54, 1110), '参考 Hong et al., Nature (2024), Fig. 1c 的色调路径重新设计，并非作者原始色表。', font=r.font(17), fill=muted)
    draw.text((54, 1140), '下图仅显示前 218 条完整扫描线。AFM grey 保持不变；本次仅更新候选预览。', font=r.font(17), fill=muted)
    board.save(r.OUT / 'preview_B4_deep_blue.png')
    native = r.ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    assert hashlib.sha256(native.read_bytes()).hexdigest() == validation['native_palette_catalog_sha256']
    report = dict(status='preview_only_no_app_defaults_changed',
                  floating_point_luminance_strictly_increasing=True,
                  max_L_difference_from_B3=float(np.max(np.abs(L - old_L))),
                  same_raw_data_direction_crop_and_numerical_range=True,
                  prior_B3_pixel_equality=True, input_sha256_verified=True,
                  production_palette_catalog_unchanged=True)
    (r.OUT / 'validation_B4.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
