<?php

# The Live log (public, no login):
#
#   /log                 - dashboard with system status and the live output.log console
#                          (Views/Log/index.html)
#   /log/tail?offset=N   - new log text since byte N, as JSON (polled every 2 s)
#   /log/stats           - CPU, temperature, memory, disks, load, uptime, SDR and schedule,
#                          as JSON (polled every 3 s)

namespace App\Controllers;

use Lib\View;
use Config\Config;

class LogController extends \Lib\Controller {
  public function indexAction($args) {
    View::renderTemplate('Log/index.html', array_merge($args, array('page' => 'log')));
  }

  # new log text since byte offset ?offset=N (or the last 64 KB on first call
  # or after log rotation), as JSON: {offset, size, text, reset}
  public function tailAction($args) {
    $file = defined('Config\Config::LOG_FILE') ? Config::LOG_FILE : '/var/log/raspberry-lrpt/output.log';
    $out = array('offset' => 0, 'size' => 0, 'text' => '', 'reset' => false, 'error' => null);

    clearstatcache(true, $file);
    if (!is_readable($file)) {
      $out['error'] = is_file($file) ? 'Log file is not readable by the web server' : 'Log file not found';
      $this->json($out);
    }

    $size = filesize($file);
    $offset = isset($args['offset']) ? intval($args['offset']) : -1;
    if ($offset < 0 || $offset > $size) {            # first call, or the log was rotated
      $offset = max(0, $size - 524288);             # read further back: start-up noise is dropped below
      $out['reset'] = true;
    }
    $len = min($size - $offset, 262144);
    $text = '';
    if ($len > 0) {
      $fh = fopen($file, 'rb');
      fseek($fh, $offset);
      $text = fread($fh, $len);
      fclose($fh);
      if ($out['reset'] && $offset > 0) {             # drop the partial first line
        $nl = strpos($text, "\n");
        $text = $nl === false ? '' : substr($text, $nl + 1);
      }
    }
    $text = $this->dropNoise($text);
    if ($out['reset']) {                             # the first view only needs the newest lines
      $lines = explode("\n", $text);
      if (count($lines) > self::FIRST_LINES) {
        $text = implode("\n", array_slice($lines, -self::FIRST_LINES));
      }
    }
    $out['offset'] = $offset + $len;
    $out['size'] = $size;
    $out['text'] = mb_convert_encoding($text, 'UTF-8', 'UTF-8');
    $this->json($out);
  }

  const FIRST_LINES = 2000;

  # Every SatDump run starts with ~1,300 lines of start-up chatter: the banner, each plugin and
  # pipeline file it loads, and lists of its plugins, modules and pipelines. It also fails to load
  # the drivers of SDRs this station doesn't have, which it reports as errors. None of it says
  # anything about a pass, so it isn't sent to the browser ("Starting SatDump vX" stays).
  # The last, unfinished line is left alone; the browser keeps it for the next poll.
  const NOISE = '/^\\[\\d\\d:\\d\\d:\\d\\d - [\\d\\/]+\\] (?:'
    . '\\([DT]\\) (?:Loading plugin |Plugin .* loaded!|Loaded plugins|Registered (?:modules|pipelines)| - |Found system pipeline file)'
    . '|\\(I\\) (?:Loading pipelines from file|Loading plugins from|Loading system pipelines|Loading config|Loading user settings|[ _\\/\\\\|.,`]*$)'
    . ')/';

  # SatDump tries every SDR driver at start and logs "Error loading …" for the ones a station
  # doesn't use. Those lines are dropped, except for the station's own receiver's driver.
  const LOAD_ERROR = '/^\\[\\d\\d:\\d\\d:\\d\\d - [\\d\\/]+\\] \\(E\\) Error loading .*(?:\\.so|dynload)/';
  const DRIVER = array('rtlsdr' => '/rtl/i', 'airspy_mini' => '/airspy(?!hf)/i', 'airspy_r2' => '/airspy(?!hf)/i',
                       'airspy_hf_plus_discovery' => '/airspyhf/i', 'hackrf' => '/hackrf/i',
                       'sdrplay' => '/sdrplay/i', 'mirisdr' => '/mirisdr/i');

