#!/usr/bin/env python3
#
# Station settings for install_and_upgrade.sh.
#
# config/settings.yml (tracked in git) holds every setting with its default. The answers given
# during setup go to config/settings.local.yml (not tracked, mode 600), which overrides it, so a
# "git pull" never clashes with them. The install merges the two into config/.settings.merged.yml,
# which Ansible and the image annotation read.
#
#   settings.py summary        show the station's main settings (password hidden)
#   settings.py setup          ask the setup questions; Enter keeps the value shown
#   settings.py merged FILE    write settings.yml + settings.local.yml merged into FILE
#   settings.py ask-new        ask only the questions added since this station's setup (upgrades)
#   settings.py set KEY VALUE  set one setting in settings.local.yml

import getpass
import json
import os
import re
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = os.path.join(REPO, 'config', 'settings.yml')
LOCAL = os.path.join(REPO, 'config', 'settings.local.yml')
SCHEMA = os.path.join(REPO, 'config', 'settings_schema.json')

# (setting, question, kind); kind: text, number, integer, bool, choice, password, url, secret_url
# (a url that works like a password: shown as (set), '-' clears it).
# 'bias_tee' sets meteor_m2_3_enable_bias_tee and meteor_m2_4_enable_bias_tee together.
QUESTIONS = [
    ('station_title',           'Station name shown in the web panel',               'text'),
    ('latitude',                'Latitude in decimal degrees (north +)',             'number'),
    ('longitude',               'Longitude in decimal degrees (east +)',             'number'),
    ('altitude',                'Altitude in metres',                                'number'),
    ('ground_station_location', 'Location written on the images',                    'text'),
    ('antenna_information',     'Antenna written on the images',                     'text'),
    ('receiver_type',           'Receiver',                                          'receiver'),
    ('sdrplay_licence_accepted', 'Accept SDRplay\'s API licence',                     'licence'),
    ('storage',                 'The Pi runs from (sd = SD card, ssd = SSD)',          'choice'),
    ('meteor_m2_3_gain',        'Gain for METEOR-M2 3 in dB',                        'number'),
    ('meteor_m2_4_gain',        'Gain for METEOR-M2 4 in dB',                        'number'),
    ('bias_tee',                'Power an LNA through the antenna cable (bias tee)', 'bool'),
    ('iss_sstv',                'Also record the ISS\'s SSTV pictures (extra)',      'bool'),
    ('web_port',                'Web panel port',                                    'integer'),
    ('admin_username',          'Admin user name (for /admin/passes)',               'text'),
    ('admin_password',          'Admin password',                                    'password'),
    ('discord_webhook',         'Discord webhook URL to post passes to (- = none)',  'secret_url'),
    ('discord_site_url',        'Web panel address for links in the Discord posts',  'url'),
]

# receivers: setting -> (name in the menu, gain range or None (automatic gain), suggested gain,
# what the gain number means)
RECEIVERS = {
    'rtlsdr':                   ('RTL-SDR (RTL-SDR Blog V3/V4, Nooelec and other RTL2832U sticks)', (0, 49.6), 40, 'dB'),
    'airspy_mini':              ('Airspy Mini', (0, 21), 15, 'linearity gain step'),
    'airspy_r2':                ('Airspy R2', (0, 21), 15, 'linearity gain step'),
    'airspy_hf_plus_discovery': ('Airspy HF+ Discovery', None, None, ''),
    'hackrf':                   ('HackRF One', (0, 102), 56, 'dB, LNA first, then VGA'),
    'sdrplay':                  ('SDRplay RSP1/RSP1A/RSP1B/RSP2/RSPduo/RSPdx (installs SDRplay\'s API)', (20, 59), 40, 'IF gain'),
    'mirisdr':                  ('MSi2500/MSi001 receiver (MiriSDR, "SDRplay clones")', (0, 100), 60, 'dB, 10 dB steps'),
}
SDRPLAY_LICENCE = ('SDRplay\'s API is closed source. The install downloads it from sdrplay.com and\n'
                   '     installs it under SDRplay\'s licence (https://www.sdrplay.com/api/ - the text is\n'
                   '     also kept in /usr/local/share/doc/sdrplay_api/ after the install).')

# questions added after stations were first set up: an upgrade asks them once (ask-new)
NEW_QUESTIONS = ('storage', 'discord_webhook', 'discord_site_url', 'sdrplay_licence_accepted', 'iss_sstv')


def load(path):
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        return yaml.safe_load(f) or {}


def detect_storage():
    """'sd' or 'ssd' from the device the root file system is on, or None if unclear."""
    try:
        with open('/proc/mounts') as f:
            for line in f:
                dev, mnt = line.split()[:2]
                if mnt == '/':
                    name = os.path.basename(os.path.realpath(dev))
                    if name.startswith('mmcblk'):
                        return 'sd'
                    if name.startswith(('sd', 'nvme')):
                        return 'ssd'
    except OSError:
        pass
    return None


