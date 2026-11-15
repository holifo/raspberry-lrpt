<?php

# Meteor-M tab (/meteor): the Meteor-M series this station receives: the satellites working now,
# every launch so far, the planned ones, the LRPT signal and the instruments. The facts are kept
# here in SERIES / SOURCES; update them (and CHECKED) when a launch happens or a plan changes.
# The notes are language keys (mi_n_*), so new text needs all nine language files.

namespace App\Controllers;

use Lib\View;

class MeteorController extends \Lib\Controller {
  # when the facts below were last checked against the sources
  const CHECKED = '2026-11-15';

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
    View::renderTemplate('Meteor/index.html', array_merge($args, array(
      'page' => 'meteor', 'sats' => $sats, 'sources' => self::SOURCES,
      'checked' => strtotime(self::CHECKED . ' 12:00'), 'now_year' => (int) date('Y'),
      'now_pos' => round(((int) date('Y') + ((int) date('z')) / 365 - 2009) / 25 * 100, 2))));
  }
}

?>
