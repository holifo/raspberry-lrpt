<?php

namespace Lib;

use Config\Config;

# The result of scripts/update_check.sh (IMAGE_PATH/update.json, written daily and by each
# install): is a newer Raspberry-LRPT on GitHub? Used by the About page and the footer.
class Update {
  public static function status() {
    static $cached = false;
    if ($cached !== false) { return $cached; }
    $cached = null;
    $f = Config::IMAGE_PATH . '/update.json';
    if (!is_readable($f)) { return $cached; }
    $j = json_decode((string) @file_get_contents($f), true);
    if (!is_array($j) || empty($j['status'])) { return $cached; }
    # the running web panel's own version is what is installed, whatever the file says
    $vf = dirname(__DIR__) . '/VERSION';
    if (is_readable($vf)) { $j['installed'] = trim(file_get_contents($vf)); }
    # pulled but not installed: the clone's VERSION differs from the web panel's
    if ($j['status'] == 'ok' && !empty($j['repo']) && !empty($j['installed']) && $j['repo'] != $j['installed']) {
      $j['status'] = 'install';
    }
    # an "update" that is already installed (the install ran after the check)
    if ($j['status'] == 'update' && !empty($j['latest']) && $j['latest'] == ($j['installed'] ?? '')
        && ($j['repo'] ?? '') == $j['latest']) {
      $j['status'] = 'ok';
    }
    $j['releases'] = (isset($j['releases']) && preg_match('#^https://github\.com/[\w.-]+/[\w.-]+/releases$#', $j['releases']))
      ? $j['releases'] : '';
    $cached = $j;
    return $cached;
  }
}

?>