def merged():
    data = load(BASE)
    data.update(load(LOCAL))
    return data


def current(data, key):
    if key == 'bias_tee':
        return bool(data.get('meteor_m2_3_enable_bias_tee')) or bool(data.get('meteor_m2_4_enable_bias_tee'))
    return data.get(key)


def shown(key, kind, value):
    if kind in ('password', 'secret_url'):
        return '(set)' if value else '(not set)'
    if kind in ('bool', 'licence'):
        return 'yes' if value else 'no'
    if kind == 'receiver' and value in RECEIVERS:
        return RECEIVERS[value][0].split(' (')[0]
    return '' if value is None else str(value)


def skip(key, data):
    """Questions that don't apply to this station's receiver."""
    receiver = data.get('receiver_type')
    if key == 'sdrplay_licence_accepted':
        return receiver != 'sdrplay'
    # iss_sstv is asked with every receiver: the ISS records with an RTL-SDR, which can be a second
    # dongle beside an Airspy, HackRF or SDRplay (iss_sdr_device)
    if key in ('meteor_m2_3_gain', 'meteor_m2_4_gain'):
        return receiver in RECEIVERS and RECEIVERS[receiver][1] is None
    return False


def summary():
    data = merged()
    source = 'config/settings.local.yml over config/settings.yml' if os.path.isfile(LOCAL) else 'config/settings.yml'
    print('   Settings from ' + source + ':')
    for key, question, kind in QUESTIONS:
        if skip(key, data):
            continue
        print('     %-50s %s' % (question, shown(key, kind, current(data, key))))


def setup(only=None):
    try:
        tty = open('/dev/tty')
    except OSError:
        sys.exit('No terminal to ask the setup questions on - edit config/settings.local.yml instead')
    with open(SCHEMA) as f:
        props = json.load(f)['properties']
    data = merged()
    answers = load(LOCAL)

    def ask(prompt):
        sys.stdout.write(prompt)
        sys.stdout.flush()
        line = tty.readline()
        if not line:
            sys.exit('\nStopped')
        return line.strip()

    print('   Press Enter to keep the value in [brackets].')
    receiver_changed = False
    for key, question, kind in QUESTIONS:
        if only is not None and key not in only:
            continue
        now = current(data, key)
        if key == 'storage' and 'storage' not in answers:
            now = detect_storage() or now    # first time: suggest what the Pi actually boots from
        if key == 'discord_site_url' and not answers.get('discord_webhook', data.get('discord_webhook')):
            continue                         # only asked when there is a webhook
        view = dict(data, **answers)
        if skip(key, view):
            continue
        if key == 'receiver_type':
            names = list(RECEIVERS)
            print('   Receivers:')
            for i, r in enumerate(names, 1):
                print('     %d  %s' % (i, RECEIVERS[r][0]))
        if key in ('meteor_m2_3_gain', 'meteor_m2_4_gain'):
            receiver = view.get('receiver_type')
            lo, hi = RECEIVERS[receiver][1]
            question = '%s (%g-%g, %s)' % (question.replace(' in dB', ''), lo, hi, RECEIVERS[receiver][3])
            if receiver_changed or now is None or not lo <= float(now) <= hi:
                now = RECEIVERS[receiver][2]      # a new receiver: suggest its usual gain
        if key == 'sdrplay_licence_accepted':
            print('     ' + SDRPLAY_LICENCE)
        while True:
            if kind == 'password':
                sys.stdout.flush()
                hint = 'Enter keeps the current one' if now else 'needed'
                value = getpass.getpass('   %s (%s): ' % (question, hint), stream=sys.stdout)
                if not value and now:
                    value = now
                elif not value:
                    print('     A password is needed.')
                    continue
                elif len(value) < 8:
                    print('     Use at least 8 characters.')
                    continue
                elif getpass.getpass('   Again: ', stream=sys.stdout) != value:
                    print('     The two don\'t match.')
                    continue
                break
            if kind == 'choice':
                options = props[key]['enum']
                print('   %s: %s' % (question, ', '.join(options)))
            raw = ask('   %s [%s]: ' % (question, shown(key, kind, now)))
            if raw == '':
                value = now
                break
            if raw == '-' and kind in ('url', 'secret_url'):
                value = ''
                break
            try:
                if kind == 'number':
                    value = float(raw)
                    if key in ('meteor_m2_3_gain', 'meteor_m2_4_gain'):
                        lo, hi = RECEIVERS[view.get('receiver_type')][1]
                        if not lo <= value <= hi:
                            raise ValueError('between %g and %g' % (lo, hi))
                    if key == 'latitude' and not -90 <= value <= 90:
                        raise ValueError('between -90 and 90')
                    if key == 'longitude' and not -180 <= value <= 180:
                        raise ValueError('between -180 and 180')
                elif kind == 'integer':
                    value = int(raw)
                    if not 1 <= value <= 65534:
                        raise ValueError('between 1 and 65534')
                elif kind in ('bool', 'licence'):
                    if raw.lower() not in ('y', 'yes', 'n', 'no'):
                        raise ValueError('yes or no')
                    value = raw.lower().startswith('y')
                elif kind == 'receiver':
                    names = list(RECEIVERS)
                    if raw.isdigit() and 1 <= int(raw) <= len(names):
                        value = names[int(raw) - 1]
                    elif raw in names:
                        value = raw
                    else:
                        raise ValueError('a number from 1 to %d' % len(names))
                elif kind in ('url', 'secret_url'):
                    if not re.match(props[key]['pattern'], raw):
                        raise ValueError('a webhook URL from Discord (https://discord.com/api/webhooks/...)'
                                         if kind == 'secret_url' else 'an address like http://example.org:8080')
                    value = raw
                elif kind == 'choice':
                    if raw not in props[key]['enum']:
                        raise ValueError('one of: ' + ', '.join(props[key]['enum']))
                    value = raw
                else:
                    value = raw
                break
            except ValueError as e:
                print('     Please give %s.' % (e if str(e) and 'could not convert' not in str(e)
                                                  and 'invalid literal' not in str(e) else 'a number'))
        if key == 'receiver_type':
            receiver_changed = value != data.get('receiver_type')
        if key == 'sdrplay_licence_accepted' and not value:
            print('     Without it the install stops at the SDRplay step: run it again and accept,\n'
                  '     or pick another receiver.')
        if key == 'bias_tee':
            answers['meteor_m2_3_enable_bias_tee'] = bool(value)
            answers['meteor_m2_4_enable_bias_tee'] = bool(value)
        else:
            answers[key] = value

    save_local(answers)
    print('   Saved to config/settings.local.yml')


