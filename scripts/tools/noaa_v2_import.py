#!/usr/bin/env python3
#
# Helpers for upgrade_from_noaa_v2.sh: reads a raspberry-noaa-v2 station's settings and database.
#
#   noaa_v2_import.py settings OLD_SETTINGS.yml LOCAL.yml   write the old station's answers (location,
#                                                            receiver, gains, web login, ...) to
#                                                            Raspberry-LRPT's settings.local.yml
#   noaa_v2_import.py bases DB meteor|other                 print the image file bases of the Meteor
#                                                            or the other (NOAA) captures, one a line
#   noaa_v2_import.py prune DB                              delete everything that isn't Meteor from
#                                                            the database; prints what it removed
#
# Only settings Raspberry-LRPT knows are carried over, and only values its schema accepts; the
# install's setup questions show them for review ("Keep these settings?").

import json
import os
import re
import sqlite3
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCHEMA = os.path.join(REPO, 'config', 'settings_schema.json')

# raspberry-noaa-v2 setting -> Raspberry-LRPT setting (same meaning)
CARRY = [
    'latitude', 'longitude', 'altitude', 'ground_station_location', 'antenna_information',
    'receiver_type', 'use_device_string', 'lang_setting', 'ntp_server',
    'meteor_m2_3_gain', 'meteor_m2_4_gain',
    'meteor_m2_3_enable_bias_tee', 'meteor_m2_4_enable_bias_tee',
    'meteor_m2_3_freq_offset', 'meteor_m2_4_freq_offset',
    'meteor_m2_3_sdr_device_id', 'meteor_m2_4_sdr_device_id',
    'meteor_m2_3_80k_interleaving', 'meteor_m2_4_80k_interleaving',
    'days_to_schedule_passes', 'delete_older_than_n',
    'web_server_name', 'web_port', 'enable_tls', 'web_tls_port',
    'admin_username', 'admin_password',
]

# the example webhook in raspberry-noaa-v2's own settings.yml: never carried over
UPSTREAM_EXAMPLE_WEBHOOK = '1135901731918717068'


def schema_ok(props, key, value):
    """True when the value fits Raspberry-LRPT's schema for that setting."""
    p = props.get(key)
    if p is None:
        return False
    kinds = {'string': str, 'boolean': bool, 'integer': int, 'number': (int, float)}
    t = p.get('type')
    if t in kinds:
        if t in ('integer', 'number') and isinstance(value, bool):
            return False
        if not isinstance(value, kinds[t]):
            return False
    if 'enum' in p and value not in p['enum']:
        return False
    if 'pattern' in p and isinstance(value, str) and not re.match(p['pattern'], value):
        return False
    for bound, test in (('minimum', lambda v, b: v >= b), ('maximum', lambda v, b: v <= b)):
        if bound in p and isinstance(value, (int, float)) and not test(value, p[bound]):
            return False
    return True


def settings(old_path, local_path):
    with open(old_path) as f:
        old = yaml.safe_load(f) or {}
    with open(SCHEMA) as f:
        props = json.load(f)['properties']
    answers = {}
    if os.path.isfile(local_path):
        with open(local_path) as f:
            answers = yaml.safe_load(f) or {}
    taken, skipped = [], []
    for key in CARRY:
        if key not in old or key in answers or key not in props:
            continue
        value = old[key]
        if key == 'admin_password' and (not isinstance(value, str) or len(value) < 8):
            skipped.append(key + ' (shorter than 8 characters: the setup asks for a new one)')
            continue
        if key == 'ntp_server' and not value:
            continue
        if schema_ok(props, key, value):
            answers[key] = value
            taken.append(key)
        else:
            skipped.append('%s (%r is not valid here)' % (key, value))
    # a name for the station from the old location text
    if 'station_title' not in answers and old.get('ground_station_location'):
        answers['station_title'] = str(old['ground_station_location'])
        taken.append('station_title (from ground_station_location)')
    # the old Meteor Discord webhook, if Discord posts were on and it isn't upstream's example
    hook = old.get('discord_meteor_webhook_url') or ''
    if (old.get('enable_discord_push') and 'discord_webhook' not in answers and UPSTREAM_EXAMPLE_WEBHOOK not in hook
            and schema_ok(props, 'discord_webhook', hook)):
        answers['discord_webhook'] = hook
        taken.append('discord_webhook (from discord_meteor_webhook_url)')
    old_umask = os.umask(0o077)
    try:
        with open(local_path, 'w') as f:
            f.write('# This station\'s answers to the setup questions (install_and_upgrade.sh).\n'
                    '# They override config/settings.yml. Not tracked by git; keep it private.\n'
                    '# Started from the raspberry-noaa-v2 settings by upgrade_from_noaa_v2.sh.\n')
            yaml.safe_dump(answers, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    finally:
        os.umask(old_umask)
    os.chmod(local_path, 0o600)
    for k in taken:
        print('  kept     ' + k)
    for k in skipped:
        print('  skipped  ' + k)


def bases(db, which):
    con = sqlite3.connect(db)
    cond = 'sat_type = 0' if which == 'meteor' else 'sat_type IS NOT 0'
    for (base,) in con.execute('SELECT file_path FROM decoded_passes WHERE %s AND file_path IS NOT NULL' % cond):
        if base and '/' not in base:
            print(base)


def prune(db):
    con = sqlite3.connect(db)
    other = con.execute('SELECT COUNT(*) FROM decoded_passes WHERE sat_type IS NOT 0').fetchone()[0]
    kept = con.execute('SELECT COUNT(*) FROM decoded_passes WHERE sat_type = 0').fetchone()[0]
    con.execute('DELETE FROM decoded_passes WHERE sat_type IS NOT 0')
    passes = con.execute("DELETE FROM predict_passes WHERE sat_name NOT LIKE 'METEOR%'").rowcount
    con.commit()
    con.execute('VACUUM')
    print('%d %d %d' % (kept, other, passes))


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == 'settings':
        settings(a[1], a[2])
    elif len(a) == 3 and a[0] == 'bases' and a[2] in ('meteor', 'other'):
        bases(a[1], a[2])
    elif len(a) == 2 and a[0] == 'prune':
        prune(a[1])
    else:
        sys.exit(__doc__)
