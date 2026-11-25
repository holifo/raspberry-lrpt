#!/usr/bin/env python3
"""Band scans for Admin > Band scan: rtl_power sweeps a band for a while on one of the station's
RTL-SDRs, and the result is drawn as a waterfall and a spectrum. Run through scripts/band_scan.sh,
which loads the station's settings into the environment.

  band_scan.py status            JSON: the presets, durations, dongles, the scan running and the
                                 scans kept
  band_scan.py start  < JSON     {"preset": "...", "minutes": N, "device": INDEX}: start a scan
  band_scan.py stop              stop the scan running (what it recorded is still drawn)
  band_scan.py delete < JSON     {"id": "..."}: delete a kept scan
  band_scan.py yield ROLE        stop a scan on the dongle a pass needs (ROLE meteor or iss);
                                 receive_meteor.sh and receive_iss.sh call it, so passes come first
  band_scan.py run ID            (internal) record and draw one scan
  band_scan.py render CSV OUT_PREFIX PRESET [TITLE]
                                 draw a CSV again (tests)

The pictures and their data are kept in SCAN_DIR (/srv/scans next to /srv/images), which the web
server does not serve: the admin page reads them, behind the admin login. Every answer is one JSON
line. A scan is refused while it would overlap a scheduled pass on the same dongle.
"""
import datetime
import glob
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time

