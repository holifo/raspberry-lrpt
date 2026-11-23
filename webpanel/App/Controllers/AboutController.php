<?php

# About tab (/about; menu "About"; /meteor redirects here): at the top the station and its software
# (installed version, the update check's result from Lib\Update, credits), then the Meteor-M
# series this station receives
# (the satellites working now, every launch so far, the planned ones, the LRPT signal and the
# instruments) and, as an extra when iss_sstv is on, the ISS: its card, its amateur radio and the
# year's ARISS SSTV events (ISS / ISS_EVENTS / ISS_SOURCES). The facts are kept
# here in SERIES / SOURCES; update them (and CHECKED) when a launch happens or a plan changes.
# The notes are language keys (mi_n_*), so new text needs all nine language files.

namespace App\Controllers;

use Lib\View;

class AboutController extends \Lib\Controller {
  # when the facts below were last checked against the sources
  const CHECKED = '2026-11-16';

  # status: operational, retired, failed (launch), damaged (no LRPT), planned.
  # launch: Y-m-d when it flew; for planned ones a year or a range ('2027–2028').
  const SERIES = array(
    array('name' => 'Meteor-M No. 1', 'launch' => '2009-09-17', 'site' => 'Baikonur', 'cospar' => '2009-049A',
          'norad' => 35865, 'status' => 'retired', 'note' => 'mi_n_m1'),
    array('name' => 'Meteor-M No. 2', 'launch' => '2014-07-08', 'site' => 'Baikonur', 'cospar' => '2014-037A',
          'norad' => 40069, 'status' => 'retired', 'note' => 'mi_n_m2'),
    array('name' => 'Meteor-M No. 2-1', 'launch' => '2017-11-28', 'site' => 'Vostochny', 'cospar' => null,
          'norad' => null, 'status' => 'failed', 'note' => 'mi_n_m21'),
    array('name' => 'Meteor-M No. 2-2', 'launch' => '2019-07-05', 'site' => 'Vostochny', 'cospar' => '2019-038A',
          'norad' => 44387, 'status' => 'damaged', 'note' => 'mi_n_m22'),
    array('name' => 'Meteor-M No. 2-3', 'short' => 'M2 3', 'colour' => 'm23', 'launch' => '2023-06-27',
          'site' => 'Vostochny', 'cospar' => '2023-091A', 'norad' => 57166, 'status' => 'operational', 'note' => 'mi_n_m23'),
    array('name' => 'Meteor-M No. 2-4', 'short' => 'M2 4', 'colour' => 'm24', 'launch' => '2024-02-29',
          'site' => 'Vostochny', 'cospar' => '2024-039A', 'norad' => 59051, 'status' => 'operational', 'note' => 'mi_n_m24'),
    array('name' => 'Meteor-M No. 2-5', 'launch' => '2027–2028', 'year' => 2027.5, 'site' => 'Vostochny',
          'status' => 'planned', 'note' => 'mi_n_m25'),
    array('name' => 'Meteor-M No. 2-6', 'launch' => '2028', 'year' => 2028.5, 'site' => 'Vostochny',
          'status' => 'planned', 'note' => 'mi_n_m26'),
    array('name' => 'Meteor-MP No. 1', 'launch' => '2032', 'year' => 2032.3, 'site' => 'Vostochny',
          'status' => 'planned', 'note' => 'mi_n_mp'),
    array('name' => 'Meteor-M No. 2-7', 'launch' => '2032', 'year' => 2032.7, 'site' => 'Vostochny',
          'status' => 'planned', 'note' => 'mi_n_m27'),
    array('name' => 'Meteor-M No. 2-8', 'launch' => '2033', 'year' => 2033.5, 'site' => 'Vostochny',
          'status' => 'planned', 'note' => 'mi_n_m27'),
  );

  const SOURCES = array(
    array('WMO OSCAR: Meteor-M N2-5', 'https://space.oscar.wmo.int/satellites/view/meteor_m_n2_5'),
    array("Gunter's Space Page: Meteor-M 2-1 … 2-8", 'https://space.skyrocket.de/doc_sdat/meteor-m-2-1.htm'),
    array('RussianSpaceWeb: Meteor-M', 'https://russianspaceweb.com/meteor-m.html'),
    array('RTL-SDR.com: Meteor M2 has failed', 'https://www.rtl-sdr.com/the-meteor-m2-lrpt-weather-satellite-has-failed/'),
    array('Interfax: M2-3 and M2-4 join Cospas-Sarsat', 'https://www.interfax.com/newsroom/top-stories/114684/'),
    array('SatNOGS DB: METEOR M2-4', 'https://db.satnogs.org/satellite/59051'),
  );

