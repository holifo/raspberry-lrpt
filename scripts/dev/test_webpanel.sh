#!/bin/bash
#
# Purpose: Test the web panel on a development machine (not on the Pi).
#
#   1. Copies webpanel/ to a temporary folder and runs `composer install`.
#   2. Renders Config/Config.php from ansible/roles/webserver/templates/Config.php.j2
#      with config/settings.yml and ansible/group_vars/all.yml (strict: a missing
#      setting is an error). The admin login is switched off for the test.
#   3. Seeds a SQLite database from db_migrations/ with sample passes and captures,
#      writes a sample output.log and sample images, and copies the Meteor orbits
#      from scripts/dev/fixtures/meteor.tle.
#   4. Points the CDN links (Bootstrap, Font Awesome, jQuery, d3, topojson,
#      satellite.js, world-atlas) at local npm copies, because a sandbox or an
#      offline machine can't reach the CDNs.
#   5. Serves it with `php -S`, checks every page returns 200 with no PHP/Twig
#      errors, and takes screenshots in light and dark mode at 1000 px and 390 px.
#
# Requirements: php (sqlite3, mbstring, intl), composer, python3 with PyYAML and
#               Jinja2, npm, and Chrome or Chromium. ImageMagick is optional
#               (sample images).
#
# Usage:
#   ./scripts/dev/test_webpanel.sh [-o OUTPUT_DIR] [-k] [-p "/passes /log"]
#     -o  where to write screenshots (default: ./webpanel-test-output)
#     -k  keep the temporary web panel copy and print its path
#     -p  space-separated list of pages to test (default: all)
#
# Exit status: 0 when every page passes, 1 otherwise.

set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${PWD}/webpanel-test-output"
KEEP=0
PAGES="/passes /satellite /about /captures?page_no=1 /captures/listImages?pass_id=1 /captures/listImages?pass_id=2 /daily /satellite/map /admin/passes /admin/captures?page_no=1 /log"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rl1-webtest"

while getopts ":o:kp:" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    k) KEEP=1 ;;
    p) PAGES="$OPTARG" ;;
    *) sed -n '2,32p' "$0"; exit 2 ;;
  esac
done

say()  { echo -e "\033[1;34m==>\033[0m $*"; }
fail() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 2; }

# ---- requirements -------------------------------------------------------------
for bin in php composer python3 npm; do
  command -v $bin >/dev/null || fail "$bin is not installed"
done
for ext in sqlite3 mbstring intl; do
  php -m | grep -qi "^$ext$" || fail "PHP extension '$ext' is missing"
done
python3 -c "import yaml, jinja2" 2>/dev/null || fail "python3 needs PyYAML and Jinja2 (pip install pyyaml jinja2)"
CHROME=""
for c in google-chrome google-chrome-stable chromium chromium-browser; do
  command -v $c >/dev/null && { CHROME=$c; break; }
done
[ -n "$CHROME" ] || fail "Chrome or Chromium is not installed"
HAVE_IM=0; command -v convert >/dev/null && HAVE_IM=1

