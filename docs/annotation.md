# The image label

Every capture image gets a label: your station on the left, the pass on the right, on a panel
with rounded corners (light grey and 70% see-through unless you choose another look, below). It is drawn with Python Pillow by
`scripts/image_processors/annotation_panel.py`, from `config/annotation/annotation.yml`.

```yaml
logo: ''                 # a square PNG in config/annotation/ (e.g. logo.png, 256 px), drawn at 64 px
logo_text: LRPT          # shown instead when there is no logo
station:                 # the middle column
  - "{station_title}"
  - "{ground_station_location}"
  - "137 MHz {antenna_information} antenna"
pass:                    # the right column
  - "Satellite: {sat_name} | {capture_start}"
  - "Max Elevation: {sat_max_elevation}° {pass_side_long} | Sun Elevation: {sun_elevation}°"
  - "Direction: {pass_direction} | Gain: {gain}"
font: DejaVuSans.ttf     # any TrueType font in /usr/share/fonts
bold_font: DejaVuSans-Bold.ttf
font_size: 15
```

Each line can use `{key}` for any setting in `config/settings.yml` and for these, filled in for each
image: `sat_name`, `capture_start`, `sat_max_elevation`, `sun_elevation`, `pass_direction`,
`pass_side` (E/W), `pass_side_long` (East/West) and `gain`. Add or remove lines as
you like; each column is centred.

Settings in `config/settings.yml` place it on the image:

| Setting | What it does |
|---|---|
| `image_annotation_location` | Where: `NorthWest`, `North`, `NorthEast`, `West`, `Center`, `East`, `SouthWest`, `South`, `SouthEast` |
| `annotation_width_percent` | Its width as a share of the image's (50 = half); 0 = as drawn |
| `extend_for_annotation` | Add a black band above or below the image for it, instead of covering the picture |
| `annotation_style` | Its look, see below (default `light`) |
| `annotation_transparency` | How see-through the panel is: 0 = solid, 100 = no panel at all (default 70). Text and logo stay solid |
| `annotation_background`, `annotation_text_colour`, `annotation_border_colour` | `'#rrggbb'` to replace one of the style's colours; `''` keeps the style's |

### Choosing a look

| `annotation_style` | Looks like | Good for |
|---|---|---|
| `light` | Light grey panel, black text (the classic label) | Daytime colour images (MSA, 221, Natural Color) |
| `dark` | Navy panel (the web panel's colour), white text | Night and IR images (MCIR, thermal), which are mostly dark |
| `auto` | `light` for daytime passes, `dark` at night (by the sun at the station, as for the day/night lists) | A station that records day and night: always the right one |
| `white` | White panel, black text | Sharing and printing: with a low transparency (0–20) it reads like a caption card |
| `black` | Black panel, white text | Matching the black band of `extend_for_annotation`, or a solid bar (transparency 0) |
| `clear` | No panel or border: white text with a black outline | Covering as little of the picture as possible |

The quickest way to change it on the Pi is `scripts/label.sh` (it keeps your choice in
`config/settings.local.yml`, so `git pull` and the next install leave it alone):

```bash
cd ~/raspberry-lrpt
scripts/label.sh                         # the current look and the styles
scripts/label.sh auto 60                 # style auto, 60 % see-through
scripts/label.sh transparency 30         # only the transparency
scripts/label.sh text '#f2b33d'          # one colour (background, text or border); 'default' = the style's
scripts/label.sh reset                   # back to the classic light grey, 70 %
scripts/label.sh preview                 # draw it to tmp/label-preview.png (auto: a day and a night one)
```

The same settings in a settings file:

```yaml
# readable on every pass, day or night
annotation_style: 'auto'
annotation_transparency: 60

# a solid caption for social media
annotation_style: 'white'
annotation_transparency: 0

# your own colours: amber text on a dark brown panel
annotation_style: 'dark'
annotation_transparency: 40
annotation_background: '#3a2600'
annotation_text_colour: '#f2b33d'
annotation_border_colour: '#f2b33d'
```

A change applies to the next pass (and to `reprocess_meteor.sh`); images already made keep their label.

## Trying it out

```bash
./scripts/testing/produce_annotation_image.sh /tmp/label.png
```

draws the label with example pass details. To look at it from another computer, copy it over
(`scp pi@<your_pi>:/tmp/label.png .`) or into the web panel's folder
(`cp /tmp/label.png /var/www/wx-new/public/assets/` and open `http://<your_pi>/assets/label.png`).

Before v1.24.0 the label was an HTML template (`annotation.html.j2`) rendered with wkhtmltoimage,
which Debian Trixie no longer has. If you had changed that template, put the same text in
`annotation.yml`.
