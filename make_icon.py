#!/usr/bin/env python3
# Иконка приложения «Проектор» в стиле macOS Big Sur+.
#
# Рисуем в суперсэмплинге и уменьшаем: так край сквиркла и мелкие детали
# остаются гладкими на всех размерах, вплоть до 16×16 в Dock.
#
# Что на иконке: экран с кнопкой воспроизведения и луч от проектора снизу —
# сразу читается и как «экран», и как «проектор».
#
# Запуск: python3 make_icon.py   (нужен Pillow и numpy)

import os
import subprocess

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 3                       # суперсэмплинг
S = SIZE * SS
BOX = 824 / SIZE             # сквиркл занимает 824 из 1024, как у системных иконок
N = 5.0                      # показатель суперэллипса

# --- палитра
BG_TOP = (40, 58, 108)
BG_BOTTOM = (13, 18, 36)
GLOW = (16, 104, 224)
SCREEN_TOP = (255, 255, 255)
SCREEN_BOTTOM = (224, 237, 255)
ACCENT = (10, 132, 255)
BEAM = (118, 178, 255)
BODY_TOP = (166, 180, 209)
BODY_BOTTOM = (86, 99, 130)


def box_xy(u, v):
    """Координаты внутри сквиркла (0..1) -> пиксели холста."""
    margin = (S - S * BOX) / 2
    span = S * BOX
    return margin + u * span, margin + v * span


def squircle(size, scale=1.0, soft=1.6):
    """Маска суперэллипса с мягким краем шириной около soft пикселя."""
    coord = np.arange(size, dtype=np.float32) + 0.5
    center = size / 2
    half = size * BOX * scale / 2
    nx = (coord - center) / half
    d = np.abs(nx[None, :]) ** N + np.abs(nx[:, None]) ** N
    eps = soft * N / half
    return np.clip((1.0 - d) / eps, 0.0, 1.0)


def vgrad(size, top, bottom, skew=0.0):
    """Вертикальный градиент с диагональным наклоном skew."""
    small = 256
    t = np.linspace(0, 1, small, dtype=np.float32)[:, None]
    x = np.linspace(0, 1, small, dtype=np.float32)[None, :]
    t = np.clip(t * (1 - skew) + x * skew, 0, 1)[..., None]
    arr = (np.array(top, np.float32) * (1 - t)
           + np.array(bottom, np.float32) * t).astype(np.uint8)
    return Image.fromarray(arr, "RGB").resize((size, size), Image.Resampling.BICUBIC)


def radial(size, alpha, radius=0.55):
    """Мягкое круглое свечение по центру."""
    small = 256
    c = (small - 1) / 2
    y, x = np.mgrid[0:small, 0:small].astype(np.float32)
    r = np.sqrt((x - c) ** 2 + (y - c) ** 2) / (small * radius / 2)
    a = np.clip(1 - r, 0, 1) ** 2 * alpha
    return Image.fromarray((a * 255).astype(np.uint8), "L").resize(
        (size, size), Image.Resampling.BICUBIC)


def vramp(size, v0, a0, v1, a1):
    """Одномерный градиент прозрачности по вертикали между двумя точками."""
    ys = np.arange(size, dtype=np.float32)[:, None] / size
    t = np.clip((ys - v0) / max(v1 - v0, 1e-6), 0, 1)
    a = (a0 + (a1 - a0) * t) * 255
    return np.repeat(a.astype(np.uint8), size, axis=1)


