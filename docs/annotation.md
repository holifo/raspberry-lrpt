# The image label

Every capture image gets a label: your station on the left, the pass on the right, on a light grey
70% transparent panel with rounded corners. It is drawn with Python Pillow by
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
