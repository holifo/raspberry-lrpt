# Compact Ansible output for install_and_upgrade.sh: one line per part of the install, the
# tasks that changed something listed under it, and full details only when a task fails.
#
#     Packages and SatDump ............ ✓ 9 tasks · 1 changed · 41 s
#         ~ Python packages (pip)
#     Settings and SatDump config ..... ✓ 15 tasks · 0 changed · 3 s
#
# The part is named after the task file (see PARTS). Skipped tasks are not counted.
# Turned on by install_and_upgrade.sh with ANSIBLE_STDOUT_CALLBACK=compact.

import os
import time

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = '''
    name: compact
    type: stdout
    short_description: one line per part of the Raspberry-LRPT install
    description: Groups tasks by task file, lists changed tasks, shows details only on failure.
'''

PARTS = {
    'core.yml': 'Checks',
    'dependencies.yml': 'Packages and SatDump',
    'configs.yml': 'Settings and SatDump config',
    'ntp.yml': 'Time (NTP)',
    'sdr.yml': 'SDR drivers',
    'sdrplay.yml': 'SDRplay API and plugin',
    'tools.yml': 'Scheduler and folders',
    'ramfs.yml': 'RAM disk',
    'main.yml': 'Web server',
    'handlers': 'Restarting services',
}
WIDTH = 34

if os.environ.get('NO_COLOR') or os.environ.get('TERM') == 'dumb':
    GREEN = YELLOW = RED = DIM = BOLD = RESET = ''
else:
    GREEN, YELLOW, RED, DIM, BOLD, RESET = '\033[32m', '\033[33m', '\033[31m', '\033[2m', '\033[1m', '\033[0m'


def _name(task):
    """The task's name without the role prefix ("common : ")."""
    return task.get_name().split(' : ', 1)[-1]


def _secs(s):
    s = int(round(s))
    return '%d s' % s if s < 60 else '%d min %d s' % (s // 60, s % 60)


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = 'stdout'
    CALLBACK_NAME = 'compact'

    def __init__(self):
        super().__init__()
        self.start = time.time()
        self.part = None
        self.part_start = 0
        self.done = self.changed_n = 0
        self.changed = []
        self.warnings = []
        self.total = self.total_changed = self.total_failed = 0
        self.failed_part = False

    # ---- output helpers -------------------------------------------------------------
    def _out(self, text, newline=True):
        self._display.display(text, newline=newline) if newline else print(text, end='', flush=True)

    def _open(self, name):
        if name == self.part:
            return
        self._close()
        self.part = name
        self.part_start = time.time()
        self.done = self.changed_n = 0
        self.changed, self.warnings = [], []
        self.failed_part = False
        print('   %s %s ' % (name, '.' * max(2, WIDTH - len(name))), end='', flush=True)

    def _close(self):
        if self.part is None:
            return
        if not self.failed_part:
            print('%s✓%s %d task%s · %s%d changed%s · %s' % (
                GREEN, RESET, self.done, '' if self.done == 1 else 's',
                YELLOW if self.changed_n else '', self.changed_n, RESET if self.changed_n else '',
                _secs(time.time() - self.part_start)), flush=True)
        for name in self.changed:
            print('       %s~%s %s' % (YELLOW, RESET, name), flush=True)
        for w in dict.fromkeys(self.warnings):
            print('       %s! %s%s' % (YELLOW, w.strip().splitlines()[0][:150], RESET), flush=True)
        self.part = None

    @staticmethod
    def _part_of(task, handler=False):
        if handler:
            return PARTS['handlers']
        path = (task.get_path() or '').rsplit(':', 1)[0]
        return PARTS.get(os.path.basename(path), os.path.splitext(os.path.basename(path))[0].replace('_', ' ').capitalize() or 'Tasks')

    # ---- tasks ----------------------------------------------------------------------
    def v2_playbook_on_task_start(self, task, is_conditional):
        self._open(self._part_of(task))

    def v2_playbook_on_handler_task_start(self, task):
        self._open(self._part_of(task, handler=True))

    def v2_runner_on_ok(self, result):
        r = result._result
        self.done += 1
        self.total += 1
        if r.get('changed'):
            self.changed_n += 1
            self.total_changed += 1
            self.changed.append(_name(result._task))
        self.warnings.extend(r.get('warnings') or [])

    def v2_runner_on_skipped(self, result):
        pass

    def v2_runner_item_on_ok(self, result):
        pass

    def v2_runner_item_on_skipped(self, result):
        pass

    def v2_runner_item_on_failed(self, result):
        self._fail(result, item=True)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        if ignore_errors:
            self.done += 1
            self.total += 1
            self.warnings.append('%s: failed (ignored)' % _name(result._task))
            return
        if result._result.get('results') and self.failed_part:
            return                                      # the failing item was shown already
        self._fail(result)

    def v2_runner_on_unreachable(self, result):
        self._fail(result)

    def _fail(self, result, item=False):
        r = result._result
        if not self.failed_part:
            print('%s✗ failed%s' % (RED, RESET), flush=True)
            self.failed_part = True
            self.total_failed += 1
        label = _name(result._task)
        if item:
            label += ' (%s)' % self._get_item_label(r)
        print('       %s✗ %s%s' % (RED + BOLD, label, RESET), flush=True)
        lines = []
        if r.get('msg'):
            lines.append(str(r['msg']))
        for key in ('stderr', 'stdout'):
            text = (r.get(key) or '').strip()
            if text:
                lines.extend(text.splitlines()[-15:])
        if r.get('cmd'):
            cmd = r['cmd'] if isinstance(r['cmd'], str) else ' '.join(map(str, r['cmd']))
            lines.append('command: ' + cmd)
        for line in lines or ['(no message)']:
            print('         %s%s%s' % (RED, line, RESET), flush=True)

    # ---- end ------------------------------------------------------------------------
    def v2_playbook_on_stats(self, stats):
        self._close()
        print('   %s%d task%s · %d changed · %d failed · %s%s' % (
            DIM, self.total, '' if self.total == 1 else 's', self.total_changed, self.total_failed, _secs(time.time() - self.start), RESET), flush=True)

    # quiet: no play banners, no include/loop chatter
    def v2_playbook_on_play_start(self, play):
        pass

    def v2_playbook_on_include(self, included_file):
        pass

    def v2_playbook_on_no_hosts_matched(self):
        print('   %s! no hosts matched%s' % (YELLOW, RESET))