def build():
    # ------------------------------------------------ фон
    base = vgrad(S, BG_TOP, BG_BOTTOM, skew=0.35).convert("RGBA")

    glow_mask = radial(S, 0.5)
    glow = Image.new("RGBA", (S, S), GLOW + (255,))
    glow.putalpha(glow_mask)
    base = Image.alpha_composite(base, glow)

    # ------------------------------------------------ луч (аддитивно, за экраном)
    # Композиция симметричная: экран сверху, проектор по центру снизу, конус света
    # между ними. Так силуэт читается как «проектор», а не как случайное пятно.
    apex_x, apex_y = box_xy(0.500, 0.665)
    left_x, left_y = box_xy(0.228, 0.455)
    right_x, right_y = box_xy(0.772, 0.455)

    beam_alpha = Image.new("L", (S, S), 0)
    ImageDraw.Draw(beam_alpha).polygon(
        [(apex_x, apex_y), (right_x, right_y), (left_x, left_y)], fill=255)
    # У линзы ярче, к экрану слабее — как настоящий световой конус.
    ramp = vramp(S, 0.455, 0.10, 0.665, 0.62)
    beam_alpha = Image.fromarray(
        (np.asarray(beam_alpha, np.uint16) * np.asarray(ramp, np.uint16) // 255).astype(np.uint8))
    beam_alpha = beam_alpha.filter(ImageFilter.GaussianBlur(S * 0.010))

    beam = Image.new("RGB", (S, S), (0, 0, 0))
    beam.paste(Image.new("RGB", (S, S), BEAM), (0, 0), beam_alpha)
    base = Image.merge("RGBA", (*ImageChops.add(base.convert("RGB"), beam).split(),
                                base.split()[3]))

    # ------------------------------------------------ экран
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sx0, sy0 = box_xy(0.140, 0.080)
    sx1, sy1 = box_xy(0.860, 0.452)
    radius = (sx1 - sx0) * 0.082

    screen_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(screen_mask).rounded_rectangle(
        [sx0, sy0, sx1, sy1], radius=radius, fill=255)

    screen = vgrad(S, SCREEN_TOP, SCREEN_BOTTOM).convert("RGBA")
    screen.putalpha(screen_mask)
    art = Image.alpha_composite(art, screen)

    # кнопка воспроизведения
    draw = ImageDraw.Draw(art)
    pcx, pcy = box_xy(0.500, 0.266)
    r = (sx1 - sx0) * 0.115
    draw.polygon([(pcx - r * 0.55, pcy - r), (pcx - r * 0.55, pcy + r),
                  (pcx + r * 1.00, pcy)], fill=ACCENT + (255,))

    # ------------------------------------------------ корпус проектора
    body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bx0, by0 = box_xy(0.322, 0.600)
    bx1, by1 = box_xy(0.678, 0.848)
    body_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(body_mask).rounded_rectangle(
        [bx0, by0, bx1, by1], radius=(bx1 - bx0) * 0.22, fill=255)

    body_grad = vgrad(S, BODY_TOP, BODY_BOTTOM).convert("RGBA")
    body_grad.putalpha(body_mask)
    art = Image.alpha_composite(art, body_grad)

    # подсветка верхней грани корпуса
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle(
        [bx0, by0, bx1, by1], radius=(bx1 - bx0) * 0.22,
        outline=(255, 255, 255, 60), width=max(1, int(S * 0.0016)))
    art = Image.alpha_composite(art, hl)

    # ------------------------------------------------ линза
    lcx, lcy = box_xy(0.500, 0.665)
    lr = (bx1 - bx0) * 0.150
    lens_glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(lens_glow).ellipse(
        [lcx - lr * 2.0, lcy - lr * 2.0, lcx + lr * 2.0, lcy + lr * 2.0],
        fill=BEAM + (72,))
    lens_glow = lens_glow.filter(ImageFilter.GaussianBlur(S * 0.012))
    art = Image.alpha_composite(art, lens_glow)

    lens = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(lens).ellipse(
        [lcx - lr, lcy - lr, lcx + lr, lcy + lr], fill=(238, 247, 255, 255))
    ImageDraw.Draw(lens).ellipse(
        [lcx - lr * 0.55, lcy - lr * 0.55, lcx + lr * 0.55, lcy + lr * 0.55],
        fill=ACCENT + (255,))
    art = Image.alpha_composite(art, lens)

    # ------------------------------------------------ сборка
    comp = Image.alpha_composite(base, art)

    # клип по сквирклу
    mask = Image.fromarray((squircle(S) * 255).astype(np.uint8), "L")
    comp.putalpha(Image.fromarray(
        (np.asarray(comp.split()[3], np.uint16) * np.asarray(mask, np.uint16) // 255
         ).astype(np.uint8)))

    # блик по верхней кромке
    inner = Image.fromarray(
        (squircle(S, scale=0.972) * 255).astype(np.uint8), "L")
    rim = ImageChops.subtract(mask, inner)
    rim_np = np.asarray(rim, np.float32)
    lum = np.linspace(1.0, 0.0, S, dtype=np.float32)[:, None] ** 1.6
    rim = Image.fromarray((rim_np * lum).astype(np.uint8), "L")
    highlight = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    highlight.putalpha(Image.fromarray(
        (np.asarray(rim, np.uint16) * 96 // 255).astype(np.uint8)))
    comp = Image.alpha_composite(comp, highlight)

    # ------------------------------------------------ тень под иконкой
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(Image.fromarray(
        (np.asarray(mask, np.uint16) * 110 // 255).astype(np.uint8)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.020))
    shadow = ImageChops.offset(shadow, 0, int(S * 0.014))

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, comp)

    return canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    icon = build()

    iconset = os.path.join(here, "iconset", "Проектор.iconset")
    os.makedirs(iconset, exist_ok=True)
    icon.save(os.path.join(here, "iconset", "icon_1024.png"))

    # Имена строго по требованиям iconutil: без них .icns собирается без части размеров.
    for size, name in [(16, "icon_16x16"), (32, "icon_16x16@2x"),
                       (32, "icon_32x32"), (64, "icon_32x32@2x"),
                       (128, "icon_128x128"), (256, "icon_128x128@2x"),
                       (256, "icon_256x256"), (512, "icon_256x256@2x"),
                       (512, "icon_512x512"), (1024, "icon_512x512@2x")]:
        icon.resize((size, size), Image.Resampling.LANCZOS).save(
            os.path.join(iconset, name + ".png"))

    icns = os.path.join(here, "Проектор.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("готово:", icns)


if __name__ == "__main__":
    main()
