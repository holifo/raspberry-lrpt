#!/bin/bash
#
# Makes the sample screenshots in docs/assets/screenshots/ (shown in docs/webpanel_screenshots.md).
#
# Dev machine only (not the Pi). It builds a test copy of the web panel with
# scripts/dev/test_webpanel.sh, gives it real METEOR imagery decoded with SatDump from the
# verification tool's test CADU (falls back to the made-up images if SatDump is missing),
# adds a few days of passes, then drives Chrome with playwright-core to photograph every view.
#
# Usage: ./scripts/dev/make_screenshots.sh [-o DIR]
# Needs what test_webpanel.sh needs, plus Node.js; SatDump 1.2.3 and ImageMagick are optional.

set -u
PHP_PID=""
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO/docs/assets/screenshots"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/rl1-webtest"
while getopts "o:" opt; do
  case $opt in o) OUT="$OPTARG" ;; *) echo "Usage: $0 [-o DIR]"; exit 1 ;; esac
done
say()  { echo -e "\033[1;34m==>\033[0m $*"; }
fail() { echo -e "\033[31mERROR:\033[0m $*" >&2; exit 1; }
command -v node >/dev/null || fail "Node.js is needed"
CHROME=""
for c in google-chrome google-chrome-stable chromium chromium-browser; do
  command -v $c >/dev/null && { CHROME=$(command -v $c); break; }
done
[ -n "$CHROME" ] || fail "Chrome or Chromium is not installed"

# ---- test copy ---------------------------------------------------------------------
say "Building a test copy of the web panel"
log=$("$REPO/scripts/dev/test_webpanel.sh" -k -p "/passes" -o "$(mktemp -d)" 2>&1) || { echo "$log"; fail "test_webpanel.sh failed"; }
WORK=$(echo "$log" | sed -n 's/^Kept test copy: //p' | tail -1)
[ -d "$WORK/wp" ] || fail "No test copy"
PORT=""
trap '[ -n "$PHP_PID" ] && kill $PHP_PID 2>/dev/null; rm -rf "$WORK"' EXIT
SRV="$WORK/srv"

# ---- real imagery from the test CADU -------------------------------------------------
IMG="$WORK/real"; mkdir -p "$IMG"
if command -v satdump >/dev/null; then
  say "Decoding the test CADU with SatDump"
  satdump meteor_m2-x_lrpt cadu "$REPO/scripts/tools/verification_tool/test_files/meteordemod-input.cadu" \
    "$IMG/out" >"$IMG/satdump.log" 2>&1
  # SatDump's exit code isn't reliable: look for its output instead
  [ -f "$IMG/out/MSU-MR/msu_mr_rgb_AVHRR_221_False_Color_corrected.png" ] || echo "  (SatDump made no images - using the made-up ones)"
fi

say "Sample data"
python3 - "$WORK" "$IMG/out/MSU-MR" <<'EOF'
import os, sys, glob, sqlite3, time
work, real = sys.argv[1], sys.argv[2]
srv = os.path.join(work, 'srv')
db = sqlite3.connect(os.path.join(work, 'panel.db'))
now = int(time.time())

# two more days of passes, so the collapsed days show
for d in (1, 2):
    for k, (sat, el, az, dr) in enumerate([('METEOR-M2 3', 65, 20, 'Southbound'), ('METEOR-M2 4', 31, 190, 'Northbound'),
                                           ('METEOR-M2 3', 18, 340, 'Southbound'), ('METEOR-M2 4', 74, 170, 'Northbound')]):
        ps = now + 86400 * d + k * 5400 - 30000
        db.execute('INSERT OR IGNORE INTO predict_passes (sat_name, pass_start, pass_end, max_elev, is_active, '
                   'pass_start_azimuth, direction, azimuth_at_max) VALUES (?,?,?,?,1,?,?,100)',
                   (sat, ps, ps + 780, el, az, dr))
db.commit()

try:
    from PIL import Image
except ImportError:
    sys.exit(0)
src = {'AVHRR_221_False_Color_corrected': 'msu_mr_rgb_AVHRR_221_False_Color_corrected.png',
       'AVHRR_3a21_False_Color_corrected': 'msu_mr_rgb_AVHRR_3a21_False_Color_corrected.png'}
if not all(os.path.isfile(os.path.join(real, f)) for f in src.values()):
    sys.exit(0)
# the test CADU's first and last rows are noisy: keep the clean middle of the pass
pics = {}
for name, f in src.items():
    im = Image.open(os.path.join(real, f)).convert('RGB')
    w, h = im.size
    pics[name] = im.crop((0, int(h * 0.06), w, int(h * 0.80)))
ch = Image.open(os.path.join(real, 'MSU-MR-2.png')).convert('RGB')
w, h = ch.size
pics['MSU-MR_channel_2'] = ch.crop((0, int(h * 0.06), w, int(h * 0.80)))
caps = [r[0] for r in db.execute('SELECT file_path FROM decoded_passes WHERE sat_type < 3 ORDER BY pass_start DESC')]
for i, fp in enumerate(caps):
    for old in glob.glob(os.path.join(srv, 'images', fp + '-*.jpg')) + glob.glob(os.path.join(srv, 'images/thumb', fp + '-*.jpg')):
        if 'polar' not in old:
            os.remove(old)
    for name, im in pics.items():
        im.save(os.path.join(srv, 'images', '%s-%s.jpg' % (fp, name)), quality=85)
        t = im.copy(); t.thumbnail((300, 600)); t.save(os.path.join(srv, 'images/thumb', '%s-%s.jpg' % (fp, name)), quality=85)
    # thumbnails differ a little from card to card
    base = pics['AVHRR_221_False_Color_corrected' if i % 2 == 0 else 'AVHRR_3a21_False_Color_corrected']
    bw, bh = base.size
    top = int(bh * (0.1 + 0.12 * (i % 4)))
    t = base.crop((0, top, bw, top + bw)); t.thumbnail((300, 300))
    t.save(os.path.join(srv, 'images/thumb', fp + '-website-thumbnail.jpg'), quality=85)
    db.execute('UPDATE decoded_passes SET img_count = ? WHERE file_path = ?', (len(pics), fp))
