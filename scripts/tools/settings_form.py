#!/usr/bin/env python3
#
# The web panel's settings page (Admin > Settings). Run as the station user by
# scripts/settings_web.sh, which www-data may start through sudo (030_www-data-switch).
#
#   settings_form.py show    print the page's sections and this station's values as JSON
#   settings_form.py apply   read {"setting": "value as typed", ...} as JSON on stdin, check every
#                            value against config/settings_schema.json, save them to
#                            config/settings.local.yml (like settings.py set), refresh the merged
#                            file and write ~/.raspberry-lrpt.conf and the web panel's Config.php
#                            again (render_config.py). Prints a JSON result.
#
# Settings that need the install (drivers, nginx, NTP, predict's location, ...) are saved, but the
# installed copies keep their old values until ./install_and_upgrade.sh runs: the old values wait
# in config/.settings.pending.yml, which the install deletes. The admin password, the admin user
# name, the admin lock and the Discord webhook are never shown or changed here (SSH only).

import json
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings                 # noqa: E402  (scripts/tools/settings.py)
import render_config            # noqa: E402

PENDING = os.path.join(settings.REPO, 'config', '.settings.pending.yml')
MERGED = os.path.join(settings.REPO, 'config', '.settings.merged.yml')

# flags: a = advanced (folded), i = needs the install, r = reschedules the passes,
#        s = secret (only "set" / "not set"), l = locked (shown, changed over SSH only)
# (setting, flags, label, help)
FORM = [
  ('station', [
    ('station_title', '', 'Station name', 'Shown at the top of the Passes page, in the browser tab and in Discord posts.'),
    ('latitude', 'ir', 'Latitude', 'Decimal degrees, north positive. Used for the pass predictions and the maps.'),
    ('longitude', 'ir', 'Longitude', 'Decimal degrees, east positive.'),
    ('altitude', 'ir', 'Altitude', 'Metres above sea level.'),
    ('ground_station_location', '', 'Location on the images', 'Written in the label on every image (empty = left out).'),
    ('antenna_information', '', 'Antenna on the images', 'Written in the label on every image, e.g. QFH (empty = left out).'),
    ('lang_setting', '', 'Default language', 'The web panel\'s language for visitors who haven\'t picked one in the menu.'),
    ('ntp_server', 'i', 'NTP server', 'Time server for ntpsec, e.g. a pool like pool.ntp.org or a local stratum-1 server. Not used when the Pi runs chrony or openntpd.'),
  ]),
  ('receiver', [
    ('receiver_type', 'i', 'Receiver', 'The SDR the Meteors are recorded with. The install sets up its drivers.'),
    ('sdrplay_licence_accepted', 'i', 'SDRplay licence accepted', 'Needed for an SDRplay receiver: the install then downloads SDRplay\'s closed-source API.'),
    ('sdr_extra_options', '', 'Extra SatDump options', 'Added to every capture, e.g. --amp (HackRF amplifier) or --lna_gain 20 (SDRplay LNA state).'),
    ('use_device_string', 'ar', 'Use device strings', 'For several SDRs of the same kind: pick them by device string instead of index.'),
    ('test_gain', 'a', 'Test scripts: gain', 'Gain used by the scripts in scripts/testing.'),
    ('test_sdr_device_id', 'a', 'Test scripts: SDR index', 'SDR used by the scripts in scripts/testing.'),
    ('test_enable_bias_tee', 'a', 'Test scripts: bias tee', 'Bias tee for the scripts in scripts/testing.'),
    ('test_freq_offset', 'a', 'Test scripts: frequency offset', 'PPM correction for the scripts in scripts/testing.'),
  ]),
  ('meteor', [
    ('meteor_m2_3_schedule', 'r', 'Record METEOR-M2 3', 'Schedule its passes.'),
    ('meteor_m2_4_schedule', 'r', 'Record METEOR-M2 4', 'Schedule its passes.'),
    ('meteor_m2_3_gain', '', 'METEOR-M2 3 gain', 'Its meaning depends on the receiver: RTL-SDR 0-49.6 dB, Airspy 0-21, HackRF 0-102 dB, SDRplay IF gain 20-59, MiriSDR 0-100 dB. Not used by the Airspy HF+.'),
    ('meteor_m2_4_gain', '', 'METEOR-M2 4 gain', 'As above, for METEOR-M2 4.'),
    ('meteor_m2_3_enable_bias_tee', '', 'METEOR-M2 3 bias tee', 'Power an LNA through the antenna cable.'),
    ('meteor_m2_4_enable_bias_tee', '', 'METEOR-M2 4 bias tee', 'Power an LNA through the antenna cable.'),
    ('meteor_m2_3_sat_min_elevation', 'r', 'METEOR-M2 3 minimum elevation', 'Passes whose highest point is lower than this (degrees) are not recorded.'),
    ('meteor_m2_4_sat_min_elevation', 'r', 'METEOR-M2 4 minimum elevation', 'As above, for METEOR-M2 4.'),
    ('meteor_m2_3_sun_min_elevation', '', 'Day/night sun elevation', 'A pass counts as daytime when the sun is higher than this (degrees). Decides the image order, thumbnail and label style.'),
    ('meteor_m2_4_sun_min_elevation', '', 'Day/night sun elevation (M2 4)', 'As above, for METEOR-M2 4.'),
    ('select_best_overlapping_passes', 'r', 'Pick the best of overlapping passes', 'When two passes overlap, keep the higher one (Meteor before the ISS). Off: both stay and you delete one yourself.'),
    ('days_to_schedule_passes', 'r', 'Days to schedule', 'How many days ahead the passes are scheduled (today counts as 1).'),
    ('keep_recordings', '', 'Recordings to keep', 'The decoded frames (.cadu) of the newest N passes stay for download and re-processing (0 = none).'),
    ('meteor_m2_3_sdr_device_id', 'ar', 'METEOR-M2 3 SDR index', 'Which SDR records it when several are connected.'),
    ('meteor_m2_4_sdr_device_id', 'ar', 'METEOR-M2 4 SDR index', 'Which SDR records it when several are connected.'),
    ('meteor_m2_3_freq_offset', 'a', 'METEOR-M2 3 frequency offset', 'PPM correction (RTL-SDR).'),
    ('meteor_m2_4_freq_offset', 'a', 'METEOR-M2 4 frequency offset', 'PPM correction (RTL-SDR).'),
    ('meteor_m2_3_schedule_sun_min_elevation', 'ar', 'METEOR-M2 3: record only with the sun above', 'Degrees; -90 records day and night.'),
    ('meteor_m2_4_schedule_sun_min_elevation', 'ar', 'METEOR-M2 4: record only with the sun above', 'Degrees; -90 records day and night.'),
    ('meteor_m2_3_80k_interleaving', 'a', 'METEOR-M2 3 80k mode', 'Decode the 80 kbit/s interleaved signal instead of the usual 72k.'),
    ('meteor_m2_4_80k_interleaving', 'a', 'METEOR-M2 4 80k mode', 'Decode the 80 kbit/s interleaved signal instead of the usual 72k.'),
  ]),
  ('iss', [
    ('iss_sstv', 'r', 'Record the ISS (extra)', 'SSTV pictures during ARISS events, APRS on its other passes. Needs an RTL-SDR; Meteor passes come first.'),
    ('iss_sstv_dates', 'r', 'SSTV event dates', '"YYYY-MM-DD YYYY-MM-DD": record SSTV only between these dates (empty = every pass).'),
    ('iss_sstv_min_elevation', 'r', 'ISS minimum elevation', 'Passes whose highest point is lower than this (degrees) are not recorded.'),
    ('iss_sstv_frequency', '', 'SSTV frequency', 'MHz: 437.550 (70 cm, the 2026 events) or 145.800 (2 m).'),
    ('iss_sstv_gain', '', 'ISS gain', 'The RTL-SDR\'s gain for the ISS (dB).'),
    ('iss_aprs', 'r', 'APRS between SSTV events', 'Record the APRS stations heard through the ISS; they show live on the Satellites map.'),
    ('iss_aprs_frequency', '', 'APRS frequency', 'MHz: 437.825 (70 cm, since 2026) or 145.825 (2 m).'),
    ('iss_sdr_device', 'r', 'ISS RTL-SDR', 'Empty = automatic (a second RTL-SDR records alongside the Meteors), or an index, a serial number or part of the model name.'),
    ('iss_bias_tee', '', 'ISS bias tee', 'Bias tee on the ISS\'s own RTL-SDR (a shared one uses the METEOR-M2 3 setting).'),
  ]),
  ('images', [
    ('meteor_daytime_enhancements', '', 'Daytime image order', 'SatDump image names shown first on a daytime capture\'s page, space-separated. Others follow.'),
    ('meteor_nighttime_enhancements', '', 'Night-time image order', 'The same for night-time passes.'),
    ('meteor_daytime_thumbnail', '', 'Daytime thumbnail', 'Image names tried in order for a daytime capture\'s card.'),
    ('meteor_nighttime_thumbnail', '', 'Night-time thumbnail', 'Image names tried in order for a night-time capture\'s card.'),
    ('rain_images', 'i', 'Rain images', 'Rain likelihood from cloud-top temperature when the satellite sends calibration (it doesn\'t at the moment), and for night passes a relative "Coldest cloud tops" image. Estimates, not measurements.'),
    ('drop_dark_images', '', 'Drop images without a picture', 'Delete the images made from an empty channel: at night the sunlight channels 1-3 make white or yellow images. The pictures are checked, so dawn and dusk passes keep theirs.'),
    ('flip_meteor_image', '', 'Turn northbound passes', 'Rotate the images of northbound passes so north is up.'),
    ('meteor_jpg_image_quality', '', 'JPEG quality', '0-100.'),
    ('produce_spectrogram', '', 'Spectrogram', 'A waterfall of each pass with SNR, decoder lock and elevation.'),
    ('produce_polar_direction_graph', '', 'Sky track graph', 'The pass drawn on the sky.'),
    ('produce_polar_az_el_graph', '', 'Elevation & azimuth graph', 'Elevation and azimuth over the pass.'),
    ('live_preview', '', 'Live picture', 'While a pass records, show what has been decoded so far (needs 4 CPU cores).'),
  ]),
  ('label', [
    ('annotation_style', '', 'Label style', 'light, dark, auto (light by day, dark at night), white, black or clear (no panel, outlined text).'),
    ('annotation_transparency', '', 'Panel transparency', '0 (solid) to 100 (invisible) %; the text stays solid.'),
    ('annotation_background', '', 'Panel colour', '#rrggbb, empty = the style\'s.'),
    ('annotation_text_colour', '', 'Text colour', '#rrggbb, empty = the style\'s.'),
    ('annotation_border_colour', '', 'Border colour', '#rrggbb, empty = the style\'s.'),
    ('annotation_width_percent', '', 'Label width', 'Percent of the image width (0 = as drawn).'),
    ('image_annotation_location', '', 'Label position', 'Where on the image the label goes.'),
    ('extend_for_annotation', '', 'Black band for the label', 'Add a black band above or below the image for the label instead of covering the picture (not with West, Center or East).'),
  ]),
  ('maps', [
    ('daily_map', '', 'Daily map', 'Every pass of a day on one map of the region (Daily map page).'),
    ('map_capitals', 'i', 'Capital cities', 'Write capitals on the projected images and the daily map.'),
    ('map_projection', '', 'Map projection', 'equal_earth keeps every area\'s true size; equirectangular is SatDump\'s plain grid.'),
    ('enable_animation', '', 'Time-lapse', 'A time-lapse of each day\'s passes on the Daily map page.'),
    ('animation_area', '', 'Time-lapse area', '"west east south north" in degrees.'),
  ]),
  ('web', [
    ('web_passes_date_format', '', 'Date format', 'PHP date format, e.g. d/m/Y.'),
    ('web_datetime_format', '', 'Date and time format', 'PHP date format, e.g. d/m/Y H:i:s.'),
    ('experimental_features', '', 'Satellites tab', 'The live map of the satellites, their details and the pass tracks.'),
    ('web_server_name', 'i', 'Server name', 'The station\'s host name (DNS name or IP), used for the TLS certificate.'),
    ('enable_non_tls', 'i', 'Plain HTTP', 'Serve the web panel over HTTP.'),
    ('web_port', 'i', 'HTTP port', 'The port the web panel listens on.'),
    ('enable_tls', 'i', 'HTTPS', 'Serve the web panel over HTTPS (needs a certificate, see docs/tls_webserver.md).'),
    ('web_tls_port', 'i', 'HTTPS port', 'The port for HTTPS.'),
    ('lock_admin_page', 'l', 'Admin login', 'Ask for the user name and password on the admin pages.'),
    ('admin_username', 'l', 'Admin user name', ''),
    ('admin_password', 's', 'Admin password', ''),
  ]),
  ('discord', [
    ('discord_webhook', 's', 'Webhook', 'Empty = no posts.'),
    ('discord_site_url', '', 'Web panel address', 'The web panel as seen from the internet, for a link to each capture (empty = no link).'),
    ('discord_images', '', 'Images per post', '0-9.'),
    ('discord_sky_track', '', 'Post the sky track', 'Add the sky track graph to each post.'),
  ]),
  ('housekeeping', [
    ('delete_older_than_n', '', 'Delete captures older than', 'Days (0 = keep).'),
    ('delete_oldest_n', '', 'Delete the oldest N captures', 'On each clean-up run (0 = none).'),
    ('update_check', '', 'Update check', 'Look for a newer Raspberry-LRPT on GitHub once a day (it never updates by itself).'),
    ('log_level', '', 'Log level', 'How much the scripts write to the Live log.'),
    ('storage', 'i', 'The Pi runs from', 'sd: decode on a RAM disk to spare the card; ssd: no RAM disk.'),
    ('disable_wifi_power_mgmt', 'i', 'Wi-Fi power saving off', 'Keep wlan0 awake (needs a reboot after the install).'),
    ('disable_at_mail', 'a', 'No mail from at', 'Don\'t let the scheduled captures send local mail.'),
  ]),
]

