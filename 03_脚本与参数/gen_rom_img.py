# -*- coding: utf-8 -*-
"""
把一张 512x512 RGB 图打包成 4 个 ROM 的 hex（ee/eo/oe/oo，各 256x256，RGB565）
用法: python gen_rom_img.py gray|photo <图片路径>
输出: rom_ee.hex rom_eo.hex rom_oe.hex rom_oo.hex + preview_*.png
"""
import sys, os
import numpy as np
from PIL import Image

BASE = r'D:\pango\img_correct\img_correct_backup_vga'
N = 512


def bayer(n):
    m = np.array([[0]])
    while m.shape[0] < n:
        m = np.block([[4 * m, 4 * m + 2], [4 * m + 3, 4 * m + 1]])
    return m


def make_gray():
    """20 级线性灰阶横条，填满 y=0..479（屏上可见区），y>=480 用白"""
    img = np.zeros((N, N, 3), np.uint8)
    levels = 20
    h = 480 // levels          # 24 行/级
    for i in range(levels):
        v = int(round(i * 255.0 / (levels - 1)))
        img[i * h:(i + 1) * h, :, :] = v
    img[levels * h:, :, :] = 255
    return img


def make_photo(path):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    s = min(w, h)
    im = im.crop(((w - s) // 2, (h - s) // 2,
                  (w - s) // 2 + s, (h - s) // 2 + s))
    im = im.resize((N, N), Image.LANCZOS)
    a = np.asarray(im).astype(np.float32)
    # Bayer 8x8 有序抖动，压住 RGB565 的色带
    bs = bayer(8)
    tile = np.tile(bs / 64.0 - 0.5, (N // 8, N // 8))
    a[:, :, 0] += tile * 8.0
    a[:, :, 1] += tile * 4.0
    a[:, :, 2] += tile * 8.0
    return np.clip(a, 0, 255).astype(np.uint8)


def pack(img):
    r = (img[:, :, 0].astype(np.uint16) >> 3) & 0x1F
    g = (img[:, :, 1].astype(np.uint16) >> 2) & 0x3F
    b = (img[:, :, 2].astype(np.uint16) >> 3) & 0x1F
    return (r << 11) | (g << 5) | b


def write_hex(v, tag):
    # ee=(x偶,y偶) oe=(x奇,y偶) eo=(x偶,y奇) oo=(x奇,y奇)
    banks = {'ee': (0, 0), 'oe': (0, 1), 'eo': (1, 0), 'oo': (1, 1)}
    for name, (yc, xc) in banks.items():
        sub = v[yc::2, xc::2].reshape(-1)
        assert sub.size == 65536, (name, sub.size)
        p = os.path.join(BASE, 'rom_%s.hex' % name)
        with open(p, 'w', newline='\n') as f:
            f.write(''.join('%04X\n' % x for x in sub))
        print('  rom_%s.hex  %d 条' % (name, sub.size))


def preview(img, tag):
    """左=原图(线性)，右=gamma 后(取中灰档位示意)"""
    lut = [int(l.strip(), 16) for l in open(os.path.join(BASE, 'gam_lut.hex')) if l.strip()]
    Image.fromarray(img).save(os.path.join(BASE, 'preview_%s.png' % tag))
    # 4 档 gamma 效果拼图
    tiles = [img]
    for k in range(4):
        seg = np.array(lut[k * 256:(k + 1) * 256], np.uint8)
        tiles.append(seg[img])
    out = np.concatenate(tiles, axis=1)
    Image.fromarray(out).save(os.path.join(BASE, 'preview_%s_gamma4.png' % tag))
    print('  preview_%s.png / preview_%s_gamma4.png' % (tag, tag))


def main():
    mode = sys.argv[1]
    if mode == 'gray':
        img = make_gray()
        tag = 'gray'
    else:
        img = make_photo(sys.argv[2])
        tag = 'photo'
    v = pack(img)
    print('[%s] 打包中...' % tag)
    write_hex(v, tag)
    preview(img, tag)
    # 亮度均值（决定自适应选哪一档）
    m = float(img[:, :, 1][:480, :].mean())
    print('  G 通道均值 = %.1f  -> 自适应档位 %s' % (
        m, '0(γ0.55)' if m < 50 else ('1(γ0.78)' if m < 110 else ('2(γ1.00)' if m < 190 else '3(γ1.45)'))))
    print('  DONE')


if __name__ == '__main__':
    main()