HOME = os.environ.get('LRPT_HOME', os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
IMAGE_OUTPUT = os.environ.get('IMAGE_OUTPUT', '/srv/images')
SCAN_DIR = os.environ.get('SCAN_DIR', os.path.join(os.path.dirname(IMAGE_OUTPUT.rstrip('/')), 'scans'))
STATE = os.path.join(HOME, 'tmp', 'band-scan.json')
DB = os.environ.get('DB_FILE', os.path.join(HOME, 'db', 'panel.db'))
KEEP = 20                                   # scans kept; older ones are deleted
RTL_POWER = os.environ.get('RTL_POWER', 'rtl_power')

# The five presets: what a weather and ISS station most often needs to look at.
# start/stop in MHz, bin in Hz, wide = many tuner hops (rtl_power covers ~2 MHz per hop).
PRESETS = [
    {'id': 'meteor', 'name': 'Meteor band', 'start': 136.9, 'stop': 138.1, 'bin': 600, 'wide': False,
     'what': 'METEOR-M2 LRPT at 137.900 and 137.100 MHz: check the signal, its width and any interference next to it',
     'marks': [(137.1, '137.100'), (137.9, 'Meteor 137.900')]},
    {'id': '2m', 'name': '2 m amateur band', 'start': 144.0, 'stop': 146.0, 'bin': 1000, 'wide': False,
     'what': 'The ISS on 2 m (145.800 voice/SSTV, 145.825 APRS) and other amateur satellites',
     'marks': [(145.8, 'ISS 145.800'), (145.825, 'APRS 145.825')]},
    {'id': '70cm', 'name': '70 cm satellite band', 'start': 435.0, 'stop': 438.0, 'bin': 1000, 'wide': False,
     'what': 'The ISS on 70 cm (437.550 SSTV, 437.800 repeater, 437.825 APRS) and CubeSats',
     'marks': [(437.55, 'SSTV 437.550'), (437.8, '437.800'), (437.825, 'APRS 437.825')]},
    {'id': 'vhf', 'name': 'VHF overview', 'start': 108.0, 'stop': 175.0, 'bin': 25000, 'wide': True,
     'what': 'Everything from 108 to 175 MHz: airband, weather satellites, 2 m, marine and AIS; find what disturbs reception',
     'marks': [(121.5, '121.5'), (137.9, 'Meteor'), (145.8, 'ISS'), (156.8, 'Marine 16'), (162.0, 'AIS')]},
    {'id': 'fm', 'name': 'FM broadcast band', 'start': 87.5, 'stop': 108.0, 'bin': 10000, 'wide': True,
     'what': 'Strong FM stations, the most common cause of an overloaded dongle and missed passes',
     'marks': []},
]
MINUTES = [2, 5, 10, 30, 60]


def env(name, default=''):
    return os.environ.get(name, default)


def out(obj, code=0):
    print(json.dumps(obj, ensure_ascii=False))
    sys.exit(code)


def preset(pid):
    return next((p for p in PRESETS if p['id'] == pid), None)


def roles():
    """The RTL-SDRs with their roles (meteor, iss, meteor+iss, spare), as the Live log shows them."""
    meteor = env('METEOR_M2_3_SDR_DEVICE_ID', '0') if env('USE_DEVICE_STRING') == 'true' else '0'
    try:
        r = subprocess.run([sys.executable, os.path.join(HOME, 'scripts', 'tools', 'rtlsdr_list.py'), 'roles',
                            env('ISS_SDR_DEVICE'), meteor or '0', env('RECEIVER_TYPE', 'rtlsdr'), env('ISS_SSTV', 'false')],
                           capture_output=True, text=True, timeout=20)
        return json.loads(r.stdout or '[]')
    except Exception:
        return []


def running():
    """The scan running now, or None (a stale state file is removed)."""
    try:
        with open(STATE) as f:
            st = json.load(f)
    except (OSError, ValueError):
        return None
    try:
        os.kill(int(st.get('runner', 0)), 0)
        return st
    except (OSError, ValueError):
        try:
            os.remove(STATE)
        except OSError:
            pass
        return None


def conflicts(role, start, end):
    """Scheduled passes on this dongle between start and end (epoch), as 'sat hh:mm' texts."""
    sats = []
    if 'meteor' in role:
        sats.append("sat_name LIKE 'METEOR%'")
    if 'iss' in role:
        sats.append("sat_name = 'ISS'")
    if not sats:
        return []
    try:
        con = sqlite3.connect('file:' + DB + '?mode=ro', uri=True, timeout=5)
        rows = con.execute('SELECT sat_name, pass_start FROM predict_passes WHERE (is_active = 1 OR is_active IS NULL) '
                           'AND pass_start < ? AND pass_end > ? AND (' + ' OR '.join(sats) + ') ORDER BY pass_start',
                           (end + 60, start - 60)).fetchall()
        con.close()
    except sqlite3.Error:
        return []
    return ['{} {}'.format(s, datetime.datetime.fromtimestamp(int(t)).strftime('%H:%M')) for s, t in rows]


def recording(role):
    pats = []
    if 'meteor' in role:
        pats.append(r'/receive_meteor\.sh ')
    if 'iss' in role:
        pats.append(r'/receive_iss\.sh ')
    for pat in pats:
        if subprocess.run(['pgrep', '-f', '^(/usr)?/bin/bash [^ ]*' + pat], capture_output=True).returncode == 0:
            return True
    return False


def kept():
    scans = []
    for path in sorted(glob.glob(os.path.join(SCAN_DIR, '*.json')), reverse=True):
        try:
            with open(path) as f:
                scans.append(json.load(f))
        except (OSError, ValueError):
            pass
    return scans


def prune():
    for old in kept()[KEEP:]:
        remove(old.get('id', ''))


def remove(sid):
    if not sid or '/' in sid or sid.startswith('.'):
        return False
    gone = False
    for path in glob.glob(os.path.join(SCAN_DIR, sid + '*')):
        try:
            os.remove(path)
            gone = True
        except OSError:
            pass
    return gone


def status():
    devs = roles()
    now = time.time()
    for d in devs:
        d['next_pass'] = (conflicts(d['role'], now, now + 3600) or [''])[0]
    out({'ok': True, 'running': running(), 'presets': [{k: p[k] for k in ('id', 'name', 'start', 'stop', 'bin', 'what')}
                                                         for p in PRESETS],
         'minutes': MINUTES, 'devices': devs, 'scans': kept()})


def gain_for(role):
    if role == 'iss':
        return env('ISS_SSTV_GAIN', '40')
    return env('METEOR_M2_3_GAIN', '30')


def start():
    try:
        req = json.loads(sys.stdin.read() or '{}')
    except ValueError:
        out({'ok': False, 'error': 'bad_request'}, 1)
    p = preset(str(req.get('preset', '')))
    minutes = req.get('minutes')
    try:
        minutes = int(minutes)
        index = int(req.get('device'))
    except (TypeError, ValueError):
        out({'ok': False, 'error': 'bad_request'}, 1)
    if not p or minutes not in MINUTES:
        out({'ok': False, 'error': 'bad_request'}, 1)
    if running():
        out({'ok': False, 'error': 'running'}, 2)
    dev = next((d for d in roles() if int(d.get('index', -1)) == index), None)
    if not dev:
        out({'ok': False, 'error': 'no_device'}, 1)
    if recording(dev['role']):
        out({'ok': False, 'error': 'recording'}, 2)
    now = time.time()
    clash = conflicts(dev['role'], now, now + minutes * 60)
    if clash:
        out({'ok': False, 'error': 'pass', 'pass': clash[0]}, 2)
    os.makedirs(SCAN_DIR, exist_ok=True)
    try:
        subprocess.run(['chgrp', 'www-data', SCAN_DIR], capture_output=True)
        os.chmod(SCAN_DIR, 0o2750)
    except OSError:
        pass
    sid = datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + p['id']
    info = {'id': sid, 'preset': p['id'], 'name': p['name'], 'start_mhz': p['start'], 'stop_mhz': p['stop'],
            'minutes': minutes, 'device': index, 'serial': dev.get('serial') or '', 'model': dev.get('model') or '',
            'role': dev['role'], 'gain': gain_for(dev['role']), 'started': int(now), 'ends': int(now + minutes * 60)}
    with open(os.path.join(SCAN_DIR, sid + '.req'), 'w') as f:
        json.dump(info, f)
    # the runner goes on after this command (and the web request) ends
    runner = subprocess.Popen([sys.executable, os.path.abspath(__file__), 'run', sid], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=open(env('LRPT_LOG', os.devnull), 'a'),
                              start_new_session=True)
    info['runner'] = runner.pid
    write_state(info)
    out({'ok': True, 'scan': info})


def write_state(info):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + '.part'
    with open(tmp, 'w') as f:
        json.dump(info, f)
    os.replace(tmp, STATE)


def log(msg, level='INFO'):
    try:
        with open(env('LRPT_LOG', os.devnull), 'a') as f:
            f.write('{} band_scan {} : {}\n'.format(datetime.datetime.now().strftime('%d-%m-%Y %H:%M'), level, msg))
    except OSError:
        pass


def run(sid):
    req = os.path.join(SCAN_DIR, sid + '.req')
    with open(req) as f:
        info = json.load(f)
    os.remove(req)
    p = preset(info['preset'])
    secs = info['minutes'] * 60
    interval = max(5, round(secs / 600)) if p['wide'] else max(1, round(secs / 900))
    csv = os.path.join(SCAN_DIR, sid + '.csv')
    cmd = [RTL_POWER, '-d', str(info['device']), '-f', '{}M:{}M:{}'.format(p['start'], p['stop'], p['bin']),
           '-i', str(interval), '-e', '{}s'.format(secs), '-g', str(info['gain'])]
    if p['wide']:
        cmd += ['-c', '25%']
    if info['role'] == 'iss' and env('ISS_BIAS_TEE') == 'true':
        cmd += ['-T']
    elif 'meteor' in info['role'] and env('METEOR_M2_3_ENABLE_BIAS_TEE') == '-T':
        cmd += ['-T']
    cmd.append(csv)
    log('Band scan {} ({}-{} MHz) for {} min on RTL-SDR #{}'.format(p['name'], p['start'], p['stop'], info['minutes'],
                                                                     info['device']))
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    info['runner'] = os.getpid()
    info['rtl_power'] = proc.pid
    write_state(info)
    signal.signal(signal.SIGTERM, lambda *a: proc.terminate())
    try:
        _, err = proc.communicate(timeout=secs + 120)
    except subprocess.TimeoutExpired:
        proc.terminate()
        _, err = proc.communicate()
    info['stopped_early'] = os.path.exists(STATE + '.stop')
    info['finished'] = int(time.time())
    try:
        result = render(csv, os.path.join(SCAN_DIR, sid), p, info)
        info.update(result)
        log('Band scan {} done: {} rows'.format(sid, result.get('rows', 0)))
    except Exception as e:
        info['error'] = 'no_data'
        tail = (err or '').strip().splitlines()[-3:]
        info['detail'] = ' | '.join(tail)[:300] or str(e)[:300]
        log('Band scan {} failed: {}'.format(sid, info['detail']), 'WARN')
    for path in (csv, STATE + '.stop'):
        try:
            os.remove(path)
        except OSError:
            pass
    with open(os.path.join(SCAN_DIR, sid + '.json'), 'w') as f:
        json.dump(info, f)
    for path in glob.glob(os.path.join(SCAN_DIR, sid + '*')):
        try:
            os.chmod(path, 0o640)
        except OSError:
            pass
    try:
        os.remove(STATE)
    except OSError:
        pass
    prune()


def stop(role=None):
    st = running()
    if not st or (role and role not in st.get('role', '')):
        out({'ok': True, 'stopped': False})
    open(STATE + '.stop', 'w').close()
    for key in ('rtl_power', 'runner'):
        try:
            os.kill(int(st.get(key, 0)), signal.SIGTERM)
            break
        except (OSError, ValueError):
            pass
    if role:
        log('Band scan {} stopped: a {} pass needs the dongle'.format(st.get('id'), role))
    out({'ok': True, 'stopped': True})


def read_csv(path):
    """rtl_power's CSV: each line is one hop (date, time, Hz low, Hz high, Hz step, samples, dB...);
    the hops of one sweep share its time. Returns (times, Hz of each point, rows x points dB)."""
    import numpy as np
    sweeps = {}
    order = []
    with open(path) as f:
        for line in f:
            parts = [x.strip() for x in line.split(',')]
            if len(parts) < 7:
                continue
            try:
                t = time.mktime(time.strptime(parts[0] + ' ' + parts[1], '%Y-%m-%d %H:%M:%S'))
                lo, step = float(parts[2]), float(parts[4])
                vals = [float(v) for v in parts[6:]]
            except ValueError:
                continue
            if t not in sweeps:
                sweeps[t] = {}
                order.append(t)
            sweeps[t][lo] = (step, vals)
    if not order:
        raise ValueError('no data')
    # the frequency axis from the sweep with the most hops (a stopped scan's last sweep can be partial)
    full = max(order, key=lambda t: len(sweeps[t]))
    axis = []
    for lo in sorted(sweeps[full]):
        step, vals = sweeps[full][lo]
        axis += [lo + (i + 0.5) * step for i in range(len(vals))]
    axis = np.array(axis)
    rows = []
    times = []
    for t in order:
        if len(sweeps[t]) < len(sweeps[full]):
            continue
        row = []
        for lo in sorted(sweeps[full]):
            step, n = sweeps[full][lo][0], len(sweeps[full][lo][1])
            vals = sweeps[t].get(lo, (step, [np.nan] * n))[1]
            row += (list(vals) + [np.nan] * n)[:n]
        rows.append(row)
        times.append(t)
    return np.array(times), axis, np.array(rows, dtype=np.float32)


def peaks(axis, data, p, count=8):
    """The strongest signals: runs of points whose maximum over the scan stands at least 6 dB above
    the peak-hold's floor; each run is one signal (levels given above the band's median noise), reported at its strongest point with
    its width, strongest first."""
    import numpy as np
    mx = np.nanmax(data, axis=0)
    noise = float(np.nanmedian(data))
    # 6 dB above the peak-hold's own floor (the noise's peaks rise a few dB over a long scan)
    above = mx - float(np.nanmedian(mx)) >= 6
    step = float(axis[1] - axis[0]) if len(axis) > 1 else 1.0
    gap = max(1, int(round(5e3 / step)))            # runs closer than 5 kHz are one signal
    runs, i = [], 0
    while i < len(mx):
        if not above[i]:
            i += 1
            continue
        j, last = i, i
        while j < len(mx) and j - last <= gap:
            if above[j]:
                last = j
            j += 1
        runs.append((i, last))
        i = last + 1
    found = []
    for a, b in runs:
        k = a + int(np.nanargmax(mx[a:b + 1]))
        name = ''
        for f, label in p['marks']:
            if axis[a] / 1e6 - 0.01 <= f <= axis[b] / 1e6 + 0.01:
                name = label
        found.append({'mhz': round(float(axis[k]) / 1e6, 4), 'db': round(float(mx[k] - noise), 1),
                      'avg_db': round(float(np.nanmean(data[:, k]) - noise), 1),
                      'khz': round((b - a + 1) * step / 1e3, 1), 'name': name})
    found.sort(key=lambda x: -x['db'])
    return found[:count], noise


def render(csv, prefix, p, info):
    import numpy as np
    sys.path.insert(0, os.path.join(HOME, 'scripts', 'image_processors'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import spectrogram as sg
    times, axis, data = read_csv(csv)
    mhz = axis / 1e6
    when = datetime.datetime.fromtimestamp(float(times[0])).strftime('%d/%m/%Y %H:%M')
    title = '{}  ·  {:.3f}-{:.3f} MHz  ·  {}'.format(p['name'], mhz[0], mhz[-1], when)
    step = float(axis[1] - axis[0]) if len(axis) > 1 else float(p['bin'])
    every = float(np.median(np.diff(times))) if len(times) > 1 else 0
    xscale = max(1, 1400 // max(1, len(axis)))
    size = sg.full_waterfall(data, mhz, 'Frequency (MHz)  ·  {:.0f} Hz a point  ·  a row every {:.0f} s  ·  gain {} dB'.format(
        step, every, info.get('gain', '?')), lambda v: '{:.3f}'.format(v).rstrip('0').rstrip('.'), times,
        prefix + '.jpg', title, '#4fd1c5', marks=p['marks'], xscale=xscale)
    found, noise = peaks(axis, data, p)
    # the spectrum: average and peak over the scan
    fig = plt.figure(figsize=(9, 3.4), dpi=150)
    fig.patch.set_facecolor(sg.BG)
    ax = fig.add_axes([0.07, 0.16, 0.9, 0.72])
    ax.set_facecolor(sg.BG)
    ax.plot(mhz, np.nanmax(data, axis=0), color='#f2b33d', lw=0.7, label='peak')
    ax.plot(mhz, np.nanmean(data, axis=0), color='#4fd1c5', lw=0.9, label='average')
    for f, label in p['marks']:
        if mhz[0] <= f <= mhz[-1]:
            ax.axvline(f, color=sg.FAINT, lw=0.8, ls='--')
    for pk in found[:6]:
        ax.annotate('{:.3f}'.format(pk['mhz']), (pk['mhz'], noise + pk['db']), color=sg.TEXT, fontsize=7,
                    ha='center', va='bottom', xytext=(0, 3), textcoords='offset points')
    ax.set_xlim(mhz[0], mhz[-1])
    ax.tick_params(colors=sg.DIM, labelsize=8)
    for s in ax.spines.values():
        s.set_color('#22344d')
    ax.set_xlabel('MHz', color=sg.DIM, fontsize=8)
    ax.set_ylabel('dB', color=sg.DIM, fontsize=8)
    ax.grid(color='#22344d', lw=0.5)
    ax.legend(loc='upper right', fontsize=7, facecolor=sg.BG, edgecolor='#22344d', labelcolor=sg.TEXT)
    fig.text(0.07, 0.94, title, color=sg.TEXT, fontsize=9, fontweight='bold')
    fig.savefig(prefix + '-spectrum.png', facecolor=sg.BG)
    plt.close(fig)
    from PIL import Image
    im = Image.open(prefix + '.jpg')
    im.thumbnail((1200, 800))
    im.save(prefix + '-thumb.jpg', quality=82)
    return {'rows': int(len(times)), 'points': int(len(axis)), 'hz_per_point': round(step, 1),
            'seconds_per_row': round(every, 1), 'size': list(size), 'noise_db': round(noise, 1), 'peaks': found,
            'first': int(times[0]), 'last': int(times[-1])}


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'status':
        status()
    elif cmd == 'start':
        start()
    elif cmd == 'stop':
        stop()
    elif cmd == 'yield' and len(sys.argv) == 3 and sys.argv[2] in ('meteor', 'iss'):
        stop(sys.argv[2])
    elif cmd == 'delete':
        try:
            sid = str(json.loads(sys.stdin.read() or '{}').get('id', ''))
        except ValueError:
            sid = ''
        out({'ok': remove(sid)})
    elif cmd == 'run' and len(sys.argv) == 3:
        run(sys.argv[2])
    elif cmd == 'render' and len(sys.argv) >= 5:
        p = preset(sys.argv[4])
        print(json.dumps(render(sys.argv[2], sys.argv[3], p, {'gain': '?'})))
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == '__main__':
    main()