  # USB ids of each receiver type (vendor, products; null = any product), as the install checks them
  const SDR_USB = array(
    'rtlsdr' => array(array('0bda', array('2832', '2838'), 'RTL-SDR')),
    'airspy_mini' => array(array('1d50', array('60a1'), 'Airspy')),
    'airspy_r2' => array(array('1d50', array('60a1'), 'Airspy')),
    'airspy_hf_plus_discovery' => array(array('03eb', array('800c'), 'Airspy HF+')),
    'hackrf' => array(array('1d50', array('6089', 'cc15'), 'HackRF')),
    'sdrplay' => array(array('1df7', null, 'SDRplay')),
    'mirisdr' => array(array('1df7', null, 'MiriSDR'), array('2040', array('d300'), 'MiriSDR')));

  private static function receiver() {
    $r = defined('Config\\Config::RECEIVER_TYPE') ? Config::RECEIVER_TYPE : 'rtlsdr';
    return isset(self::SDR_USB[$r]) ? $r : 'rtlsdr';
  }

  private function dropNoise($text) {
    $lines = explode("\n", $text);
    $last = array_pop($lines);
    $keep = array();
    foreach ($lines as $line) {
      $plain = preg_replace('/\\x1b?\\[[0-9;]*m/', '', $line);
      if (preg_match(self::NOISE, $plain)) continue;
      if (preg_match(self::LOAD_ERROR, $plain) && !preg_match(self::DRIVER[self::receiver()], $plain)) continue;
      $keep[] = $line;
    }
    $keep[] = $last;
    return implode("\n", $keep);
  }