  # the ISS (iss_sstv): an extra, shown under the Meteors
  const ISS = array('name' => 'International Space Station', 'short' => 'ISS', 'launch' => '1998-11-20',
                    'crewed' => '2000-11-02', 'site' => 'Baikonur', 'cospar' => '1998-067A', 'norad' => 25544);
  # ARISS SSTV events of the year: dates, frequency (MHz), mode; 'note' = a language key
  const ISS_EVENTS = array(
    array('name' => 'Series 31', 'from' => '2026-04-10', 'to' => '2026-04-14', 'freq' => '437.550', 'mode' => 'Robot 36'),
    array('name' => 'Series 32', 'from' => '2026-05-08', 'to' => '2026-05-12', 'freq' => '437.550', 'mode' => 'Robot 36'),
    array('name' => 'Series 34', 'from' => '2026-10-22', 'to' => '2026-10-26', 'freq' => '437.550 / 145.800', 'mode' => 'Robot 36',
          'note' => 'iss_ev_differ'),
  );
  const ISS_SOURCES = array(
    array('ARISS: current status of ISS stations', 'https://www.ariss.org/current-status-of-iss-stations.HTML'),
    array('AMSAT: amateur radio on the ISS', 'https://www.amsat.org/amateur-radio-on-the-iss/'),
    array('AMSAT News Service: ARISS SSTV Series 31 and 32', 'https://www.amsat.org/?p=64506'),
    array('AMSAT-UK: ISS Slow Scan TV Oct 22-26', 'https://amsat-uk.org/tag/iss'),
    array('IARU Region 1: ARSPEX news', 'https://www.iaru-r1.org/about-us/committees-and-working-groups/arspex/'),
    array('NASA: the station deorbit spacecraft', 'https://www.nasa.gov/blogs/spacestation/2023/09/20/nasa-seeks-proposals-from-us-industry-for-station-deorbit-spacecraft'),
  );

  public function indexAction($args) {
    $now = time();
    $sats = array();
    foreach (self::SERIES as $s) {
      $flown = preg_match('/^\d{4}-\d{2}-\d{2}$/', $s['launch']);
      $ts = $flown ? strtotime($s['launch'] . ' 12:00') : null;
      $year = $flown ? (int) date('Y', $ts) + ((int) date('z', $ts)) / 365 : $s['year'];
      $sats[] = array_merge($s, array(
        'flown' => (bool) $flown,
        'ts' => $ts,
        'years' => $flown && $s['status'] == 'operational' ? round(($now - $ts) / 86400 / 365.25, 1) : null,
        # position on the timeline (2009 … 2034)
        'pos' => round(($year - 2009) / 25 * 100, 2),
      ));
    }
    $iss = null;
    if (defined('Config\\Config::ISS_SSTV') && \Config\Config::ISS_SSTV) {
      $iss = array_merge(self::ISS, array(
        'ts' => strtotime(self::ISS['launch'] . ' 12:00'),
        'crewed_ts' => strtotime(self::ISS['crewed'] . ' 12:00'),
        'years' => round(($now - strtotime(self::ISS['launch'] . ' 12:00')) / 86400 / 365.25, 1),
        'events' => array_map(function ($e) use ($now) {
          return array_merge($e, array('from_ts' => strtotime($e['from'] . ' 12:00'), 'to_ts' => strtotime($e['to'] . ' 12:00'),
                                       'past' => strtotime($e['to'] . ' 23:59') < $now));
        }, self::ISS_EVENTS),
        'freq' => defined('Config\\Config::ISS_SSTV_FREQ') ? \Config\Config::ISS_SSTV_FREQ : '437.550',
        'sources' => self::ISS_SOURCES,
      ));
    }
    View::renderTemplate('About/index.html', array_merge($args, array(
      'page' => 'about', 'update' => \Lib\Update::status(), 'photo' => self::photo(), 'sats' => $sats, 'sources' => self::SOURCES, 'iss' => $iss,
      # release notes (Lib\Changelog reads CHANGELOG.md, copied next to the web panel by the install)
      'changes' => \Lib\Changelog::releases('https://github.com/holifo/raspberry-lrpt'),
      'checked' => strtotime(self::CHECKED . ' 12:00'), 'now_year' => (int) date('Y'),
      'now_pos' => round(((int) date('Y') + ((int) date('z')) / 365 - 2009) / 25 * 100, 2))));
  }

  # The station photo for the Station tab (scripts/station_photo.sh writes IMAGE_PATH/station/photo.jpg
  # and photo.json with the caption); null when there is none.
  private static function photo() {
    $dir = \Config\Config::IMAGE_PATH . '/station';
    $f = $dir . '/photo.jpg';
    if (!is_file($f)) { return null; }
    $meta = @json_decode((string) @file_get_contents($dir . '/photo.json'), true);
    $size = @getimagesize($f);
    return [
      'url' => '/images/station/photo.jpg?v=' . filemtime($f),
      'caption' => is_array($meta) && isset($meta['caption']) ? (string) $meta['caption'] : '',
      'w' => $size ? $size[0] : null,
      'h' => $size ? $size[1] : null,
    ];
  }
}

?>