META = {key: (flags, label, hint) for _, items in FORM for key, flags, label, hint in items}


def flag(key, f):
    return f in META[key][0]


def load_pending():
    return settings.load(PENDING)


def save_yaml(path, data, header):
    old = os.umask(0o077)
    try:
        with open(path, 'w') as f:
            f.write(header)
            yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    finally:
        os.umask(old)


def show():
    with open(settings.SCHEMA) as f:
        props = json.load(f)['properties']
    data = settings.merged()
    pending = load_pending()
    out = []
    for section, items in FORM:
        rows = []
        for key, flags, label, hint in items:
            p = props.get(key, {})
            row = {'key': key, 'label': label, 'help': hint, 'type': p.get('type', 'string'),
                   'advanced': 'a' in flags, 'install': 'i' in flags, 'reschedule': 'r' in flags,
                   'pending': key in pending}
            for k in ('enum', 'minimum', 'maximum', 'pattern'):
                if k in p:
                    row[k] = p[k]
            if 's' in flags:
                row['secret'] = True
                row['set'] = bool(data.get(key))
            else:
                row['value'] = data.get(key)
                row['locked'] = 'l' in flags
            rows.append(row)
        out.append({'id': section, 'settings': rows})
    print(json.dumps({'sections': out}, ensure_ascii=False))


