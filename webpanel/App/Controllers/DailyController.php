<?php

# Daily map (/daily): every pass of a day projected onto one map of the region around the
# station, one map for the daytime passes and one for the night-time passes. The maps and a
# <date>.json list of the passes in them are made by scripts/daily_map.sh in IMAGE_PATH/daily.
# With enable_animation each day also has a time-lapse of its passes over the animation area,
# made by scripts/animation.sh in IMAGE_PATH/daily/timelapse (<date>.webm/.mp4/.jpg/.json).

namespace App\Controllers;

use Lib\View;
use Config\Config;

class DailyController extends \Lib\Controller {
  const DAYS_PER_PAGE = 7;

  public function indexAction($args) {
    $dir = Config::IMAGE_PATH . '/daily';
    $files = glob($dir . '/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json') ?: array();
    rsort($files);

    $pages = max(1, (int) ceil(count($files) / self::DAYS_PER_PAGE));
    $page = isset($args['page_no']) ? max(1, min($pages, (int) $args['page_no'])) : 1;

    $days = array();
    foreach (array_slice($files, ($page - 1) * self::DAYS_PER_PAGE, self::DAYS_PER_PAGE) as $file) {
      $info = json_decode(file_get_contents($file), true);
      if (!is_array($info) || empty($info['date'])) continue;
      $date = $info['date'];
      $maps = array();
      foreach (array('day', 'night') as $kind) {
        $jpg = $dir . '/' . $date . '-' . $kind . '.jpg';
        if (!is_file($jpg)) continue;
        $v = filemtime($jpg);
        $comp = $info['composites'][$kind] ?? null;
        $passes = $this->passes($info[$kind] ?? array());
        $maps[] = array(
          'kind' => $kind,
          'composite' => $comp['name'] ?? ($kind == 'day' ? 'AVHRR 221' : '3.9 µm Shortwave IR'),
          'channels' => implode('-', $comp['channels'] ?? ($kind == 'day' ? array(2, 2, 1) : array(4))),
          'wavelengths' => $comp['wavelengths'] ?? '',
          'first' => $passes ? $passes[0]['start'] : null,
          'last' => $passes ? end($passes)['start'] : null,
          'image' => $jpg . '?v=' . $v,
          'thumb' => $dir . '/thumb/' . $date . '-' . $kind . '.jpg?v=' . $v,
          'passes' => $passes,
        );
      }
      $timelapse = $this->timelapse($dir . '/timelapse', $date);
      if ($maps || $timelapse) $days[] = array('date' => $date, 'ts' => strtotime($date . ' 12:00'), 'maps' => $maps,
                                 'area' => $this->area($info), 'made' => $info['made'] ?? filemtime($file),
                                 'decoder' => $info['decoder'] ?? 'SatDump', 'timelapse' => $timelapse);
    }

    View::renderTemplate('Daily/index.html', array_merge($args, array(
      'page' => 'daily', 'days' => $days, 'cur_page' => $page, 'page_count' => $pages)));
  }

  # a day's time-lapse made by scripts/animation.sh (enable_animation): the videos, the last
  # frame as the poster, and <date>.json (area, passes, when it was made)
  private function timelapse($dir, $date) {
    if (Config::ENABLE_ANIMATION !== 'true') return null;
    $webm = $dir . '/' . $date . '.webm';
    $mp4 = $dir . '/' . $date . '.mp4';
    if (!is_file($webm) && !is_file($mp4)) return null;
    $json = $dir . '/' . $date . '.json';
    $info = is_file($json) ? json_decode(file_get_contents($json), true) : array();
    if (!is_array($info)) $info = array();
    $v = filemtime(is_file($mp4) ? $mp4 : $webm);
    $passes = $info['passes'] ?? array();
    $times = array_map(function ($b) {
      return preg_match('/(\d{8})-(\d{6})$/', $b, $m) ? strtotime($m[1] . 'T' . $m[2] . 'Z') : null;
    }, $passes);
    $times = array_values(array_filter($times));
    $poster = $dir . '/' . $date . '.jpg';
    return array(
      'webm' => is_file($webm) ? $webm . '?v=' . $v : null,
      'mp4' => is_file($mp4) ? $mp4 . '?v=' . $v : null,
      'poster' => is_file($poster) ? $poster . '?v=' . $v : null,
      'frames' => count($passes),
      'first' => $times ? min($times) : null,
      'last' => $times ? max($times) : null,
      'made' => $info['made'] ?? $v,
      'area' => $this->area($info),
      'size' => $info['size'] ?? null,
    );
  }

  # the map's area and scale, from daily_map.sh's bounds: "7.0°W–63.0°E · 11.1°N–61.1°N",
  # pixel size and roughly how many km a pixel is (north-south)
  private function area($info) {
    $b = $info['bounds'] ?? null;
    if (!is_array($b) || count($b) != 4) return null;
    $lon = function ($v) { return sprintf('%.0f°%s', abs($v), $v < 0 ? 'W' : 'E'); };
    $lat = function ($v) { return sprintf('%.0f°%s', abs($v), $v < 0 ? 'S' : 'N'); };
    $deg = $info['deg_per_px'] ?? 0.025;
    return array(
      'lon' => $lon($b[0]) . '–' . $lon($b[2]),
      'lat' => $lat($b[3]) . '–' . $lat($b[1]),
      'size' => isset($info['size']) ? $info['size'][0] . ' × ' . $info['size'][1] : null,
      'km' => round($deg * 111.32, 1),
      'proj' => $info['projection'] ?? 'equirectangular',
    );
  }

  # the passes a map is made of, oldest first: satellite, start time and the capture's id
  private function passes($bases) {
    $out = array();
    $q = $this->db_conn->prepare('SELECT id, pass_start FROM decoded_passes WHERE file_path = :f ORDER BY id DESC LIMIT 1');
    foreach ($bases as $base) {
      if (!preg_match('/^METEOR-M2-(\d)-/', $base, $m)) continue;
      $q->bindValue(':f', $base, SQLITE3_TEXT);
      $row = $q->execute()->fetchArray(SQLITE3_ASSOC);
      if (!$row) continue;
      $out[] = array('sat' => 'M2 ' . $m[1], 'colour' => 'm2' . $m[1], 'id' => $row['id'], 'start' => $row['pass_start']);
    }
    usort($out, function ($a, $b) { return $a['start'] - $b['start']; });
    return $out;
  }
}

?>
