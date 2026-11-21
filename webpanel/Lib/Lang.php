<?php

namespace Lib;

use Config\Config;

# The web panel's language: the visitor's choice from the language button (cookie
# rl1-lang), otherwise lang_setting from settings.yml. Only languages in SWITCHABLE can be
# picked with the button; any App/Lang file still works as the station default.
class Lang {
  # the language menu: code => [name in that language, flag file in public/assets/img/flags].
  # The EU's five most spoken languages (English, German, French, Italian, Spanish) and Greek
  # for the station, then Chinese, Hindi and Arabic.
  const SWITCHABLE = [
    'en' => ['English', 'gb'],
    'de' => ['Deutsch', 'de'],
    'fr' => ['Français', 'fr'],
    'it' => ['Italiano', 'it'],
    'es' => ['Español', 'es'],
    'gr' => ['Ελληνικά', 'gr'],
    'cn' => ['中文', 'cn'],
    'hi' => ['हिन्दी', 'in'],
    'ar' => ['العربية', 'sa'],
  ];
  # BCP 47 tags for the HTML lang attribute, Intl date names and JS
  const LOCALES = ['gr' => 'el', 'cn' => 'zh-CN', 'kr' => 'ko'];
  # languages written right to left
  const RTL = ['ar'];

  public static function code() {
    $c = $_COOKIE['rl1-lang'] ?? '';
    if (isset(self::SWITCHABLE[$c])) { return $c; }
    return Config::LANG;
  }

  public static function dir() {
    return in_array(self::code(), self::RTL, true) ? 'rtl' : 'ltr';
  }

  public static function locale() {
    $c = self::code();
    return self::LOCALES[$c] ?? $c;
  }

  # English strings first, so a key missing in the chosen language falls back to English
  public static function strings() {
    static $cache = [];
    $c = self::code();
    if (!isset($cache[$c])) {
      $dir = dirname(__DIR__) . '/App/Lang/';
      $en = include($dir . 'en.php');
      $cache[$c] = ($c === 'en' || !is_file($dir . $c . '.php')) ? $en : array_merge($en, include($dir . $c . '.php'));
      # {freq}: the ISS SSTV frequency this station records (iss_sstv_frequency)
      $freq = defined('Config\Config::ISS_SSTV_FREQ') ? \Config\Config::ISS_SSTV_FREQ : '437.550';
      # {aprs_freq}: the ISS APRS frequency (iss_aprs_frequency)
      $aprs = defined('Config\Config::ISS_APRS_FREQ') ? \Config\Config::ISS_APRS_FREQ : '437.825';
      foreach ($cache[$c] as $k => $v) {
        if (is_string($v) && strpos($v, 'freq}') !== false) { $cache[$c][$k] = str_replace(array('{freq}', '{aprs_freq}'), array($freq, $aprs), $v); }
      }
    }
    return $cache[$c];
  }
}

?>