def apply():
    try:
        changes = json.loads(sys.stdin.read(200000) or '{}')
    except ValueError:
        changes = None
    if not isinstance(changes, dict):
        print(json.dumps({'ok': False, 'errors': {'': 'bad request'}}))
        return 1
    errors, values = {}, {}
    for key, raw in changes.items():
        if key not in META or flag(key, 's') or flag(key, 'l'):
            errors[key] = 'can\'t be changed here'
            continue
        raw = '' if raw is None else str(raw)
        if any(ord(c) < 32 or ord(c) == 127 for c in raw):
            errors[key] = 'line breaks and control characters are not allowed'
            continue
        try:
            values[key] = settings.check_value(key, raw)
        except ValueError as e:
            errors[key] = str(e)
    if errors:
        print(json.dumps({'ok': False, 'errors': errors}, ensure_ascii=False))
        return 1

    data = settings.merged()
    changed = {k: v for k, v in values.items() if data.get(k) != v}
    pending = load_pending()
    if changed:
        # settings the install applies: the installed copies keep the old value meanwhile
        for key, value in changed.items():
            if flag(key, 'i'):
                if key not in pending:
                    pending[key] = data.get(key)
                elif pending[key] == value:
                    del pending[key]          # back to what is installed
        answers = settings.load(settings.LOCAL)
        answers.update(changed)
        settings.save_local(answers)
        settings.write_merged(MERGED)
        if pending:
            save_yaml(PENDING, pending, '# Installed values of settings changed on the web panel\'s settings page;\n'
                                        '# ./install_and_upgrade.sh applies the new ones and deletes this file.\n')
        elif os.path.exists(PENDING):
            os.remove(PENDING)
        live = settings.merged()
        live.update(pending)
        render_config.write_all(live)
    print(json.dumps({'ok': True, 'saved': sorted(changed),
                      'install': sorted(k for k in changed if flag(k, 'i')),
                      'pending': sorted(pending),
                      'reschedule': any(flag(k, 'r') and k not in pending for k in changed)},
                     ensure_ascii=False))
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'show':
        show()
    elif cmd == 'apply':
        sys.exit(apply())
    else:
        sys.exit('Usage: settings_form.py show | apply < changes.json')
