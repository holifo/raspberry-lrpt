#!/usr/bin/env python3
#
# Write the station's two generated settings files without the install, as the station user:
# ~/.raspberry-lrpt.conf (raspberry-lrpt.conf.j2) and the web panel's Config.php (Config.php.j2),
# from the given settings + ansible/group_vars/all.yml, the same way Ansible's template module
# does (Jinja2; Ansible's 'quote' filter is shlex.quote). Used by settings_form.py apply.
#
#   render_config.py [FILE.yml]   render from FILE (default config/.settings.merged.yml)

import getpass
import os
import shlex
import subprocess
import sys

import jinja2
import yaml

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEMPLATES = {
    'conf': os.path.join(REPO, 'ansible/roles/common/templates/raspberry-lrpt.conf.j2'),
    'php': os.path.join(REPO, 'ansible/roles/webserver/templates/Config.php.j2'),
}


def _out(cmd, default=''):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip() or default
    except (OSError, subprocess.SubprocessError):
        return default


def codename():
    info = {}
    try:
        with open('/etc/os-release') as f:
            for line in f:
                if '=' in line:
                    k, v = line.rstrip('\n').split('=', 1)
                    info[k] = v.strip('"')
    except OSError:
        pass
    return info.get('DEBIAN_CODENAME') or info.get('VERSION_CODENAME', 'bookworm')


def variables(settings):
    env = jinja2.Environment(undefined=jinja2.ChainableUndefined)
    v = {}
    with open(os.path.join(REPO, 'ansible/group_vars/all.yml')) as f:
        v.update(yaml.safe_load(f))
    v.update(settings)
    v.update(target_user=getpass.getuser(),
             raspbian_version={'stdout': codename()},
             system_timezone={'stdout': _out(['timedatectl', 'show', '--property=Timezone', '--value'], 'UTC')},
             system_architecture=_out(['dpkg', '--print-architecture'], 'arm64'))
    for _ in range(4):                          # group vars that use other variables
        for k, val in list(v.items()):
            if isinstance(val, str) and '{{' in val:
                v[k] = env.from_string(val).render(**v)
    return v


def render(name, v):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
    env.filters['quote'] = lambda s: shlex.quote(str(s))
    with open(TEMPLATES[name]) as f:
        return env.from_string(f.read()).render(**v)


def write(path, text, mode=None):
    # in place, so the file keeps its owner, group and mode (Config.php: group www-data)
    with open(path, 'w') as f:
        f.write(text)
    if mode is not None:
        os.chmod(path, mode)


def write_all(settings):
    """Render both files from these settings and write them where the install puts them."""
    v = variables(settings)
    conf = render('conf', v)
    php = render('php', v)
    write(os.path.expanduser('~/.raspberry-lrpt.conf'), conf, 0o600)
    php_path = os.path.join(v['web_home'], 'Config', 'Config.php')
    if os.path.isdir(os.path.dirname(php_path)):
        write(php_path, php)


if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, 'config', '.settings.merged.yml')
    with open(path) as f:
        write_all(yaml.safe_load(f) or {})
