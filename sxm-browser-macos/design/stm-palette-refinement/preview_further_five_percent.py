"""Preview one extra 5% step from build 81 without changing the app palette."""
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = HERE / 'further-five-percent'
sys.path.insert(0, str(HERE.parent / 'stm-palette-preview'))
import render_previews as r


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(exist_ok=True)
    native_path = ROOT / 'native/SXMBrowserNative/Sources/SXMBrowserCore/Resources/palettes.json'
    installed_path = Path('/Applications/SXM Browser.app/Contents/MacOS/SXMBrowserNative')
    protected = {p: digest(p) for p in [native_path, installed_path]}
    current = json.loads((HERE / 'after-blue-violet.json').read_text())
    catalog = json.loads(native_path.read_text())
    assert current == next(p for p in catalog['palettes'] if p['name'] == 'blueViolet')
    t = np.array([s['position'] for s in current['stops']])
    lab = r.rgb_lab(r.sample(current['stops'], t))
    adjusted = lab.copy()
    # +5% contrast relative to the black endpoint in the lower 45% of the LUT.
    # Fade the lift smoothly toward white to avoid clipping the highlights.
    u = np.clip((t - .45) / .55, 0, 1)
    weight = 1 - u * u * (3 - 2 * u)
    adjusted[:, 0] += .05 * (lab[:, 0] - lab[0, 0]) * weight
    adjusted[:, 1:] *= .95
    rgb = r.lab_rgb(adjusted)
    assert np.all((rgb >= 0) & (rgb <= 1)), 'Do not clip out-of-gamut colors'
    candidate = dict(name='blueViolet', stops=[
        dict(position=float(v), r=float(c[0]), g=float(c[1]), b=float(c[2]))
        for v, c in zip(t, rgb)])
    (OUT / 'candidate-blue-violet.json').write_text(json.dumps(candidate, indent=2) + '\n')
    dense = np.linspace(0, 1, 4097)
    dense_rgb = r.sample(candidate['stops'], dense)
    old_lab = r.rgb_lab(r.sample(current['stops'], dense))
    new_lab = r.rgb_lab(dense_rgb)
    assert np.all(np.diff(r.linear_rgb(dense_rgb) @ r.RGB_XYZ[1]) > 0)
    assert np.max(np.abs(new_lab[[0, -1], 0] - old_lab[[0, -1], 0])) < 1e-6
    old_chroma = np.linalg.norm(old_lab[:, 1:], axis=1)
    new_chroma = np.linalg.norm(new_lab[:, 1:], axis=1)
    colored = old_chroma > 1
    reduction = 100 * (1 - new_chroma[colored] / old_chroma[colored])
    assert np.all((reduction > 4.9) & (reduction < 5.1))

    samples = json.loads((HERE / 'native-export/matrices.json').read_text())
    previous_report = json.loads((HERE / 'preview-validation.json').read_text())
    for sample, report in zip(samples, previous_report):
        assert sample['key'] == report['key']
        assert digest(Path(sample['path'])) == report['original_sha256']
    board = Image.new('RGB', (1280, 1170), '#F4F4F1')
    draw = ImageDraw.Draw(board)
    ink, muted = '#22282C', '#62696C'
    draw.text((54, 25), '蓝紫配色 · 在当前版本上再调 5%', font=r.font(32), fill=ink)
    draw.text((54, 77), '暗部明暗层次再增强 5%；感知色度再降低 5%，高光平滑衔接。', font=r.font(19), fill=muted)
    draw.text((54, 111), '相同数据 / Plane linear fit / Forward / Full min–max；仅配色不同。', font=r.font(17), fill=muted)
    draw.line((54, 149, 1226, 149), fill='#D8DAD7', width=1)
    for col, palette in enumerate([current, candidate]):
        x, size = [54, 666][col], 560
        draw.text((x, 165), ['当前版本 · Build 81', '再调整 5% · 预览'][col], font=r.font(23), fill=ink)
        gradient = r.sample(palette['stops'], np.linspace(0, 1, 280))
        board.paste(Image.fromarray(np.floor(np.repeat(gradient[None, ...], 16, axis=0) * 255 + .5).astype(np.uint8)), (x + 280, 174))
        draw.text((x + 280, 195), '低', font=r.font(13), fill=muted)
        draw.text((x + 546, 195), '高', font=r.font(13), fill=muted)
        for row, sample in enumerate(samples):
            key = sample['key']
            matrix = np.fromfile(HERE / 'native-export' / (key + '_planeLinear.f32'), dtype='<f4').reshape(sample['height'], sample['width'])
            pixels = r.colorize(matrix, palette['stops'], sample['vmin'], sample['vmax'])
            if col == 0:
                native = np.array(Image.open(HERE / 'native-export' / (key + '_blueViolet.png')).convert('RGB'))
                assert np.array_equal(native, pixels)
            image = Image.fromarray(pixels)
            image.save(OUT / (key + ['_current.png', '_candidate.png'][col]))
            labels = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域']
            draw.text((x, [228, 832][row]), labels[row], font=r.font(17), fill=muted)
            image = image.crop([(0, 0, 512, 512), (0, 0, 512, 218)][row])
            height = round(image.height / image.width * size)
            y = [260, 866][row]
            board.paste(image.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
    draw.text((54, 1120), '真实 SXM 数据渲染；两侧高度范围一致。下图仅显示前 218 条完整扫描线。', font=r.font(17), fill=muted)
    draw.text((54, 1148), '仅预览，当前应用配色保留。亮度连续递增，无颜色裁切；黑白亮度端点保持不变。', font=r.font(16), fill=muted)
    board.save(OUT / 'comparison.png')
    assert all(digest(p) == value for p, value in protected.items())
    report = dict(preview_only=True, base='Build 81 Blue Violet',
                  shadow_contrast_multiplier=1.05, chroma_multiplier=.95,
                  chroma_reduction_percent_range=[float(reduction.min()), float(reduction.max())],
                  max_additional_lightness=float((new_lab[:, 0] - old_lab[:, 0]).max()),
                  monotonic_luminance=True, within_srgb_without_clipping=True,
                  endpoints_preserved=True, source_hashes_verified=True,
                  current_preview_matches_native_RGB=True,
                  app_and_production_palette_unchanged=True)
    (OUT / 'validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
