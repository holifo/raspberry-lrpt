#!/usr/bin/env python3
#
# Draws the station label put on every capture image (called by meteor_normalize_annotate.sh).
# The layout is config/annotation/annotation.yml: a logo (or a short text) on the left, then two
# columns of centred text lines, on a panel with rounded corners. Its look comes from the settings
# annotation_style (a preset: STYLES below), annotation_transparency (0-100 % see-through) and,
# optionally, annotation_background / annotation_text_colour / annotation_border_colour (#rrggbb).
# Text and logo stay opaque.
#
#   annotation_panel.py SETTINGS.yml LAYOUT.yml OUT.png [key=value ...]
#
# Text lines use {key} for any setting in SETTINGS.yml (the install's merged settings) and for
# the key=value pairs given here (the pass: sat_name, capture_start, sat_max_elevation, …).
# A key that has no value is left empty.

import os
import string
import sys

import yaml
from PIL import Image, ImageDraw, ImageFont

SCALE = 2                        # drawn at twice the base size; the caller resizes it
FONT_DIRS = ['/usr/share/fonts/truetype/dejavu', '/usr/share/fonts/dejavu',
             '/usr/share/fonts/TTF', '/usr/share/fonts/truetype/freefont']
DEFAULT_LAYOUT = {
    'logo': '',
    'logo_text': 'LRPT',
    'station': ['{station_title}', '{ground_station_location}', '137 MHz {antenna_information} antenna'],
    'pass': ['Satellite: {sat_name} | {capture_start}',
             'Max Elevation: {sat_max_elevation}° {pass_side_long} | Sun Elevation: {sun_elevation}°',
             'Direction: {pass_direction} | Gain: {gain}'],
    'font': 'DejaVuSans.ttf',
    'bold_font': 'DejaVuSans-Bold.ttf',
    'font_size': 15,
}


# preset colours: panel, text, border; 'auto' is light for daytime passes and dark at night
STYLES = {
    'light': ('#cacaca', '#000000', '#333333'),   # the classic grey label, for daytime colour images
    'dark':  ('#0b1220', '#ffffff', '#4b5563'),   # the web panel's navy, for night / IR images
    'white': ('#ffffff', '#000000', '#999999'),   # clean white card, for sharing and printing
    'black': ('#000000', '#ffffff', '#555555'),   # plain black, for the black band (extend_for_annotation)
    'clear': (None,      '#ffffff', None),        # no panel: white text with a black outline
}
DEFAULT_TRANSPARENCY = 70


def colour(text, fallback):
    text = str(text or '').strip()
    if len(text) == 7 and text.startswith('#'):
        try:
            return tuple(int(text[i:i + 2], 16) for i in (1, 3, 5))
        except ValueError:
            pass
    return colour(fallback, None) if fallback else None


def look(values):
    """The panel's fill, text, border and outline colours as RGBA tuples (None = not drawn)."""
    style = str(values.get('annotation_style') or 'light').strip().lower()
    if style == 'auto':
        try:
            day = float(values.get('sun_elevation')) > float(values.get('meteor_m2_3_sun_min_elevation') or 0)
        except (TypeError, ValueError):
            day = True
        style = 'light' if day else 'dark'
    bg, fg, edge = STYLES.get(style, STYLES['light'])
    try:
        clear = int(float(values.get('annotation_transparency')))
    except (TypeError, ValueError):
        clear = DEFAULT_TRANSPARENCY
    alpha = round(255 * (100 - max(0, min(100, clear))) / 100)
    bg = colour(values.get('annotation_background'), bg)
    edge = colour(values.get('annotation_border_colour'), edge)
    fg = colour(values.get('annotation_text_colour'), fg)
    fill = bg + (alpha,) if bg else None
    border = edge + (255,) if edge else None
    # text with no panel behind it (style clear, or 100 % transparent) gets an outline to stay readable
    outline = None
    if fill is None or alpha < 40:
        outline = (0, 0, 0, 255) if sum(fg) > 382 else (255, 255, 255, 255)
    return fill, fg + (255,), border, outline


class Blank(dict):
    def __missing__(self, key):
        return ''


def fill(text, values):
    """{key} replaced from values; unknown keys become empty, stray braces stay as they are."""
    try:
        return string.Formatter().vformat(str(text), (), values)
    except (ValueError, IndexError):
        return str(text)


def font(name, size):
    for path in [name] + [os.path.join(d, name) for d in FONT_DIRS]:
        if path and os.path.isfile(path):
            return ImageFont.truetype(path, size)
    try:
        return ImageFont.load_default(size)          # Pillow 10.1+
    except TypeError:
        return ImageFont.load_default()


def main(settings_path, layout_path, out_path, pairs):
    with open(settings_path) as f:
        values = Blank({k: ('' if v is None else v) for k, v in (yaml.safe_load(f) or {}).items()})
    for pair in pairs:
        key, _, value = pair.partition('=')
        values[key] = value
    layout = dict(DEFAULT_LAYOUT)
    if os.path.isfile(layout_path):
        with open(layout_path) as f:
            layout.update(yaml.safe_load(f) or {})
    folder = os.path.dirname(os.path.abspath(layout_path))

    s = SCALE
    size = int(layout.get('font_size') or 15) * s
    regular = font(layout.get('font') or 'DejaVuSans.ttf', size)
    bold = font(layout.get('bold_font') or 'DejaVuSans-Bold.ttf', size)
    line_h = int(size * 1.35)
    pad, gap, border, radius, logo_box = 8 * s, 16 * s, 2 * s, 16 * s, 64 * s

    columns = [[fill(t, values) for t in (layout.get(k) or [])] for k in ('station', 'pass')]
    columns = [[t for t in col if t.strip()] or [''] for col in columns]
    probe = ImageDraw.Draw(Image.new('L', (1, 1)))
    widths = [max(int(probe.textlength(t, font=regular)) for t in col) for col in columns]

    logo = None
    if layout.get('logo'):
        path = os.path.join(folder, layout['logo'])
        if os.path.isfile(path):
            logo = Image.open(path).convert('RGBA').resize((logo_box, logo_box), Image.LANCZOS)
    logo_text = fill(layout.get('logo_text') or '', values)
    logo_w = logo_box if (logo or logo_text) else 0
    if logo_text and not logo:
        logo_w = max(logo_box, int(probe.textlength(logo_text, font=bold)) + 8 * s)

    content_h = max(logo_box if logo_w else 0, max(len(c) for c in columns) * line_h)
    parts = [w for w in [logo_w] + widths if w]
    width = sum(parts) + gap * (len(parts) - 1) + 2 * (pad + border)
    height = content_h + 2 * (pad + border)

    img = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    panel, ink, edge, halo = look(values)
    stroke = {'stroke_width': s, 'stroke_fill': halo} if halo else {}
    if panel or edge:
        draw.rounded_rectangle([0, 0, width - 1, height - 1], radius=radius,
                               fill=panel, outline=edge, width=border if edge else 0)
    x = pad + border
    top = pad + border
    if logo_w:
        if logo:
            img.alpha_composite(logo, (x, top + (content_h - logo_box) // 2))
        else:
            draw.text((x + logo_w // 2, top + content_h // 2), logo_text, font=bold,
                      fill=ink, anchor='mm', **stroke)
        x += logo_w + gap
    for col, w in zip(columns, widths):
        y = top + (content_h - len(col) * line_h) // 2
        for t in col:
            draw.text((x + w // 2, y + line_h // 2), t, font=regular, fill=ink, anchor='mm', **stroke)
            y += line_h
        x += w + gap
    img.save(out_path)


if __name__ == '__main__':
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
