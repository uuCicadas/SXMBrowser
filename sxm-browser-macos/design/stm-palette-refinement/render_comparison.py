"""Create a data-rendered comparison and check native parity and OLS residuals."""
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'stm-palette-preview'))
import render_previews as r


def main():
    exported = HERE / 'native-export'
    samples = json.loads((exported / 'matrices.json').read_text())
    before = next(p for p in json.loads((HERE / 'before-palettes.json').read_text())['palettes']
                  if p['name'] == 'blueViolet')
    after = json.loads((HERE / 'after-blue-violet.json').read_text())
    board = Image.new('RGB', (1280, 1170), '#F4F4F1')
    draw = ImageDraw.Draw(board)
    ink, muted = '#22282C', '#62696C'
    draw.text((54, 25), '蓝紫配色 · 暗部与色彩微调', font=r.font(32), fill=ink)
    draw.text((54, 77), '暗部稍亮、低亮度层次拉开；感知色度降低 3%，保留蓝紫色相。', font=r.font(19), fill=muted)
    draw.text((54, 111), '两侧均为 Plane linear fit / Forward / Full min–max；仅配色不同。', font=r.font(17), fill=muted)
    draw.line((54, 149, 1226, 149), fill='#D8DAD7', width=1)
    reports = []
    for col, palette in enumerate([before, after]):
        x, size = [54, 666][col], 560
        draw.text((x, 165), ['修改前 · 蓝紫', '修改后 · 蓝紫'][col], font=r.font(23), fill=ink)
        gradient = r.sample(palette['stops'], np.linspace(0, 1, 280))
        gradient = np.repeat(gradient[None, ...], 16, axis=0)
        board.paste(Image.fromarray(np.floor(gradient * 255 + .5).astype(np.uint8)), (x + 280, 174))
        draw.text((x + 280, 195), '低', font=r.font(13), fill=muted)
        draw.text((x + 546, 195), '高', font=r.font(13), fill=muted)
        for row, sample in enumerate(samples):
            key = sample['key']
            matrix = np.fromfile(exported / (key + '_planeLinear.f32'), dtype='<f4').reshape(sample['height'], sample['width'])
            pixels = r.colorize(matrix, palette['stops'], sample['vmin'], sample['vmax'])
            labels = ['Au1110164 · 50 × 50 nm · Z', 'Au1110365 · 4 × 4 nm 扫描的已采集区域']
            draw.text((x, [228, 832][row]), labels[row], font=r.font(17), fill=muted)
            image = Image.fromarray(pixels)
            image.save(HERE / (key + ['_before.png', '_after.png'][col]))
            crop = [(0, 0, 512, 512), (0, 0, 512, 218)][row]
            image = image.crop(crop)
            height = round(image.height / image.width * size)
            y = [260, 866][row]
            board.paste(image.resize((size, height), Image.Resampling.NEAREST), (x, y))
            draw.rectangle((x - 1, y - 1, x + size, y + height), outline='#DBDDDA', width=1)
            if col == 1:
                native = np.array(Image.open(exported / (key + '_blueViolet.png')).convert('RGB'))
                assert np.array_equal(native, pixels), 'Preview must match production rendering exactly'
                raw = np.fromfile(exported / (key + '_raw.f32'), dtype='<f4').reshape(matrix.shape).astype(np.float64)
                yy, xx = np.indices(raw.shape)
                finite = np.isfinite(raw)
                design = np.column_stack([xx[finite], yy[finite], np.ones(finite.sum())])
                z = raw[finite]
                # Independent SVD least-squares implementation, not normal equations.
                coefficients = np.linalg.lstsq(design, z - z[0], rcond=None)[0]
                reference = (z - z[0]) - design @ coefficients
                error = np.max(np.abs(matrix[finite].astype(np.float64) - reference))
                tolerance = max(np.ptp(reference) * 1e-6, 1e-20)
                assert error < tolerance
                assert np.array_equal(np.isfinite(matrix), finite)
                reports.append(dict(**sample, original_sha256=hashlib.sha256(Path(sample['path']).read_bytes()).hexdigest(),
                                    exact_native_RGB_parity=True, numpy_SVD_max_residual_error_m=float(error),
                                    numpy_SVD_tolerance_m=float(tolerance), preview_crop=crop,
                                    fitted_pixel_slopes_m=coefficients[:2].tolist()))
    draw.text((54, 1120), '真实 SXM 数据渲染；两侧使用同一高度范围。下图仅显示前 218 条完整扫描线。', font=r.font(17), fill=muted)
    draw.text((54, 1148), '暗部亮度最多增加约 2.5 L*；亮度连续递增，无颜色裁切。', font=r.font(16), fill=muted)
    board.save(HERE / 'blue-violet-comparison.png')
    (HERE / 'preview-validation.json').write_text(json.dumps(reports, indent=2) + '\n')
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