db.commit()
EOF

# ---- serve ---------------------------------------------------------------------------
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$WORK/wp" && exec php -d date.timezone=Europe/Athens -S "127.0.0.1:$PORT" -t public router.php >"$WORK/php.log" 2>&1) &
PHP_PID=$!
sleep 1

# ---- photograph ------------------------------------------------------------------------
[ -d "$CACHE/node_modules/playwright-core" ] || (cd "$CACHE" && npm install --silent playwright-core) || fail "npm install playwright-core failed"
mkdir -p "$OUT"
rm -f "$OUT"/*.jpg
say "Taking screenshots into ${OUT#$REPO/}"
# the newest Meteor capture (the sample data's ISS captures come first)
METEOR_ID=$(sqlite3 "$WORK/panel.db" "SELECT id FROM decoded_passes WHERE sat_type < 3 ORDER BY pass_start DESC LIMIT 1" 2>/dev/null)
NODE_PATH="$CACHE/node_modules" node - "http://127.0.0.1:$PORT" "$OUT" "$CHROME" "${METEOR_ID:-3}" <<'EOF'
const { chromium } = require('playwright-core');
const [base, out, exe, METEOR_ID] = process.argv.slice(2);
(async () => {
  const browser = await chromium.launch({ executablePath: exe, args: ['--no-sandbox'] });
  async function page(opts) {
    const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1280, height: 860 },
      deviceScaleFactor: opts.scale || 1, colorScheme: opts.theme || 'dark', isMobile: !!opts.mobile, hasTouch: !!opts.mobile });
    if (opts.lang) { await ctx.addCookies([{ name: 'rl1-lang', value: opts.lang, url: base }]); }
    await ctx.addInitScript(t => { try { localStorage.setItem('rl1-theme', t); } catch (e) {} }, opts.theme || 'dark');
    const p = await ctx.newPage();
    await p.goto(base + opts.url);
    await p.waitForTimeout(opts.wait || 2500);
    if (opts.before) { await opts.before(p); }
    await p.screenshot({ path: `${out}/${opts.name}.jpg`, type: 'jpeg', quality: 82, fullPage: !!opts.full });
    console.log('  ' + opts.name);
    await ctx.close();
  }
  const map = async p => { await p.evaluate(() => document.querySelector('.pass-list').scrollIntoView()); };
  await page({ name: 'passes-dark', url: '/passes' });
  await page({ name: 'passes-light', url: '/passes', theme: 'light' });
  await page({ name: 'passes-days', url: '/passes', before: async p => { await p.evaluate(() => window.scrollTo(0, document.querySelector('.pass-list').getBoundingClientRect().top + window.scrollY - 80)); await p.waitForTimeout(300); } });
  await page({ name: 'passes-greek', url: '/passes', lang: 'gr' });
  await page({ name: 'language-menu', url: '/passes', before: async p => { await p.click('#lang-btn'); await p.waitForTimeout(400); } });
  await page({ name: 'passes-phone', url: '/passes', viewport: { width: 390, height: 844 }, scale: 2, mobile: true });
  await page({ name: 'satellites', url: '/satellite', viewport: { width: 1680, height: 900 }, wait: 4000, before: async p => {
    await p.click('.sat-pass >> nth=1'); await p.waitForTimeout(1200); } });
  await page({ name: 'satellites-phone', url: '/satellite', viewport: { width: 390, height: 844 }, scale: 2, mobile: true, wait: 4000 });
  await page({ name: 'map-fullscreen', url: '/satellite', before: async p => {
    await p.frameLocator('#meteor-map-frame').locator('#fullscreen').click(); await p.waitForTimeout(1500); } });
  await page({ name: 'captures', url: '/captures?page_no=1' });
  await page({ name: 'capture', url: '/captures/listImages?pass_id=' + METEOR_ID, full: true });
  await page({ name: 'image-viewer', url: '/captures/listImages?pass_id=' + METEOR_ID, before: async p => {
    await p.click('.cap-card >> nth=0'); await p.waitForTimeout(1200);
    await p.click('.iv [data-z="in"]'); await p.waitForTimeout(500); } });
  await page({ name: 'iss-aprs', url: '/captures/listImages?pass_id=2', full: true });
  await page({ name: 'meteor', url: '/meteor', viewport: { width: 1280, height: 1100 } });
  await page({ name: 'daily', url: '/daily', viewport: { width: 1400, height: 900 } });
  await page({ name: 'live-log', url: '/log', wait: 4000 });
  await page({ name: 'live-log-light', url: '/log', theme: 'light', wait: 4000 });
  await page({ name: 'admin-passes', url: '/admin/passes' });
  await page({ name: 'admin-captures', url: '/admin/captures?page_no=1' });
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
EOF
echo "Done: $(ls "$OUT"/*.jpg | wc -l) screenshots, $(du -sh "$OUT" | cut -f1)"
