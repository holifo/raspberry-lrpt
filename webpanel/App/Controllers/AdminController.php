<?php

namespace App\Controllers;

use Lib\View;
use Config\Config;

class AdminController extends \Lib\Controller {
  # perform authentication prior to access any admin endpoint
  # NOTE: This is a CHEAP method of security and not recommended as
  #       "sufficient" to enable exposing things on the public internet.
  #       /admin/log only redirects to the public Live log at /log.
  const PUBLIC_ACTIONS = ['log'];
  protected function before() {
    if (in_array($this->action, self::PUBLIC_ACTIONS, true)) { return; }
    if (Config::LOCK_ADMIN == "true") {
      if (!isset($_SERVER['PHP_AUTH_USER']) ||
          ($_SERVER['PHP_AUTH_USER'] != Config::ADMIN_USER || $_SERVER['PHP_AUTH_PW'] != Config::ADMIN_PASS)) {
        header('WWW-Authenticate: Basic realm="raspberry-lrpt"');
        header('HTTP/1.0 401 Unauthorized');
        echo 'Auth required';
        exit;
      }
    }
  }

  public function passesAction($args) {
    $pass = $this->loadModel('Pass');
    $pass->getActiveList();
    # ?sw=<meteor|iss>-<result> from switchAction
    $sw = null;
    if (isset($args['sw']) && preg_match('/^(meteor|iss)-([a-z]+)$/', $args['sw'], $m)
        && in_array($m[2], self::SWITCH_RESULTS, true)) {
      $sw = array('what' => $m[1], 'result' => $m[2]);
    }
    $args = array_merge($args, array('pass' => $pass,
                                     'sw' => $sw,
                                     'iss_switchable' => true,     # switch.sh refuses when no RTL-SDR is connected
                                     'admin_action' => 'passes'));
    View::renderTemplate('Admin/passes.html', $args);
  }