WORK="$(mktemp -d /tmp/rl1-webtest.XXXXXX)"
cleanup() {
  [ -n "${PHP_PID:-}" ] && kill "$PHP_PID" 2>/dev/null
  if [ "$KEEP" -eq 1 ]; then echo "Kept test copy: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

# ---- web panel copy and PHP dependencies ----------------------------------------
say "Copying web panel to $WORK"
cp -r "$REPO/webpanel" "$WORK/wp"
cp "$REPO/VERSION" "$WORK/wp/VERSION"
(cd "$WORK/wp" && composer install -q --no-interaction) || fail "composer install failed"

# ---- local copies of the CDN libraries (cached between runs) --------------------
say "Preparing local front-end libraries"
mkdir -p "$CACHE"
if [ ! -d "$CACHE/node_modules/world-atlas" ]; then
  (cd "$CACHE" && npm init -y >/dev/null 2>&1 &&
   npm install --silent bootstrap@4.6.0 @fortawesome/fontawesome-free@5.7.0 jquery@3.5.1 \
     d3@7.9.0 topojson-client@3.1.0 satellite.js@5.0.0 world-atlas@2) || fail "npm install failed"
fi
mkdir -p "$WORK/wp/public/vendor"
cp -r "$CACHE/node_modules/." "$WORK/wp/public/vendor/"

# ---- config, sample data, CDN rewrite ----------------------------------------------
say "Rendering Config.php and seeding sample data"
python3 - "$REPO" "$WORK" "$HAVE_IM" <<'PY' || fail "preparing the test copy failed"
import sys, os, re, json, glob, sqlite3, time, subprocess, shutil, yaml, jinja2
repo, work, have_im = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
wp = os.path.join(work, 'wp')
srv = os.path.join(work, 'srv')

# settings + group vars, resolving the group vars' own templates
v = yaml.safe_load(open(os.path.join(repo, 'config/settings.yml')))
v.update(yaml.safe_load(open(os.path.join(repo, 'ansible/group_vars/all.yml'))))
v.update(target_user='tester', system_timezone={'stdout': 'Europe/Athens'},
         raspbian_version={'stdout': os.environ.get('TEST_CODENAME', 'bookworm')},
         system_architecture='arm64',
         # the sample data has ISS passes and a capture: show the ISS extra (off by default on a
         # station); TEST_ISS=0 tests it off
         iss_sstv=os.environ.get('TEST_ISS', '1') == '1')
env = jinja2.Environment(undefined=jinja2.StrictUndefined)
for _ in range(3):
    for k, val in list(v.items()):
        if isinstance(val, str) and '{{' in val:
            v[k] = env.from_string(val).render(**v)
v.update(db_file=os.path.join(work, 'panel.db'), images_output=os.path.join(srv, 'images'),
         audio_output=os.path.join(srv, 'audio'),
         animation_output=os.path.join(srv, 'videos/RollingAnimation.webm'),
         log_file=os.path.join(work, 'output.log'))
tpl = open(os.path.join(repo, 'ansible/roles/webserver/templates/Config.php.j2')).read()
cfg = env.from_string(tpl).render(**v).replace("const LOCK_ADMIN = 'true'", "const LOCK_ADMIN = 'false'")
os.makedirs(os.path.join(wp, 'Config'), exist_ok=True)
open(os.path.join(wp, 'Config/Config.php'), 'w').write(cfg)

# CDN links -> local copies
cdn = {
  'https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/css/bootstrap.min.css': '/vendor/bootstrap/dist/css/bootstrap.min.css',
  'https://use.fontawesome.com/releases/v5.7.0/css/all.css': '/vendor/@fortawesome/fontawesome-free/css/all.css',
  'https://code.jquery.com/jquery-3.5.1.slim.min.js': '/vendor/jquery/dist/jquery.slim.min.js',
  'https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/js/bootstrap.bundle.min.js': '/vendor/bootstrap/dist/js/bootstrap.bundle.min.js',
  'https://cdn.jsdelivr.net/npm/d3@7.9.0/dist/d3.min.js': '/vendor/d3/dist/d3.min.js',
  'https://cdn.jsdelivr.net/npm/topojson-client@3.1.0/dist/topojson-client.min.js': '/vendor/topojson-client/dist/topojson-client.min.js',
  'https://cdn.jsdelivr.net/npm/satellite.js@5.0.0/dist/satellite.min.js': '/vendor/satellite.js/dist/satellite.min.js',
  'https://cdn.jsdelivr.net/npm/world-atlas@2/countries-50m.json': '/vendor/world-atlas/countries-50m.json',
}
for f in glob.glob(os.path.join(wp, 'App/Views/**/*.html'), recursive=True) + glob.glob(os.path.join(wp, 'App/Static/*.html')):
    s = open(f, encoding='utf-8').read(); o = s
    for a, b in cdn.items():
        s = s.replace(a, b)
    s = re.sub(r'\s+integrity="[^"]+"', '', s)
    if s != o:
        open(f, 'w', encoding='utf-8').write(s)

# Meteor orbits for the live map (a fixed sample: the map propagates it to now)
shutil.copy(os.path.join(repo, 'scripts/dev/fixtures/meteor.tle'), os.path.join(wp, 'App/Static/meteor.tle'))

# database: schema from the migrations, then sample passes and captures
db = sqlite3.connect(v['db_file'])
for f in sorted(glob.glob(os.path.join(repo, 'db_migrations/*.sql'))):
    db.executescript(open(f).read())
now = int(time.time())
start = now - 3 * 3600
for i in range(10):
    sat = 'METEOR-M2 3' if i % 2 == 0 else 'METEOR-M2 4'
    s = start + i * 5400
    db.execute('INSERT INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
               'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,?,?,?,?)',
               (sat, s, s + 780, [34, 61, 22, 47, 18, 72, 29, 55, 40, 25][i], 1,
                [12, 190, 340, 165, 20, 200, 350, 170, 15, 185][i], ['Southbound', 'Northbound'][i % 2], [101, 260][i % 2]))
# ISS SSTV (iss_sstv): two coming ISS passes, and yesterday's pass with two SSTV pictures
for k, s in enumerate((now + 2 * 3600 + 1200, now + 26 * 3600)):
    db.execute('INSERT INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
               'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,?,?,?,?)',
               ('ISS', s, s + 600, [52, 31][k], 1, [240, 300][k], 'Northbound', 180))
os.makedirs(os.path.join(srv, 'images/thumb'), exist_ok=True)
iss_ps = now - 86400 - 5000
db.execute('INSERT INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
           'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,?,?,?,?)',
           ('ISS', iss_ps, iss_ps + 610, 63, 0, 250, 'Northbound', 170))
db.execute('INSERT INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, img_count, gain, '
           'has_spectrogram, has_pristine, has_polar_az_el, has_polar_direction, has_histogram) '
           'VALUES (?,?,1,3,2,30,0,0,0,0,0)', (iss_ps, 'ISS-sample'))
if have_im:
    for n, grad in ((1, 'gradient:navy-orange'), (2, 'gradient:darkgreen-skyblue')):
        img = os.path.join(srv, 'images', 'ISS-sample-SSTV_%d.jpg' % n)
        subprocess.run(['convert', '-size', '640x496', grad, '-gravity', 'north', '-fill', 'white',
                        '-pointsize', '36', '-annotate', '+0+20', 'ARISS SSTV %d/12' % n, img], check=False)
        for suffix in ('-SSTV_%d.jpg' % n,) + (('-website-thumbnail.jpg',) if n == 1 else ()):
            subprocess.run(['convert', img, '-resize', '300x', os.path.join(srv, 'images/thumb', 'ISS-sample' + suffix)], check=False)
# ISS APRS (iss_aprs): a pass with stations heard through the ISS (drawn by the station's own
# aprs_pass.py), and an APRS pass being recorded now for the Satellites map's live layer.
# N0CALL is APRS's placeholder call sign.
aprs_hdr = ('chan,utime,isotime,source,heard,level,error,dti,name,symbol,latitude,longitude,speed,course,'
            'altitude,frequency,offset,tone,system,status,telemetry,comment')
aprs_st = [('N0CALL-7', 'RS0ISS', 38.25, 21.73, '/>', 'Mobile via ARISS'),
           ('N0CALL-9', 'RS0ISS', 41.01, 28.98, '/[', 'Hello from the bridge'),
           ('N0CALL-1', 'RS0ISS', 35.34, 25.13, '/-', 'QRV 145.825 sat'),
           ('N0CALL-5', 'RS0ISS', 32.89, 13.19, '/-', '73 de N0CALL'),
           ('N0CALL-3', 'RS0ISS', 39.62, 19.92, '/`', 'Portable, 5 W Arrow'),
           ('N0CALL-2', 'RS0ISS', None, None, '', 'ISS QSO? 73')]
def aprs_csv(path, t0, n):
    with open(path, 'w') as f:
        f.write(aprs_hdr + '\n')
        for j, (call, heard, la, lo, sym, cmt) in enumerate(aprs_st[:n]):
            for rep in range(1 + j % 2):
                t = t0 + 40 * j + 25 * rep
                f.write('0,%d,x,%s,%s,50(14/14),0,!,%s,%s,%s,%s,,,,,,,,,,"%s"\n' % (
                    t, call, heard, call, sym, '' if la is None else la, '' if lo is None else lo, cmt))
aprs_ps = now - 86400 - 20000
try:   # a real ISS pass over the sample station, so the map's track crosses the stations
    import ephem, datetime
    l = [x for x in open(os.path.join(wp, 'App/Static/meteor.tle')).read().split('\n') if x.strip()]
    k = [x.strip() for x in l].index('ISS')
    o = ephem.Observer(); o.lat, o.lon, o.horizon = '37.983810', '23.727539', '10'
    o.date = datetime.datetime.fromtimestamp(aprs_ps, datetime.timezone.utc).replace(tzinfo=None)
    for _ in range(12):
        p = o.next_pass(ephem.readtle('ISS', l[k + 1], l[k + 2]))
        if p[3] > 0.6:         # max elevation over ~35 degrees
            break
        o.date = p[4] + ephem.minute
    aprs_ps = int(ephem.Date(p[0]).datetime().replace(tzinfo=datetime.timezone.utc).timestamp())
    if aprs_ps > now - 3600:
        aprs_ps = now - 86400 - 20000
except Exception:
    pass
db.execute('INSERT INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
           'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,?,?,?,?)',
           ('ISS', aprs_ps, aprs_ps + 600, 48, 0, 290, 'Southbound', 200))
db.execute('INSERT INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, img_count, gain, '
           'has_spectrogram, has_pristine, has_polar_az_el, has_polar_direction, has_histogram) '
           'VALUES (?,?,1,4,?,30,0,0,0,0,0)', (aprs_ps, 'ISS-aprs-sample', len(aprs_st)))
aprs_tmp = os.path.join(work, 'aprs-sample.csv')
aprs_csv(aprs_tmp, aprs_ps + 60, len(aprs_st))
r = subprocess.run([sys.executable, '-I', os.path.join(repo, 'scripts/image_processors/aprs_pass.py'),
                    aprs_tmp, '', os.path.join(wp, 'App/Static/meteor.tle'), 'ISS', str(aprs_ps),
                    str(aprs_ps + 600), '37.983810', '23.727539',
                    os.path.join(srv, 'images', 'ISS-aprs-sample'), '437.825'], capture_output=True, text=True)
if r.returncode != 0:
    print('APRS sample not drawn:', r.stderr.strip()[-300:])
elif have_im:
    for src, dst in (('-aprs-map.png', '-aprs-map.png'), ('-aprs-map.png', '-website-thumbnail.jpg')):
        subprocess.run(['convert', os.path.join(srv, 'images', 'ISS-aprs-sample' + src), '-resize', '300x',
                        os.path.join(srv, 'images/thumb', 'ISS-aprs-sample' + dst)], check=False)
json.dump({'base': 'ISS-live', 'start': now - 200, 'end': now + 400, 'frequency': '437.825'},
          open(os.path.join(srv, 'images', 'aprs-live.json'), 'w'))
aprs_csv(os.path.join(srv, 'images', 'aprs-live.csv'), now - 180, 5)
# TEST_LIVE_METEOR=1: a Meteor pass being recorded now, with its live picture (live_preview.sh),
# so the live decode panel shows the picture box (SatDump's /api is absent: "Waiting for SatDump")
if os.environ.get('TEST_LIVE_METEOR') == '1':
    db.execute('INSERT INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
               'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,?,?,?,?)',
               ('METEOR-M2 4', now - 240, now + 540, 61, 1, 190, 'Southbound', 100))
    json.dump({'sat': 'METEOR-M2 4', 'start': now - 230, 'end': now + 530, 'samplerate': 1024000,
               'frequency': 137.9, 'max_elev': 61, 'port': 9}, open(os.path.join(srv, 'images', 'live.json'), 'w'))
    pic = os.environ.get('TEST_LIVE_PICTURE', '')
    if pic and os.path.isfile(pic):
        shutil.copy(pic, os.path.join(srv, 'images', 'live-preview.jpg'))
    elif have_im:
        subprocess.run(['convert', '-size', '480x620', 'plasma:gray20-white', '-colorspace', 'Gray',
                        os.path.join(srv, 'images', 'live-preview.jpg')], check=False)
    json.dump({'start': now - 230, 'made': now - 20, 'channel': 2, 'lines': 1640},
              open(os.path.join(srv, 'images', 'live-preview.json'), 'w'))
# the update check's result (scripts/update_check.sh): TEST_UPDATE=ok (default) | update | install |
# error | off | none (no file)
ust = os.environ.get('TEST_UPDATE', 'ok')
if ust != 'none':
    ver = open(os.path.join(repo, 'VERSION')).read().strip()
    nxt = ver.rsplit('.', 1)[0] + '.' + str(int(ver.rsplit('.', 1)[1]) + 1)
    json.dump({'status': ust, 'installed': ver, 'repo': nxt if ust == 'install' else ver,
               'latest': '' if ust in ('off', 'error') else (nxt if ust in ('update', 'install') else ver),
               'behind': 4 if ust == 'update' else 0, 'dirty': 0,
               'releases': 'https://github.com/holifo/raspberry-lrpt/releases', 'checked': now - 3600,
               'error': 'fatal: unable to access the repository: Could not resolve host: github.com' if ust == 'error' else ''},
              open(os.path.join(srv, 'images', 'update.json'), 'w'))
# a station photo for the About page (scripts/station_photo.sh) with TEST_STATION_PHOTO=1, or
# TEST_STATION_PHOTO=file to use a real picture
sp = os.environ.get('TEST_STATION_PHOTO', '')
if sp:
    from PIL import Image, ImageDraw
    os.makedirs(os.path.join(srv, 'images', 'station'), exist_ok=True)
    out = os.path.join(srv, 'images', 'station', 'photo.jpg')
    if os.path.isfile(sp):
        im = Image.open(sp).convert('RGB'); im.thumbnail((1600, 1600)); im.save(out, quality=85)
    else:
        w, h = 1200, 800
        im = Image.new('RGB', (w, h)); d = ImageDraw.Draw(im)
        for y in range(h):   # evening sky
            t = y / h; d.line([(0, y), (w, y)], fill=(int(30 + 200 * t), int(60 + 90 * t), int(140 - 40 * t)))
        d.rectangle([0, 620, w, h], fill=(40, 46, 38))
        d.rectangle([592, 300, 608, 640], fill=(70, 70, 70))          # mast
        for k in range(6):                                            # a QFH-ish helix
            y = 200 + k * 18; d.arc([560, y, 640, y + 40], 0, 180, fill=(220, 220, 220), width=4)
        im.save(out, quality=85)
    json.dump({'caption': 'QFH antenna on the roof (test picture)', 'made': now},
              open(os.path.join(srv, 'images', 'station', 'photo.json'), 'w'))
for i in range(6):
    fp = 'METEOR-M2-%d-sample%d' % (3 + i % 2, i)
    ps = now - 86400 * (i + 1)
    # the capture lists join decoded_passes to predict_passes on pass_start
    db.execute('INSERT INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
               'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,?,?,?,?)',
               ('METEOR-M2 %d' % (3 + i % 2), ps, ps + 780, 30 + 7 * i, 0, 15, 'Northbound', 100))
    db.execute('INSERT INTO decoded_passes (pass_start, file_path, daylight_pass, sat_type, img_count, gain, '
               'has_spectrogram, has_pristine, has_polar_az_el, has_polar_direction, has_histogram) '
               'VALUES (?,?,?,?,?,?,?,0,?,?,0)', (ps, fp, i % 2, 0, 3, 48, int(i == 0), int(i == 0), int(i == 0)))
    if have_im:
        for suffix in ('-website-thumbnail.jpg', '-MSA_corrected.jpg', '-MCIR_corrected.jpg',
                       '-AVHRR_221_False_Color_corrected.jpg', '-3.9_um_Shortwave_IR_(Calibrated)_corrected.jpg'):
            for d in ('images', 'images/thumb'):
                subprocess.run(['convert', '-size', '300x300',
                                'plasma:' + ('steelblue-white' if i % 2 else 'navy-gray'),
                                os.path.join(srv, d, fp + suffix)], check=False)
    # the first capture also gets a kept recording and the pass graphs, drawn by the station's own script
    if i == 0:
        os.makedirs(os.path.join(srv, 'audio/meteor'), exist_ok=True)
        open(os.path.join(srv, 'audio/meteor', fp + '.cadu'), 'wb').write(os.urandom(3 * 1048576))
        tle = os.path.join(wp, 'App/Static/meteor.tle')
        g0, g1 = now - 1800, now - 600
        try:   # use a real pass over the station when ephem is available
            import ephem, datetime
            l = open(tle).read().split('\n')
            o = ephem.Observer(); o.lat, o.lon, o.horizon = '37.983810', '23.727539', '0'
            o.date = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(hours=12)
            best = None
            for _ in range(8):
                p = o.next_pass(ephem.readtle(*l[:3]))
                if best is None or p[3] > best[3]: best = p
                o.date = p[4] + ephem.minute
            g0 = int(ephem.Date(best[0]).datetime().replace(tzinfo=datetime.timezone.utc).timestamp())
            g1 = int(ephem.Date(best[4]).datetime().replace(tzinfo=datetime.timezone.utc).timestamp())
        except Exception:
            pass
        for kind, suffix in (('azel', '-polar-azel.jpg'), ('direction', '-polar-direction.png')):
            out = os.path.join(srv, 'images', fp + suffix)
            r = subprocess.run([sys.executable, '-I', os.path.join(repo, 'scripts/image_processors/polar_plot.py'),
                                'METEOR-M2 3', tle, str(g0), str(g1), '37.983810', '23.727539',
                                '15', 'Southbound', out, kind], capture_output=True, text=True)
            if r.returncode == 0 and have_im:
                subprocess.run(['convert', out, '-resize', '300x', os.path.join(srv, 'images/thumb', fp + suffix)])
            elif r.returncode:
                print('  (pass graph skipped: %s)' % (r.stderr.strip().splitlines() or ['error'])[-1])
        # spectrogram from a made-up pass (signal rising and setting, Doppler drift, decoder lock)
        import numpy as np
        rng = np.random.default_rng(3); fs = 1.024e6; nb = 1024; T = max(60, g1 - g0)
        fr = (np.arange(nb) - nb / 2) * fs / nb
        x = np.arange(T) / T; amp = np.sin(np.pi * x) ** 1.5
        fft = (-50 + rng.normal(0, 1.2, (T, nb)) + (amp * 16)[:, None]
               * np.exp(-((fr[None, :] - (3200 * np.cos(np.pi * x))[:, None]) / 48e3) ** 8)).astype(np.float32)
        snr = np.maximum(0, amp * 11 + rng.normal(0, 0.4, T)); lock = (snr > 3.5).astype(int)
        npz = os.path.join(work, 'spectro.npz')
        np.savez_compressed(npz, t=g0 + np.arange(T), fft=fft, snr=snr, freq=np.zeros(T), ber=np.zeros(T),
                            vlock=lock, dlock=lock, samplerate=fs)
        out = os.path.join(srv, 'images', fp + '-spectrogram.png')
        r = subprocess.run([sys.executable, '-I', os.path.join(repo, 'scripts/image_processors/spectrogram.py'), 'render',
                            npz, out, 'METEOR-M2 3', tle, '37.983810', '23.727539', '15'], capture_output=True, text=True)
        if r.returncode == 0 and have_im:
            subprocess.run(['convert', out, '-resize', '300x', os.path.join(srv, 'images/thumb', fp + '-spectrogram.png')])
        elif r.returncode:
            print('  (spectrogram skipped: %s)' % (r.stderr.strip().splitlines() or ['error'])[-1])
db.commit()

# daily maps (scripts/daily_map.sh): two days of day and night maps over the sample captures
daily = os.path.join(srv, 'images/daily')
os.makedirs(os.path.join(daily, 'thumb'), exist_ok=True)
for back in (1, 2):
    day = time.strftime('%Y-%m-%d', time.localtime(now - 86400 * back))
    caps = ['METEOR-M2-%d-sample%d' % (3 + j % 2, j) for j in range(6)]
    json.dump({'date': day, 'day': caps[1::2], 'night': caps[0::2], 'bounds': [-6.9, 61.1, 63.1, 11.1],
               'size': [2800, 2000], 'deg_per_px': 0.025, 'made': now - 86400 * back + 3600,
               'composites': {'day': {'name': 'AVHRR 221', 'channels': [2, 2, 1], 'wavelengths': '0.8, 0.8, 0.6 µm'},
                              'night': {'name': '3.9 µm Shortwave IR', 'channels': [4], 'wavelengths': '3.8 µm, inverted'}},
               'projection': 'equal_earth', 'decoder': 'SatDump v1.2.3'},
              open(os.path.join(daily, day + '.json'), 'w'))
    if have_im:
        for kind, fill in (('day', 'steelblue-white'), ('night', 'gray20-gray80')):
            out = os.path.join(daily, '%s-%s.jpg' % (day, kind))
            subprocess.run(['convert', '-size', '1400x1000', 'plasma:' + fill, out], check=False)
            subprocess.run(['convert', out, '-resize', '700x', os.path.join(daily, 'thumb', os.path.basename(out))], check=False)

# time-lapse (scripts/animation.sh): one per daily-map day, a few made-up frames over Greece
tl = os.path.join(daily, 'timelapse')
os.makedirs(tl, exist_ok=True)
if have_im and shutil.which('ffmpeg'):
    tmpf = os.path.join(tl, 'frames')
    os.makedirs(tmpf, exist_ok=True)
    for j, fill in enumerate(('gray10-gray70', 'gray20-gray80', 'gray15-gray90')):
        subprocess.run(['convert', '-size', '1100x1030', 'plasma:' + fill, os.path.join(tmpf, '%04d.jpg' % j)], check=False)
    for back in (1, 2):
        day = time.strftime('%Y-%m-%d', time.localtime(now - 86400 * back))
        for ext, codec in (('webm', ['-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-cpu-used', '8']),
                           ('mp4', ['-c:v', 'libx264', '-preset', 'veryfast'])):
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-framerate', '2', '-i', os.path.join(tmpf, '%04d.jpg')]
                           + codec + ['-pix_fmt', 'yuv420p', os.path.join(tl, day + '.' + ext)], check=False)
        subprocess.run(['convert', os.path.join(tmpf, '0002.jpg'), '-resize', '640x640>', os.path.join(tl, day + '.jpg')], check=False)
        start = int(time.mktime(time.strptime(day, '%Y-%m-%d')))
        json.dump({'date': day, 'bounds': [19, 42, 30, 34], 'size': [1100, 1030], 'made': now - 600,
                   'projection': 'equal_earth', 'composite': '3.9 µm Shortwave IR',
                   'passes': [time.strftime('METEOR-M2-3-%Y%m%d-%H%M%S', time.gmtime(start + 3600 * h)) for h in (2, 9, 13, 21)]},
                  open(os.path.join(tl, day + '.json'), 'w'))
    shutil.rmtree(tmpf)

