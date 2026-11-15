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

import getpass
import json
import os
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = os.path.join(REPO, 'config', 'settings.yml')
LOCAL = os.path.join(REPO, 'config', 'settings.local.yml')
SCHEMA = os.path.join(REPO, 'config', 'settings_schema.json')

# (setting, question, kind); kind: text, number, integer, bool, choice, password.
# 'bias_tee' sets meteor_m2_3_enable_bias_tee and meteor_m2_4_enable_bias_tee together.
QUESTIONS = [
    ('station_title',           'Station name shown in the web panel',               'text'),
    ('latitude',                'Latitude in decimal degrees (north +)',             'number'),
    ('longitude',               'Longitude in decimal degrees (east +)',             'number'),
    ('altitude',                'Altitude in metres',                                'number'),
    ('ground_station_location', 'Location written on the images',                    'text'),
    ('antenna_information',     'Antenna written on the images',                     'text'),
    ('receiver_type',           'Receiver',                                          'choice'),
    ('storage',                 'The Pi runs from (sd = SD card, ssd = SSD)',          'choice'),
    ('meteor_m2_3_gain',        'Gain for METEOR-M2 3 in dB',                        'number'),
    ('meteor_m2_4_gain',        'Gain for METEOR-M2 4 in dB',                        'number'),
    ('bias_tee',                'Power an LNA through the antenna cable (bias tee)', 'bool'),
    ('web_port',                'Web panel port',                                    'integer'),
    ('admin_username',          'Admin user name (for /admin/passes)',               'text'),
    ('admin_password',          'Admin password',                                    'password'),
]

# questions added after stations were first set up: an upgrade asks them once (ask-new)
NEW_QUESTIONS = ('storage',)


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
    if kind == 'password':
        return '(set)' if value else '(not set)'
    if kind == 'bool':
        return 'yes' if value else 'no'
    return '' if value is None else str(value)


def summary():
    data = merged()
    source = 'config/settings.local.yml over config/settings.yml' if os.path.isfile(LOCAL) else 'config/settings.yml'
    print('   Settings from ' + source + ':')
    for key, question, kind in QUESTIONS:
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
    for key, question, kind in QUESTIONS:
        if only is not None and key not in only:
            continue
        now = current(data, key)
        if key == 'storage' and 'storage' not in answers:
            now = detect_storage() or now    # first time: suggest what the Pi actually boots from
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
            try:
                if kind == 'number':
                    value = float(raw)
                    if key == 'latitude' and not -90 <= value <= 90:
                        raise ValueError('between -90 and 90')
                    if key == 'longitude' and not -180 <= value <= 180:
                        raise ValueError('between -180 and 180')
                elif kind == 'integer':
                    value = int(raw)
                    if not 1 <= value <= 65534:
                        raise ValueError('between 1 and 65534')
                elif kind == 'bool':
                    if raw.lower() not in ('y', 'yes', 'n', 'no'):
                        raise ValueError('yes or no')
                    value = raw.lower().startswith('y')
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
        if key == 'bias_tee':
            answers['meteor_m2_3_enable_bias_tee'] = bool(value)
            answers['meteor_m2_4_enable_bias_tee'] = bool(value)
        else:
            answers[key] = value

    old = os.umask(0o077)
    try:
        with open(LOCAL, 'w') as f:
            f.write('# This station\'s answers to the setup questions (install_and_upgrade.sh).\n'
                    '# They override config/settings.yml. Not tracked by git; keep it private.\n')
            yaml.safe_dump(answers, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    finally:
        os.umask(old)
    os.chmod(LOCAL, 0o600)
    print('   Saved to config/settings.local.yml')


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
        missing = [k for k in NEW_QUESTIONS if k not in load(LOCAL)]
        if missing:
            print('   A new question since this station was set up:' if len(missing) == 1
                  else '   New questions since this station was set up:')
            setup(missing)
    elif cmd == 'merged' and len(sys.argv) == 3:
        write_merged(sys.argv[2])
    else:
        sys.exit(__doc__ if __doc__ else 'Usage: settings.py summary | setup | merged FILE')