  # Meteor and ISS switches (Admin > Passes): POST what=meteor|iss, state=on|off from this site's
  # own page. It runs scripts/switch.sh --web as the station user (sudo rule 030_www-data-switch:
  # those four commands only); the script refuses while a pass is recording or within 2 minutes
  # of the last change. Results go back as /admin/passes?sw=<what>-<result>.
  const SWITCH_RESULTS = ['on', 'off', 'busy', 'wait', 'fail'];
  public function switchAction($args) {
    $what = $_POST['what'] ?? '';
    $state = $_POST['state'] ?? '';
    $same_site = $this->sameSite();
    if (!in_array($what, ['meteor', 'iss'], true)) {
      header('Location: /admin/passes');
      return;
    }
    if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !in_array($state, ['on', 'off'], true) || !$same_site) {
      header('Location: /admin/passes?sw=' . $what . '-fail');
      return;
    }
    $cmd = 'sudo -n -H -u ' . escapeshellarg(Config::STATION_USER) . ' '
         . escapeshellarg(Config::LRPT_HOME . '/scripts/switch.sh') . ' --web ' . $what . ' ' . $state . ' 2>&1';
    exec($cmd, $out, $code);
    $result = [0 => $state, 2 => 'busy', 3 => 'wait'][$code] ?? 'fail';
    if ($result === 'fail') {
      error_log('Switch ' . $what . ' ' . $state . ' failed (' . $code . '): ' . implode(' | ', $out));
    }
    # the script rewrote Config.php: don't let the next page read the cached copy
    if (function_exists('opcache_invalidate')) {
      opcache_invalidate(dirname(__DIR__, 2) . '/Config/Config.php', true);
    }
    header('Location: /admin/passes?sw=' . $what . '-' . $result);
  }

  # Settings page (Admin > Settings). scripts/settings_web.sh show|apply runs as the station user
  # (sudo rule 030_www-data-switch; no sudo when PHP already runs as that user, e.g. in tests).
  # The admin login and the Discord webhook are never sent here. Not security-reviewed: see the
  # notice on the page.
  private function settingsCmd($what) {
    $me = function_exists('posix_geteuid') ? (posix_getpwuid(posix_geteuid())['name'] ?? '') : '';
    $sudo = $me === Config::STATION_USER ? '' : 'sudo -n -H -u ' . escapeshellarg(Config::STATION_USER) . ' ';
    return $sudo . escapeshellarg(Config::LRPT_HOME . '/scripts/settings_web.sh') . ' ' . $what;
  }

  private function settingsRun($what, $input = '') {
    $proc = proc_open($this->settingsCmd($what), [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($proc)) { return [null, 1]; }
    fwrite($pipes[0], $input);
    fclose($pipes[0]);
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $code = proc_close($proc);
    if ($err !== '') { error_log('settings_web.sh ' . $what . ': ' . trim($err)); }
    $json = null;
    foreach (array_reverse(explode("\n", trim($out))) as $line) {    # the JSON result line
      if (substr(ltrim($line), 0, 1) === '{') { $json = json_decode($line, true); break; }
    }
    return [$json, $code];
  }

  # the form's text for a value, as the page shows and posts it
  private static function settingText($v) {
    if (is_bool($v)) { return $v ? 'true' : 'false'; }
    if ($v === null) { return ''; }
    return (string)$v;
  }

  private function sameSite() {
    $origin = $_SERVER['HTTP_ORIGIN'] ?? ($_SERVER['HTTP_REFERER'] ?? '');
    $host = $_SERVER['HTTP_HOST'] ?? '';
    $o_host = parse_url($origin, PHP_URL_HOST);
    $o_port = parse_url($origin, PHP_URL_PORT);
    return $o_host && $host !== '' && $o_host . ($o_port ? ':' . $o_port : '') === $host;
  }

  const SETTINGS_RESULTS = ['saved', 'none'];
  public function settingsAction($args) {
    list($data, $code) = $this->settingsRun('show');
    $sections = is_array($data) ? ($data['sections'] ?? null) : null;
    $result = null;
    $errors = [];
    $posted = [];
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && $sections !== null) {
      $in = is_array($_POST['s'] ?? null) ? $_POST['s'] : [];
      $changes = [];
      foreach ($sections as $sec) {
        foreach ($sec['settings'] as $row) {
          $key = $row['key'];
          if (!empty($row['secret']) || !empty($row['locked']) || !array_key_exists($key, $in) || !is_string($in[$key])) { continue; }
          $new = trim(str_replace(["\r\n", "\r", "\n"], ' ', $in[$key]));
          $posted[$key] = $new;
          $cur = $row['value'];
          $same = (is_int($cur) || is_float($cur)) ? (is_numeric($new) && (float)$new == (float)$cur)
                                                   : $new === self::settingText($cur);
          if (!$same) { $changes[$key] = $new; }
        }
      }
      if (!$this->sameSite()) {
        $result = 'fail';
      } elseif (!$changes) {
        header('Location: /admin/settings?r=none');
        return;
      } else {
        list($res, $code) = $this->settingsRun('apply', json_encode($changes));
        if (function_exists('opcache_invalidate')) {
          opcache_invalidate(dirname(__DIR__, 2) . '/Config/Config.php', true);
        }
        if (is_array($res) && !empty($res['ok'])) {
          header('Location: /admin/settings?r=saved&n=' . count($res['saved'])
                 . '&i=' . count($res['install']) . '&sch=' . (empty($res['reschedule']) ? 0 : 1));
          return;
        }
        if (is_array($res) && !empty($res['busy'])) {
          $result = 'busy';
        } elseif (is_array($res) && !empty($res['errors'])) {
          $result = 'invalid';
          $errors = $res['errors'];
        } else {
          $result = 'fail';
          error_log('Settings apply failed (' . $code . ')');
        }
      }
    } elseif (isset($args['r']) && in_array($args['r'], self::SETTINGS_RESULTS, true)) {
      $result = $args['r'];
    }
    if ($sections !== null) {
      foreach ($sections as &$sec) {
        foreach ($sec['settings'] as &$row) {
          if (!array_key_exists('value', $row)) { continue; }
          $row['text'] = array_key_exists($row['key'], $posted) ? $posted[$row['key']] : self::settingText($row['value']);
          $row['error'] = $errors[$row['key']] ?? null;
        }
      }
      unset($sec, $row);
    }
    $args = array_merge($args, array('sections' => $sections,
                                     'result' => $result,
                                     'saved_n' => (int)($args['n'] ?? 0),
                                     'install_n' => (int)($args['i'] ?? 0),
                                     'resched' => ($args['sch'] ?? '') === '1',
                                     'admin_action' => 'settings'));
    View::renderTemplate('Admin/settings.html', $args);
  }

  # TODO: This is not very DRY between this and the above function - do
  #       something about this in the future
  public function deletePassAction($args) {
    $lang = \Lib\Lang::strings();
    $pass = $this->loadModel('Pass');

    # attempt to delete the user-specified pass
    $status_msg = 'Fail';
    if (array_key_exists('pass_start_id', $args) and $args['pass_start_id'] > 0) {
      $pass_start_id = $args['pass_start_id'];
      $pass->getATJobId($pass_start_id);

      # attempt to remove the job ID
      try {
        echo shell_exec("sudo -u " . escapeshellarg(Config::STATION_USER) . " /usr/bin/atrm " . escapeshellarg($pass->at_job_id) . " 2>&1");
      } catch (exception $e) {
        error_log("Could not delete pass job ID using atrm for job ID: " . $pass->at_job_id . " - " . $e);
      }

      # attempt to delete the database record
      try {
        $pass->deleteByPassStart($pass_start_id);
      } catch (exception $e) {
        error_log("Could not delete pass from database for pass ID: " . $pass_start_id . " - " . $e);
      }

      $status_msg = 'Success';
    } else {
      $status_msg = $lang['fail_delete_missing_id'];
    }

    $pass->getActiveList();
    $args = array_merge($args, array('pass' => $pass,
                                     'status_msg' => $status_msg,
                                     'admin_action' => 'passes'));
    View::renderTemplate('Admin/passes.html', $args);
  }

  public function capturesAction($args) {
    $capture = $this->loadModel('Capture');
    $total_pages = $capture->totalPages(Config::ADMIN_CAPTURES_PER_PAGE);

    # pagination - and check for sanity
    $page_number = 1;
    if (array_key_exists('page_no', $args) and $args['page_no'] > 0) $page_number = $args['page_no'];
    if ($page_number > $total_pages) $page_number = $total_pages;

    $capture->getList($page_number, Config::ADMIN_CAPTURES_PER_PAGE);
    $args = array_merge($args, array('capture' => $capture,
                                     'cur_page' => $page_number,
                                     'page_count' => $total_pages,
                                     'admin_action' => 'captures'));

    View::renderTemplate('Admin/captures.html', $args);
  }

  # TODO: This is not very DRY between this and the above function - do
  #       something about this in the future
  public function deleteCaptureAction($args) {
    $lang = \Lib\Lang::strings();
    $capture = $this->loadModel('Capture');
    $pass = $this->loadModel('Pass');

    # attempt to delete the user-specified capture
    $status_msg = 'Fail';
    if (array_key_exists('id', $args) and $args['id'] > 0) {
      $capture_id = $args['id'];
      $capture->getEnhancements($capture_id);
      $capture->getImagePath($capture_id);

      # delete images from disk
      foreach ($capture->enhancements as $enhancement) {
        $img = Config::IMAGE_PATH . '/' . $capture->image_path . $enhancement;
        $thumb = Config::THUMB_PATH . '/' . $capture->image_path . $enhancement;

        try {
          if (file_exists($img)) { unlink($img); }
        } catch (exception $e) {
          error_log("Could not delete file: " . $img . " - " . $e);
        }

        try {
          if (file_exists($thumb)) { unlink($thumb); }
        } catch (exception $e) {
          error_log("Could not delete file: " . $thumb . " - " . $e);
        }
      }

      # remove capture and pass records from database
      $capture->getStartEpoch($capture_id);
      $capture->deleteById($capture_id);
      $pass->deleteByPassStart($capture->start_epoch);
      $status_msg = 'Success';
    } else {
      $status_msg = $lang['fail_delete_missing_id'];
    }

    $total_pages = $capture->totalPages(Config::ADMIN_CAPTURES_PER_PAGE);

    # pagination - and check for sanity
    $page_number = 1;
    if (array_key_exists('page_no', $args) and $args['page_no'] > 0) $page_number = $args['page_no'];
    if ($page_number > $total_pages) $page_number = $total_pages;

    $capture->getList($page_number, Config::ADMIN_CAPTURES_PER_PAGE);
    $args = array_merge($args, array('capture' => $capture,
                                     'cur_page' => $page_number,
                                     'page_count' => $total_pages,
                                     'status_msg' => $status_msg,
                                     'admin_action' => 'captures'));

    View::renderTemplate('Admin/captures.html', $args);
  }

  # [Claude AI edit] START - bulk deletion support ("Delete selected" button)
  #
  # The two private helpers below intentionally perform the exact same steps as
  # the existing deletePassAction/deleteCaptureAction endpoints (which are left
  # untouched to avoid regressions); the new deleteSelected*Action endpoints
  # simply loop those steps over a POSTed list of ids.

  # shared single-pass deletion (atrm unschedule + database record removal)
  private function deleteOnePass($pass, $pass_start_id) {
    $pass->getATJobId($pass_start_id);

    # attempt to remove the job ID
    try {
      echo shell_exec("sudo -u " . escapeshellarg(Config::STATION_USER) . " /usr/bin/atrm " . escapeshellarg($pass->at_job_id) . " 2>&1");
    } catch (exception $e) {
      error_log("Could not delete pass job ID using atrm for job ID: " . $pass->at_job_id . " - " . $e);
    }

    # attempt to delete the database record
    try {
      $pass->deleteByPassStart($pass_start_id);
    } catch (exception $e) {
      error_log("Could not delete pass from database for pass ID: " . $pass_start_id . " - " . $e);
    }
  }

  # shared single-capture deletion (images + thumbnails + database records)
  private function deleteOneCapture($capture, $pass, $capture_id) {
    $capture->getEnhancements($capture_id);
    $capture->getImagePath($capture_id);

    # delete images from disk
    foreach ($capture->enhancements as $enhancement) {
      $img = Config::IMAGE_PATH . '/' . $capture->image_path . $enhancement;
      $thumb = Config::THUMB_PATH . '/' . $capture->image_path . $enhancement;

      try {
        if (file_exists($img)) { unlink($img); }
      } catch (exception $e) {
        error_log("Could not delete file: " . $img . " - " . $e);
      }

      try {
        if (file_exists($thumb)) { unlink($thumb); }
      } catch (exception $e) {
        error_log("Could not delete file: " . $thumb . " - " . $e);
      }
    }

    # remove capture and pass records from database
    $capture->getStartEpoch($capture_id);
    $capture->deleteById($capture_id);
    $pass->deleteByPassStart($capture->start_epoch);
  }

  # deletes every pass whose pass_start id was POSTed via pass_start_ids[]
  # (checkbox selection in the admin passes view)
  public function deleteSelectedPassesAction($args) {
    $lang = \Lib\Lang::strings();
    $pass = $this->loadModel('Pass');

    $status_msg = array_key_exists('fail_delete_none_selected', $lang)
                  ? $lang['fail_delete_none_selected'] : 'No items selected';
    if ($_SERVER['REQUEST_METHOD'] === 'POST' &&
        isset($_POST['pass_start_ids']) && is_array($_POST['pass_start_ids'])) {
      $deleted = 0;
      foreach ($_POST['pass_start_ids'] as $pass_start_id) {
        # only accept sane numeric identifiers
        if (is_numeric($pass_start_id) && $pass_start_id > 0) {
          $this->deleteOnePass($pass, intval($pass_start_id));
          $deleted += 1;
        }
      }
      if ($deleted > 0) $status_msg = 'SuccessBulk';
    }

    $pass->getActiveList();
    $args = array_merge($args, array('pass' => $pass,
                                     'status_msg' => $status_msg,
                                     'admin_action' => 'passes'));
    View::renderTemplate('Admin/passes.html', $args);
  }

  # deletes every capture whose id was POSTed via capture_ids[]
  # (checkbox selection in the admin captures view)
  public function deleteSelectedCapturesAction($args) {
    $lang = \Lib\Lang::strings();
    $capture = $this->loadModel('Capture');
    $pass = $this->loadModel('Pass');

    $status_msg = array_key_exists('fail_delete_none_selected', $lang)
                  ? $lang['fail_delete_none_selected'] : 'No items selected';
    if ($_SERVER['REQUEST_METHOD'] === 'POST' &&
        isset($_POST['capture_ids']) && is_array($_POST['capture_ids'])) {
      $deleted = 0;
      foreach ($_POST['capture_ids'] as $capture_id) {
        # only accept sane numeric identifiers
        if (is_numeric($capture_id) && $capture_id > 0) {
          $this->deleteOneCapture($capture, $pass, intval($capture_id));
          $deleted += 1;
        }
      }
      if ($deleted > 0) $status_msg = 'SuccessBulk';
    }

    # preserve the page the user was on (submitted as a hidden form field)
    if (isset($_POST['page_no']) && is_numeric($_POST['page_no'])) {
      $args['page_no'] = intval($_POST['page_no']);
    }

    $total_pages = $capture->totalPages(Config::ADMIN_CAPTURES_PER_PAGE);

    # pagination - and check for sanity
    $page_number = 1;
    if (array_key_exists('page_no', $args) and $args['page_no'] > 0) $page_number = $args['page_no'];
    if ($page_number > $total_pages) $page_number = $total_pages;

    $capture->getList($page_number, Config::ADMIN_CAPTURES_PER_PAGE);
    $args = array_merge($args, array('capture' => $capture,
                                     'cur_page' => $page_number,
                                     'page_count' => $total_pages,
                                     'status_msg' => $status_msg,
                                     'admin_action' => 'captures'));

    View::renderTemplate('Admin/captures.html', $args);
  }
  # [Claude AI edit] END - bulk deletion support

  # the Live log moved to /log (LogController); old bookmarks land there
  public function logAction($args) {
    header('Location: /log', true, 301);
    exit;
  }
}

?>