# sample log for Admin > Live log
open(v['log_file'], 'w').write(
  '11-11-2026 18:01 %s/scripts/schedule.sh INFO : Downloading new TLE files from source\n'
  '11-11-2026 18:40 %s/scripts/receive_meteor.sh INFO : Starting capture of METEOR-M2 3\n'
  '11-11-2026 18:40 %s/scripts/receive_meteor.sh DEBUG : Gain 48, bias tee off\n'
  '\x1b[32m[18:40:05 - 11/11/2026] (I) Loading pipelines from /usr/share/satdump/pipelines\x1b[m\n'
  '\x1b[36m[18:40:06 - 11/11/2026] (D) Starting meteor_m2-x_lrpt\x1b[m\n'
  '\x1b[33m\x1b[1m[18:52:41 - 11/11/2026] (W) Viterbi lost lock\x1b[m\n'
  '\x1b[31m\x1b[1m[18:54:02 - 11/11/2026] (E) Error loading plugin librtlsdr_sdr_support.so\x1b[m\n'
  '11-11-2026 18:53 %s/scripts/receive_meteor.sh WARN : Low SNR during part of the pass\n'
  '11-11-2026 18:55 %s/scripts/receive_meteor.sh ERROR : Example error line\n' % ((v['lrpt_home'],) * 5))
