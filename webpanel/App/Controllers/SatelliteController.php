<?php

# Pages:
#
#   /satellite         - the Satellites tab: the live map framed to fill the window, with
#                        the coming passes beside it (tap one to draw its track)
#   /satellite/map     - Meteor live map (App/Static/meteor-map.html), framed by /satellite
#
# Only available when 'experimental_features: true' is set in
# config/settings.yml. The HTML lives outside public/ so the flag cannot be
# bypassed by requesting the file directly.
#
# The station position and the scheduler's own TLE file (copied to
# App/Static/meteor.tle by scripts/schedule.sh) are injected into the page,
# so the map shows the same orbits that were used to schedule captures.

namespace App\Controllers;

use Config\Config;
use Lib\View;

class SatelliteController extends \Lib\Controller {
  public function indexAction($args) {
    $this->requireFeature();
    $pass = $this->loadModel('Pass');
    $pass->getList();
    # the pass in progress and the next ones
    $now = time();
    $coming = array_values(array_filter($pass->list, function ($p) use ($now) { return $p['pass_end'] >= $now; }));
    View::renderTemplate('Satellite/index.html', array_merge($args, array(
      'page' => 'satellite', 'passes' => array_slice($coming, 0, 12))));
  }

  public function mapAction($args) {
    $this->servePage('meteor-map.html', true);
  }

  # feature flag gate - the defined() guard tolerates a Config.php generated
  # by an older Config.php.j2 that predates this constant
  private function requireFeature() {
    if (!defined('Config\Config::ENABLE_EXPERIMENTAL_FEATURES') ||
        Config::ENABLE_EXPERIMENTAL_FEATURES != 'true') {
      header('Location: /passes');
      exit;
    }
  }

  private function servePage($file, $with_tle) {
    $this->requireFeature();

    $static_dir = __DIR__ . '/../Static';
    $html_file = $static_dir . '/' . $file;
    if (!file_exists($html_file)) {
      header('HTTP/1.0 404 Not Found');
      echo '404 - ' . $file . ' asset is missing';
      exit;
    }

    $observer = json_encode(array(
      'lat'   => floatval(Config::BASE_STATION_LAT),
      'lon'   => floatval(Config::BASE_STATION_LON),
      'label' => 'GROUND STATION',
    ));
    $inject = "<script>window.RL1_OBSERVER = " . $observer . ";";
    $inject .= "\nwindow.RL1_ISS = " . (Config::ISS_SSTV ? 'true' : 'false') . ";";
    # the visitor's language for the map's own text
    $inject .= "\nwindow.RL1_LANG = " . json_encode(\Lib\Lang::strings(), JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) . ";";

    if ($with_tle) {
      $tle_file = $static_dir . '/meteor.tle';
      $tle = is_readable($tle_file) ? file_get_contents($tle_file) : '';
      # JSON_HEX_* keeps the injected text from closing the <script> tag
      $flags = JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT;
      $inject .= "\nwindow.RL1_TLE = " . json_encode($tle, $flags) . ";";
    }
    $inject .= "</script>\n</head>";

    header('Content-Type: text/html; charset=utf-8');
    echo str_replace('</head>', $inject, file_get_contents($html_file));
  }
}

?>