def save_local(answers):
    old = os.umask(0o077)
    try:
        with open(LOCAL, 'w') as f:
            f.write('# This station\'s answers to the setup questions (install_and_upgrade.sh).\n'
                    '# They override config/settings.yml. Not tracked by git; keep it private.\n')
            yaml.safe_dump(answers, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    finally:
        os.umask(old)
    os.chmod(LOCAL, 0o600)


def set_value(key, raw):
    """Set one setting in settings.local.yml (a yes/no setting takes on/off, yes/no, true/false)."""
    with open(SCHEMA) as f:
        prop = json.load(f)['properties'].get(key)
    if prop is None:
        sys.exit('Unknown setting: ' + key)
    kind = prop.get('type')
    if kind == 'string':
        value = str(raw)                  # as typed: '#3a2600' would read as a YAML comment
    else:
        value = yaml.safe_load(raw)
    if kind == 'boolean':
        if str(raw).lower() not in ('on', 'off', 'yes', 'no', 'true', 'false'):
            sys.exit('%s takes on or off' % key)
        value = str(raw).lower() in ('on', 'yes', 'true')
    elif kind in ('number', 'integer'):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            sys.exit('%s takes a number' % key)
        if value < prop.get('minimum', value) or value > prop.get('maximum', value):
            sys.exit('%s takes %s to %s' % (key, prop.get('minimum'), prop.get('maximum')))
    if 'enum' in prop and value not in prop['enum']:
        sys.exit('%s takes one of: %s' % (key, ', '.join(str(v) for v in prop['enum'])))
    if prop.get('pattern') and not re.search(prop['pattern'], str(value)):
        sys.exit('%s: %r is not valid' % (key, value))
    answers = load(LOCAL)
    answers[key] = value
    save_local(answers)


def write_merged(path):
    old = os.umask(0o077)
    try:
        with open(path, 'w') as f:
            f.write('# Made by install_and_upgrade.sh from config/settings.yml and config/settings.local.yml.\n'
                    '# Do not edit: change those two files and run the install again.\n')
            yaml.safe_dump(merged(), f, default_flow_style=False, sort_keys=False, allow_unicode=True,
                           explicit_start=True, explicit_end=True)
    finally:
        os.umask(old)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'summary':
        summary()
    elif cmd == 'setup':
        setup()
    elif cmd == 'ask-new':
        local = load(LOCAL)
        missing = [k for k in NEW_QUESTIONS if k not in local]
        if 'discord_webhook' not in missing and not merged().get('discord_webhook'):
            missing = [k for k in missing if k != 'discord_site_url']    # asked only with a webhook
        missing = [k for k in missing if not skip(k, merged())]           # not for this receiver
        if missing:
            print('   A new question since this station was set up:' if len(missing) == 1
                  else '   New questions since this station was set up:')
            setup(missing)
    elif cmd == 'set' and len(sys.argv) == 4:
        set_value(sys.argv[2], sys.argv[3])
    elif cmd == 'merged' and len(sys.argv) == 3:
        write_merged(sys.argv[2])
    else:
        sys.exit(__doc__ if __doc__ else 'Usage: settings.py summary | setup | merged FILE')
