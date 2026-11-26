<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

# Passes page, and /passes/live: the live signal of the pass being recorded. receive_meteor.sh
# runs SatDump with its web server on 127.0.0.1:<port> and writes IMAGE_PATH/live.json (satellite,
# start, end, sample rate, frequency, port) while it records; liveAction() reads SatDump's /api and
# returns a small JSON for public/assets/js/live.js. SatDump 1.2.3 shares the spectrum and the
# demodulator / decoder figures, not the constellation itself.
class PassesController extends \Lib\Controller {
  const LIVE_BINS = 256;      # spectrum points sent to the browser
  const LIVE_SPAN = 320000;   # Hz of spectrum around the tuned frequency (LRPT is ~120 kHz wide)
  const HEALTH_PASSES = 3;    # this many failed Meteor passes in a row show the station warning

  public function indexAction($args) {
    $pass = $this->loadModel('Pass');
    $pass->getList();
    # station health: the last HEALTH_PASSES finished Meteor passes all gave nothing -> a warning
    # with their reasons (receiver, antenna, ...) at the top of the page
    $recent = $pass->recentResults(self::HEALTH_PASSES);
    $failed = array_filter($recent, function ($r) { return empty($r['id']); });
    $health = (count($recent) == self::HEALTH_PASSES && count($failed) == count($recent)) ? array_values($recent) : null;
    $args = array_merge($args, array('pass' => $pass, 'health' => $health,
                                     'iss_own_sdr' => \App\Models\Pass::issOwnSdr()));
    View::renderTemplate('Passes/index.html', $args);
  }

  public function liveAction($args) {
    $out = array('live' => false, 'time' => time());
    $info = @json_decode((string) @file_get_contents(Config::IMAGE_PATH . '/live.json'), true);
    if (is_array($info) && isset($info['end']) && time() <= $info['end'] + 120) {
      $port = (int) ($info['port'] ?? 8091);
      $ctx = stream_context_create(array('http' => array('timeout' => 1.5)));
      $api = @json_decode((string) @file_get_contents('http://127.0.0.1:' . $port . '/api', false, $ctx), true);
      $out = array_merge($out, array(
        'sat' => $info['sat'] ?? '', 'start' => $info['start'] ?? null, 'end' => $info['end'] ?? null,
        'frequency' => $info['frequency'] ?? null, 'samplerate' => $info['samplerate'] ?? null,
        'max_elev' => $info['max_elev'] ?? null, 'preview_on' => !empty($info['preview'])));
      # live picture (live_preview.sh): only this pass's, with a version so the browser reloads it
      $pv = @json_decode((string) @file_get_contents(Config::IMAGE_PATH . '/live-preview.json'), true);
      if (is_array($pv) && ($pv['start'] ?? null) == ($info['start'] ?? 0) && is_file(Config::IMAGE_PATH . '/live-preview.jpg')) {
        $out['preview'] = '/images/live-preview.jpg?v=' . (int) ($pv['made'] ?? 0);
        $out['preview_channel'] = (int) ($pv['channel'] ?? 0);
        $out['preview_lines'] = (int) ($pv['lines'] ?? 0);
      }
      if (is_array($api)) {
        $psk = $api['psk_demod'] ?? array();
        $dec = $api['ccsds_conv_concat_decoder'] ?? array();
        $out['live'] = true;
        $out['snr'] = isset($psk['snr']) ? round($psk['snr'], 2) : null;
        $out['peak_snr'] = isset($psk['peak_snr']) ? round($psk['peak_snr'], 2) : null;
        $out['freq'] = isset($psk['freq']) ? round($psk['freq'], 1) : null;
        $out['ber'] = isset($dec['viterbi_ber']) ? round($dec['viterbi_ber'], 4) : null;
        $out['viterbi_lock'] = !empty($dec['viterbi_lock']);
        $out['deframer_lock'] = !empty($dec['deframer_lock']);
        $out['rs_avg'] = isset($dec['rs_avg']) ? round($dec['rs_avg'], 2) : null;
        $out['timeout_left'] = $api['timeout_left'] ?? null;
        $out['fft'] = $this->spectrum($api['fft_values'] ?? array(), (int) ($info['samplerate'] ?? 0));
        $out['span'] = $out['fft'] ? min(self::LIVE_SPAN, (int) ($info['samplerate'] ?? self::LIVE_SPAN)) : null;
      }
    }
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($out);
    exit;
  }

