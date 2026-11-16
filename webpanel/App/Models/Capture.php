<?php

namespace App\Models;
use Config\Config;

class Capture extends \Lib\Model {
  public $enhancements;
  public $image_path;
  public $start_epoch;
  public $travel_direction;
  public $gain;
  public $info = [];

  # get a list of captures for the given page and total number
  # of configured images per page
  public function getList($page, $img_per_page) {
    $query = $this->db_conn->prepare("SELECT decoded_passes.id,
                                             predict_passes.pass_start,
                                             file_path,
                                             daylight_pass,
                                             sat_type,
                                             img_count,
                                             gain,
                                             predict_passes.sat_name,
                                             predict_passes.max_elev,
                                             predict_passes.pass_start_azimuth,
                                             predict_passes.direction,
                                             predict_passes.azimuth_at_max
                                             FROM decoded_passes
                                             INNER JOIN predict_passes
                                               ON predict_passes.pass_start = decoded_passes.pass_start
                                             ORDER BY decoded_passes.pass_start DESC LIMIT ? OFFSET ?;");
    $query->bindValue(1, $img_per_page);
    $query->bindValue(2, $img_per_page * ($page-1));
    $result = $query->execute();

    $captures = [];
    $i = 0;
    while ($row = $result->fetchArray()) {
      $captures[$i] = $row;
      $i++;
    }

    $this->list = $captures;
  }

  # get total number of pages to display images given the
  # passed number of images per page
  public function totalPages($images_per_page) {
    $decoded_passes = $this->db_conn->querySingle("SELECT count() FROM decoded_passes;");
    return ceil($decoded_passes/$images_per_page);
  }

  # get the enhancements for the particular capture
  public function getEnhancements($id) {
    $query = $this->db_conn->prepare('SELECT daylight_pass,
                                             sat_type,
                                             file_path,
                                             img_count,
                                             has_spectrogram,
                                             has_polar_az_el,
                                             has_polar_direction,
                                             has_pristine,
                                             has_histogram
                                      FROM decoded_passes
                                      WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $pass = $result->fetchArray();

    # the settings list for a day or night pass comes first, in its order; every other image
    # this pass made follows, so new SatDump composites show up without a settings change
    $list = ($pass['daylight_pass'] == 1) ? Config::METEOR_DAY_ENHANCEMENTS : Config::METEOR_NIGHT_ENHANCEMENTS;
    $enhancements = [];
    foreach (preg_split('/\s+/', trim($list)) as $name) {
      if ($name !== '' && file_exists(Config::IMAGE_PATH . '/' . $pass['file_path'] . '-' . $name . '.jpg')) {
        $enhancements[] = '-' . $name . '.jpg';
      }
    }
    $prefix = Config::IMAGE_PATH . '/' . $pass['file_path'] . '-';
    $others = [];
    foreach (glob(addcslashes($prefix, '*?[') . '*.jpg') ?: [] as $file) {
      $e = '-' . substr($file, strlen($prefix));
      if (in_array($e, $enhancements) || in_array($e, ['-website-thumbnail.jpg', '-polar-azel.jpg', '-histogram.jpg'])) { continue; }
      $others[] = $e;
    }
    sort($others, SORT_NATURAL);    # SSTV_2 before SSTV_10
    $enhancements = array_merge($enhancements, $others);

    # capture spectrogram if one exists
    if ($pass['has_spectrogram'] == '1') {
      array_push($enhancements, '-spectrogram.png');
    }
    # capture polar azimuth elevation graph if one exists
    if ($pass['has_polar_az_el'] == '1') {
      array_push($enhancements, '-polar-azel.jpg');
    }
    # capture polar direction graph if one exists
    if ($pass['has_polar_direction'] == '1') {
      array_push($enhancements, '-polar-direction.png');
    }
    # capture pristine if one exists
    if ($pass['has_pristine'] == '1') {
      array_push($enhancements, '-pristine.png');
    }
    if ($pass['has_histogram'] == '1') {
      array_push($enhancements, '-histogram.jpg');
    }

    $this->enhancements = $enhancements;
  }

  # get the image path for the specific capture
  public function getImagePath($id) {
    $query = $this->db_conn->prepare('SELECT file_path FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $image = $result->fetchArray();

    $this->image_path = $image['file_path'];
  }

  # get the gain for the specific capture
  public function getGain($id) {
    $query = $this->db_conn->prepare('SELECT gain FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $image = $result->fetchArray();

    $this->gain = $image['gain'];
  }

  # pass details for the page head of one capture (satellite, times, elevation, direction)
  public function getPassInfo($id) {
    $query = $this->db_conn->prepare('SELECT decoded_passes.pass_start,
                                             decoded_passes.daylight_pass,
                                             predict_passes.sat_name,
                                             predict_passes.pass_end,
                                             predict_passes.max_elev,
                                             predict_passes.direction
                                      FROM decoded_passes
                                      LEFT JOIN predict_passes
                                        ON predict_passes.pass_start = decoded_passes.pass_start
                                      WHERE decoded_passes.id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $this->info = $result->fetchArray() ?: [];
  }

  # the decoded frames (.cadu) kept for this capture, if any: name, size in MB
  public $recording = [];
  public function getRecording() {
    $file = Config::RECORDING_PATH . '/' . basename((string)$this->image_path) . '.cadu';
    if (!is_file($file)) {      # ISS SSTV passes keep their FM audio
      $file = Config::RECORDING_PATH . '/' . basename((string)$this->image_path) . '.wav';
    }
    if ($this->image_path && is_file($file)) {
      $this->recording = ['name' => basename($file), 'size' => round(filesize($file) / 1048576, 1)];
    }
  }

  # get the epoch start time for the capture
  public function getStartEpoch($id) {
    $query = $this->db_conn->prepare('SELECT pass_start FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
    $res = $result->fetchArray();

    $this->start_epoch = $res['pass_start'];
  }

  # delete a capture by id
  public function deleteById($id) {
    $query = $this->db_conn->prepare('DELETE FROM decoded_passes WHERE id = ?;');
    $query->bindValue(1, $id);
    $result = $query->execute();
  }
}

?>