PY

# router: /images/... from the sample folder, everything else through index.php
cat > "$WORK/wp/router.php" <<PHP
<?php
\$u = parse_url(\$_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (preg_match('#/images/(.*)\$#', \$u, \$m)) {
  \$f = '$WORK/srv/images/' . \$m[1];
  \$types = array('png' => 'image/png', 'webm' => 'video/webm', 'mp4' => 'video/mp4', 'json' => 'application/json');
  if (is_file(\$f)) { header('Content-Type: ' . (\$types[pathinfo(\$f, PATHINFO_EXTENSION)] ?? 'image/jpeg')); readfile(\$f); return true; }
  http_response_code(404); return true;
}
if (preg_match('#/videos/(.*)\$#', \$u, \$m)) {
  \$f = '$WORK/srv/videos/' . basename(\$m[1]);
  \$types = array('webm' => 'video/webm', 'mp4' => 'video/mp4', 'jpg' => 'image/jpeg');
  if (is_file(\$f)) { header('Content-Type: ' . (\$types[pathinfo(\$f, PATHINFO_EXTENSION)] ?? 'application/octet-stream')); readfile(\$f); return true; }
  http_response_code(404); return true;
}
if (preg_match('#^/recordings/(.*)\$#', \$u, \$m)) {
  \$f = '$WORK/srv/audio/meteor/' . basename(urldecode(\$m[1]));
  if (is_file(\$f)) { header('Content-Type: application/octet-stream'); header('Content-Disposition: attachment'); readfile(\$f); return true; }
  http_response_code(404); return true;
}
if (\$u !== '/' && is_file(__DIR__ . '/public' . \$u)) return false;
\$_SERVER['REQUEST_SCHEME'] = 'http';
chdir(__DIR__ . '/public');
require __DIR__ . '/public/index.php';
PHP

# ---- serve ---------------------------------------------------------------------
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$WORK/wp" && php -d date.timezone=Europe/Athens -S "127.0.0.1:$PORT" -t public router.php >"$WORK/php.log" 2>&1) &
PHP_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/passes" && break; sleep 0.1; done

# ---- check pages and take screenshots ---------------------------------------------
mkdir -p "$OUT"
FAILED=0
say "Checking pages on http://127.0.0.1:$PORT"
for page in $PAGES; do
  code=$(curl -s -o "$WORK/page.html" -w '%{http_code}' "http://127.0.0.1:$PORT$page")
  errors=$(grep -c -i -E 'Fatal error|Warning:|Notice:|Deprecated:|Twig\\Error|Uncaught|404 - ' "$WORK/page.html")
  if [ "$code" == "200" ] && [ "$errors" -eq 0 ]; then
    printf "  \033[32mPASS\033[0m  %-36s\n" "$page"
  else
    printf "  \033[31mFAIL\033[0m  %-36s HTTP %s, %s error line(s)\n" "$page" "$code" "$errors"
    grep -i -m3 -E 'Fatal error|Warning:|Notice:|Twig\\Error|Uncaught' "$WORK/page.html" | sed 's/<[^>]*>//g; s/^/        /'
    FAILED=1
  fi
  name=$(echo "$page" | sed 's#^/##; s#[/?=&]#_#g'); [ -z "$name" ] && name=root
  for width in 1000 390; do
    "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=6000 \
      --window-size=$width,1100 --screenshot="$OUT/${name}_${width}_light.png" \
      "http://127.0.0.1:$PORT$page" >/dev/null 2>&1
    "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --virtual-time-budget=6000 \
      --force-dark-mode --blink-settings=preferredColorScheme=0 \
      --window-size=$width,1100 --screenshot="$OUT/${name}_${width}_dark.png" \
      "http://127.0.0.1:$PORT$page" >/dev/null 2>&1
  done
done

# /meteor (the old Sat info tab) must send old links to /about
loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://127.0.0.1:$PORT/meteor")
if [ "$loc" == "301 http://127.0.0.1:$PORT/about" ]; then
  printf "  \033[32mPASS\033[0m  %-36s\n" "/meteor -> /about"
else
  printf "  \033[31mFAIL\033[0m  %-36s %s\n" "/meteor -> /about" "$loc"; FAILED=1
fi

if grep -q -i -E "PHP (Fatal|Warning|Parse)" "$WORK/php.log"; then
  echo "PHP server log errors:"; grep -i -E "PHP (Fatal|Warning|Parse)" "$WORK/php.log" | head -5
  FAILED=1
fi

say "Screenshots: $OUT ($(ls "$OUT"/*.png 2>/dev/null | wc -l) files)"
[ "$FAILED" -eq 0 ] && say "All pages passed" || echo -e "\033[1;31mSome pages failed\033[0m"
exit $FAILED