  # system status snapshot as JSON
  public function statsAction($args) {
    $s = array('time' => time());

    # CPU usage from two /proc/stat samples 250 ms apart
    $a = $this->cpuSample(); usleep(250000); $b = $this->cpuSample();
    if ($a && $b && ($b[0] - $a[0]) > 0) {
      $s['cpu'] = round(100 * (1 - ($b[1] - $a[1]) / ($b[0] - $a[0])), 1);
    }
    $s['cores'] = preg_match_all('/^processor\s*:/m', (string) @file_get_contents('/proc/cpuinfo')) ?: null;

    $t = @file_get_contents('/sys/class/thermal/thermal_zone0/temp');
    if ($t !== false) { $s['temp'] = round(intval($t) / 1000, 1); }

    $mem = array();
    foreach (@file('/proc/meminfo') ?: array() as $line) {
      if (preg_match('/^(\w+):\s+(\d+)/', $line, $m)) { $mem[$m[1]] = intval($m[2]) * 1024; }
    }
    if (isset($mem['MemTotal'])) {
      $s['mem_total'] = $mem['MemTotal'];
      $s['mem_used'] = $mem['MemTotal'] - ($mem['MemAvailable'] ?? 0);
      $s['swap_total'] = $mem['SwapTotal'] ?? 0;
      $s['swap_used'] = ($mem['SwapTotal'] ?? 0) - ($mem['SwapFree'] ?? 0);
    }

    # the RAM disk only exists with storage: sd; an unmounted /var/ramfs would show the root disk
    $mounts = (string) @file_get_contents('/proc/mounts');
    foreach (array('disk' => '/srv', 'ramfs' => '/var/ramfs') as $k => $path) {
      if ($k === 'ramfs' && strpos($mounts, ' ' . $path . ' tmpfs ') === false) { continue; }
      if (is_dir($path)) {
        $total = @disk_total_space($path); $free = @disk_free_space($path);
        if ($total) { $s[$k . '_total'] = $total; $s[$k . '_used'] = $total - $free; }
      }
    }

    $load = @file_get_contents('/proc/loadavg');
    if ($load !== false) { $s['load'] = array_map('floatval', array_slice(explode(' ', $load), 0, 3)); }
    $up = @file_get_contents('/proc/uptime');
    if ($up !== false) { $s['uptime'] = intval(floatval($up)); }
    $model = @file_get_contents('/proc/device-tree/model');
    if ($model !== false) { $s['model'] = trim($model, "\0\n "); }
    $s['host'] = gethostname();

    # SDR: the station's own receiver on USB (receiver_type), and whether a capture is running
    $s['sdr'] = false;
    foreach (glob('/sys/bus/usb/devices/*/idVendor') ?: array() as $vf) {
      $dir = dirname($vf);
      $vendor = strtolower(trim(@file_get_contents($vf)));
      $product = strtolower(trim(@file_get_contents($dir . '/idProduct')));
      foreach (self::SDR_USB[self::receiver()] as $id) {
        if ($vendor == $id[0] && ($id[1] === null || in_array($product, $id[1]))) {
          $s['sdr'] = trim(@file_get_contents($dir . '/product')) ?: $id[2];
          break 2;
        }
      }
    }
    $s['capturing'] = false;
    $busy = array('satdump' => false, 'rtl_fm' => false, 'rtl_sdr' => false);
    foreach (glob('/proc/[0-9]*/comm') ?: array() as $cf) {
      $comm = trim(@file_get_contents($cf));
      if (isset($busy[$comm])) { $busy[$comm] = true; $s['capturing'] = true; }
    }
    $busy['rtl_fm'] = $busy['rtl_fm'] || $busy['rtl_sdr'];   # the ISS's wide recording (v1.42.0)

    # two or more RTL-SDRs: each with its role (schedule.sh writes sdr.json), whether it is still
    # on USB (its serial in /sys) and whether its recorder is running (SatDump for the Meteors,
    # rtl_fm or rtl_sdr for the ISS)
    $list = @json_decode((string) @file_get_contents(Config::IMAGE_PATH . '/sdr.json'), true);
    if (is_array($list) && count($list) > 1) {
      $serials = array();
      foreach (glob('/sys/bus/usb/devices/*/serial') ?: array() as $sf) {
        $serials[] = trim((string) @file_get_contents($sf));
      }
      $s['sdrs'] = array();
      foreach ($list as $d) {
        $role = (string) ($d['role'] ?? 'spare');
        $s['sdrs'][] = array(
          'name' => trim(($d['model'] ?? '') ?: ($d['maker'] ?? 'RTL-SDR')),
          'serial' => (string) ($d['serial'] ?? ''),
          'role' => $role,
          'present' => ($d['serial'] ?? '') === '' || in_array((string) $d['serial'], $serials, true),
          'busy' => (strpos($role, 'meteor') !== false && $busy['satdump'])
                    || (strpos($role, 'iss') !== false && $busy['rtl_fm']),
        );
      }
    }

    # schedule: next pass, passes left today, last decoded capture
    $now = time();
    $row = $this->db_conn->querySingle("SELECT sat_name, pass_start, pass_end, max_elev FROM predict_passes
                                         WHERE is_active = 1 AND pass_end > $now
                                         ORDER BY pass_start ASC LIMIT 1", true);
    if ($row) { $s['next_pass'] = $row; }
    $s['scheduled'] = intval($this->db_conn->querySingle("SELECT COUNT(*) FROM predict_passes
                                                           WHERE is_active = 1 AND pass_start > $now"));
    $row = $this->db_conn->querySingle("SELECT decoded_passes.pass_start, predict_passes.sat_name, predict_passes.max_elev
                                         FROM decoded_passes LEFT JOIN predict_passes
                                           ON predict_passes.pass_start = decoded_passes.pass_start
                                         ORDER BY decoded_passes.pass_start DESC LIMIT 1", true);
    if ($row) { $s['last_capture'] = $row; }

    $this->json($s);
  }

  # [total jiffies, idle jiffies] from the first line of /proc/stat
  private function cpuSample() {
    $line = @fgets(@fopen('/proc/stat', 'r'));
    if (!$line || !preg_match('/^cpu\s+(.*)$/', $line, $m)) { return null; }
    $v = array_map('intval', preg_split('/\s+/', trim($m[1])));
    return array(array_sum($v), $v[3] + ($v[4] ?? 0));
  }

  private function json($data) {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
  }
}

?>
