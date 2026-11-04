"""B3: literature-informed tonal structure, not a reproduction of an author LUT."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

import render_previews as r


def candidate():
    t = np.linspace(0, 1, 257)
    lightness = 3 + 96 * (t - .35 * np.sin(2 * np.pi * t) / (2 * np.pi))
    hue = np.radians(250 - 25 * t)
    chroma = 40 * np.sin(np.pi * t)
    lab = np.column_stack([lightness, chroma * np.cos(hue), chroma * np.sin(hue)])
    low, high = np.zeros(len(t)), np.ones(len(t))
    # Gamut mapping preserves hue and L*: no independent RGB-channel clipping.
    for _ in range(32):
        mid = (low + high) / 2
        probe = lab.copy()
        probe[:, 1:] *= mid[:, None]
        rgb = r.lab_rgb(probe)
        inside = ((rgb >= 0) & (rgb <= 1)).all(axis=1)
        low = np.where(inside, mid, low)
        high = np.where(inside, high, mid)
    lab[:, 1:] *= (low * .98)[:, None]
    rgb = r.lab_rgb(lab)
    assert np.all((rgb >= 0) & (rgb <= 1))
    return dict(
        name='cyan_structure_v3', label='蓝青 · 层次版',
        provenance='Original design informed by visual review of 10 Nature/Science papers; not a recovered or fitted author LUT.',
        lightness_formula='L*(t) = 3 + 96 * (t - 0.35*sin(2*pi*t)/(2*pi))',
        hue_formula='h_ab(t) = 250 - 25*t degrees',
        chroma_formula='C_ab(t) = 40*sin(pi*t), radially reduced to fit sRGB with 2% margin',
        tradeoff='Greater middle-range lightness slope; lower slope at both ends. Display contrast, not increased spatial resolution.',
        stops=[dict(position=float(pos), r=float(c[0]), g=float(c[1]), b=float(c[2]))
               for pos, c in zip(t, rgb)])


def strip(rgb, width, height):
    pixels = np.floor(np.clip(rgb, 0, 1) * 255 + .5).astype(np.uint8)
    return Image.fromarray(np.repeat(pixels[None, ...], height, axis=0)).resize((width, height), Image.Resampling.NEAREST)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('matrix_dir', type=Path)
    parser.add_argument('bar_samples', type=Path)
    args = parser.parse_args()
    previous = json.loads((r.OUT / 'candidate_B2_saturated.json').read_text())['palettes'][0]
    revised = candidate()
    (r.OUT / 'candidate_B3_structure.json').write_text(json.dumps(
        dict(schemaVersion=1, palettes=[revised]), ensure_ascii=False, indent=2) + '\n')
    t = np.linspace(0, 1, 4097)
    new_rgb = r.sample(revised['stops'], t)
    L = r.rgb_lab(new_rgb)[:, 0]
    assert np.all(np.diff(r.linear_rgb(new_rgb) @ r.RGB_XYZ[1]) > 0)
    dense_target = 3 + 96 * (t - .35 * np.sin(2 * np.pi * t) / (2 * np.pi))
    assert np.max(np.abs(L - dense_target)) < .02
    exported = json.loads((args.matrix_dir / 'matrices.json').read_text())
    prior_validation = json.loads((r.OUT / 'validation.json').read_text())
    keys = ['Au1110164_Z_raw', 'Au1110365_Z_raw']
    selected = [next(d for d in exported if d['key'] == key) for key in keys]
    matrices = [np.fromfile(args.matrix_dir / (d['key'] + '.f32'), dtype='<f4').reshape(d['height'], d['width']) for d in selected]
    for d, original in zip(selected, prior_validation['inputs']):
        assert hashlib.sha256(Path(d['path']).read_bytes()).hexdigest() == original['sha256']
    bg, ink, muted = '#F4F4F1', '#22282C', '#62696C'
    board = Image.new('RGB', (1280, 1208), bg)
    draw = ImageDraw.Draw(board)
    draw.text((54, 25), 'B3 · 重排明暗层次', font=r.font(33), fill=ink)
    draw.text((54, 75), '保留蓝青方向：更深的暗端、有色的中间调、干净的近白亮端。', font=r.font(19), fill=muted)
    draw.text((54, 110), '相同数据 / Forward / Raw / Full min–max / 无降噪、锐化或背景校正', font=r.font(17), fill=muted)
    draw.line((54, 145, 1226, 145), fill='#D8DAD7', width=1)
    for col, palette in enumerate([previous, revised]):
        x, size = [54, 666][col], 560
        draw.text((x, 162), ['上一版 B2', 'B3 · 层次版'][col], font=r.font(23), fill=ink)
        board.paste(strip(r.sample(palette['stops'], np.linspace(0, 1, 280)), 280, 15), (x + 260, 171))
        draw.text((x + 260, 190), '低', font=r.font(13), fill=muted)
        draw.text((x + 525, 190), '高', font=r.font(13), fill=muted)
        for row, (d, a, crop) in enumerate(zip(selected, matrices, [(0, 0, 512, 512), (0, 0, 512, 218)])):
            label = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域'][row]
            draw.text((x, [218, 819][row]), label, font=r.font(17), fill=muted)
            pixels = r.colorize(a, palette['stops'], d['vmin'], d['vmax'])
            if col == 0:
                prior = np.array(Image.open(r.OUT / ('slate_teal_v2_' + d['key'] + '.png')).convert('RGB'))
                assert np.array_equal(prior, pixels)
            else:
                Image.fromarray(pixels).save(r.OUT / ('cyan_structure_v3_' + d['key'] + '.png'))
            im = Image.fromarray(pixels).crop(crop)
            height = round(im.height / im.width * size)
            y = [245, 855][row]
            board.paste(im.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
    draw.text((54, 1110), '左右使用相同的数值范围；B3 将更多明度差分配给中间调，两端的细微差异相对减弱。', font=r.font(17), fill=muted)
    draw.text((54, 1140), '下图仅显示前 218 条完整扫描线。AFM 保持 Basic gray；本次仅生成候选，应用默认未改。', font=r.font(17), fill=muted)
    draw.text((54, 1170), '文献用于参考显示策略；B3 为重新设计的色表，未声称复刻任何论文原始 LUT。', font=r.font(16), fill=muted)
    board.save(r.OUT / 'preview_B3_structure.png')

    bars = json.loads(args.bar_samples.read_text())
    (r.OUT / 'published_colorbar_samples.json').write_text(json.dumps(bars, ensure_ascii=False, indent=2) + '\n')
    bar_board = Image.new('RGB', (1280, 820), bg)
    d = ImageDraw.Draw(bar_board)
    d.text((54, 28), '从色条看明暗分配', font=r.font(31), fill=ink)
    d.text((54, 82), '每行：上方为彩色色条，下方为等亮度灰度；横轴均为色条横向位置。', font=r.font(18), fill=muted)
    rows = [(bars[0], 'Ma 2020 · Fig. 1c', 'STM：长暗段，重点展开亮端'),
            (bars[1], 'Ma 2020 · Fig. 1d', 'AFM：暗端更短，层次更均衡'),
            (bars[2], 'Hong 2024 · Fig. 1c', 'AFM：黑—有色中调—冷白')]
    rgb_rows = [(np.array(b['rgb8']) / 255, title, subtitle) for b, title, subtitle in rows]
    rgb_rows += [(r.sample(previous['stops'], np.linspace(0, 1, 601)), 'B2 · 上一版', '均匀明度，亮端转绿黄'),
                 (r.sample(revised['stops'], np.linspace(0, 1, 601)), 'B3 · 新方案', '温和 S 曲线，中段对比更强')]
    for i, (rgb, title, subtitle) in enumerate(rgb_rows):
        y = 148 + 111 * i
        d.text((54, y), title, font=r.font(22), fill=ink)
        d.text((54, y + 37), subtitle, font=r.font(17), fill=muted)
        bar_board.paste(strip(rgb, 660, 29), (566, y))
        luminance = r.linear_rgb(rgb) @ r.RGB_XYZ[1]
        gray = np.where(luminance <= .0031308, 12.92 * luminance,
                        1.055 * np.maximum(luminance, 0) ** (1 / 2.4) - .055)
        bar_board.paste(strip(np.repeat(gray[:, None], 3, axis=1), 660, 22), (566, y + 36))
    d.text((54, 727), '前三行采自出版图中的可见色条，不代表作者原始 LUT、gamma 或未经核实的数据归一化方式。', font=r.font(17), fill=muted)
    d.text((54, 759), 'B3 借鉴层次组织，未照搬长黑色平台；其全程亮度递增，不把一段数据直接压成同一种黑色。', font=r.font(17), fill=muted)
    bar_board.save(r.OUT / 'tonal_strategy_comparison.png')
    native = r.ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    assert hashlib.sha256(native.read_bytes()).hexdigest() == prior_validation['native_palette_catalog_sha256']
    report = dict(status='preview_only_no_app_defaults_changed',
                  gamut='All stops in sRGB; radial chroma reduction at fixed hue and lightness',
                  floating_point_luminance_strictly_increasing=True,
                  lightness_error_max=float(np.max(np.abs(L - dense_target))),
                  endpoint_lightness=[float(L[0]), float(L[-1])],
                  middle_lightness_slope=129.6, old_middle_lightness_slope=90,
                  endpoint_lightness_slope=62.4,
                  same_raw_data_direction_crop_and_numerical_range=True,
                  original_B2_pixel_equality=True, input_sha256_verified=True,
                  production_palette_catalog_unchanged=True,
                  scientific_limit='A nonuniform display mapping changes perceptual weighting. It does not add spatial resolution or remove noise, scan lines, or background slope.')
    (r.OUT / 'validation_B3.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