  # /passes/isslive: the ISS pass being recorded on its own RTL-SDR (receive_iss.sh's wide
  # recording): iss-live-info.json (mode APRS/SSTV, times, frequency, expected Doppler every 5 s)
  # and iq_fm.py's iss-live.json (whole band, ISS channel and audio spectra, level; once a
  # second), plus the APRS stations heard so far. Public, like /passes/live; read by iss_live.js.
  public function issliveAction($args) {
    $out = array('active' => false, 'time' => time());
    $info = @json_decode((string) @file_get_contents(Config::IMAGE_PATH . '/iss-live-info.json'), true);
    if (is_array($info) && isset($info['end']) && time() <= $info['end'] + 120) {
      $out = array_merge($out, $info, array('active' => true, 'live' => false));
      $f = Config::IMAGE_PATH . '/iss-live.json';
      $data = @json_decode((string) @file_get_contents($f), true);
      if (is_array($data) && time() - (int) ($data['t'] ?? 0) <= 10) {
        $out['live'] = true;
        foreach (array('t', 'wide', 'zoom', 'audio', 'level') as $k) { $out[$k] = $data[$k] ?? null; }
      }
      if (($info['mode'] ?? '') === 'APRS') {
        $out['stations'] = self::aprsStations(Config::IMAGE_PATH . '/aprs-live.csv');
      }
      # SSTV: live_sstv.sh's newest picture, this pass's only, versioned so the browser reloads it
      $pv = @json_decode((string) @file_get_contents(Config::IMAGE_PATH . '/iss-live-sstv.json'), true);
      if (is_array($pv) && ($pv['start'] ?? null) == ($info['start'] ?? 0) && is_file(Config::IMAGE_PATH . '/iss-live-sstv.jpg')) {
        $out['picture'] = '/images/iss-live-sstv.jpg?v=' . (int) ($pv['made'] ?? 0);
        $out['picture_mode'] = (string) ($pv['mode'] ?? '');
        $out['picture_rows'] = (int) ($pv['rows'] ?? 0);
        $out['picture_complete'] = !empty($pv['complete']);
      }
    }
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($out);
    exit;
  }

  # /passes/aprs: the stations heard so far through the ISS on the APRS pass being recorded
  # (receive_iss.sh writes IMAGE_PATH/aprs-live.json and direwolf's log aprs-live.csv). Public, like
  # /passes/live; read by the Satellites map. Stations are grouped by call sign, last position wins.
  public function aprsAction($args) {
    $out = array('active' => false, 'time' => time(), 'stations' => array());
    $info = @json_decode((string) @file_get_contents(Config::IMAGE_PATH . '/aprs-live.json'), true);
    if (is_array($info) && isset($info['end']) && time() <= $info['end'] + 120) {
      $out['active'] = true;
      $out['start'] = $info['start'] ?? null;
      $out['end'] = $info['end'] ?? null;
      $out['frequency'] = $info['frequency'] ?? null;
      $out['stations'] = self::aprsStations(Config::IMAGE_PATH . '/aprs-live.csv');
    }
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($out);
    exit;
  }

  # direwolf -L log -> [{call, lat, lon, symbol, packets, last, comment, via_iss}]
  public static function aprsStations($file) {
    $st = array();
    $f = @fopen($file, 'r');
    if (!$f) return array();
    $head = fgetcsv($f, 0, ',', '"', '');
    if (!is_array($head)) { fclose($f); return array(); }
    while (($row = fgetcsv($f, 0, ',', '"', '')) !== false) {
      if (count($row) != count($head)) continue;
      $r = array_combine($head, $row);
      $call = trim($r['source'] ?? '');
      if ($call === '' || count($st) >= 500) continue;
      $s = $st[$call] ?? array('call' => $call, 'lat' => null, 'lon' => null, 'symbol' => '',
                              'packets' => 0, 'last' => 0, 'comment' => '', 'via_iss' => false);
      $s['packets']++;
      $s['last'] = max($s['last'], (int) ($r['utime'] ?? 0));
      if (is_numeric($r['latitude'] ?? '') && is_numeric($r['longitude'] ?? '')) {
        $s['lat'] = round((float) $r['latitude'], 4);
        $s['lon'] = round((float) $r['longitude'], 4);
      }
      if (($r['symbol'] ?? '') !== '') $s['symbol'] = $r['symbol'];
      $c = trim(($r['comment'] ?? '') !== '' ? $r['comment'] : ($r['status'] ?? ''));
      if ($c !== '') $s['comment'] = mb_substr($c, 0, 80);
      if (preg_match('/RS0ISS|NA1SS|ARISS/i', $r['heard'] ?? '')) $s['via_iss'] = true;
      $st[$call] = $s;
    }
    fclose($f);
    return array_values($st);
  }

  # the middle LIVE_SPAN Hz of SatDump's FFT (centred on the tuned frequency), max-pooled to
  # LIVE_BINS points, in dB with one decimal
  private function spectrum($fft, $samplerate) {
    $n = count($fft);
    if ($n < 16) return null;
    $keep = $samplerate > self::LIVE_SPAN ? (int) round($n * self::LIVE_SPAN / $samplerate) : $n;
    $keep = max(16, min($n, $keep));
    $part = array_slice($fft, (int) (($n - $keep) / 2), $keep);
    $bins = min(self::LIVE_BINS, $keep);
    $out = array();
    for ($i = 0; $i < $bins; $i++) {
      $a = (int) floor($i * $keep / $bins); $b = max($a + 1, (int) floor(($i + 1) * $keep / $bins));
      $out[] = round(max(array_slice($part, $a, $b - $a)), 1);
    }
    return $out;
  }
}

?>
