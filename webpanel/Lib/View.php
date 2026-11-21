<?php

namespace Lib;

use Config\Config;

class View {
  # render a template using twig
  public static function renderTemplate($template, $args = []) {
    static $twig = null;

    # i18n strings for the visitor's language (Lib\Lang)
    $lang = Lang::strings();

    if ($twig === null) {
      $loader = new \Twig\Loader\FilesystemLoader(dirname(__DIR__) . '/App/Views');
      $twig = new \Twig\Environment($loader);
      $twig->addGlobal('lang', $lang);
      $twig->addGlobal('lang_code', Lang::code());
      $twig->addGlobal('lang_locale', Lang::locale());
      $twig->addGlobal('lang_switch', Lang::SWITCHABLE);
      $twig->addGlobal('lang_dir', Lang::dir());
      # the station software's version (VERSION, copied next to the web panel by the install)
      $vf = dirname(__DIR__) . '/VERSION';
      $twig->addGlobal('lrpt_version', is_readable($vf) ? trim(file_get_contents($vf)) : '');
      # the update check's result (Lib\Update), for the footer's "update available" note
      $twig->addGlobal('lrpt_update', Update::status());
      # weekday(ts) / weekday(ts, 'EEEE'): the weekday name in the page's language
      $twig->addFilter(new \Twig\TwigFilter('weekday', function ($ts, $pattern = 'EEE') {
        if (class_exists('IntlDateFormatter')) {
          $f = new \IntlDateFormatter(Lang::locale(), \IntlDateFormatter::NONE, \IntlDateFormatter::NONE,
                                      Config::TIMEZONE, null, $pattern);
          $out = $f->format((int)$ts);
          if ($out !== false) { return $out; }
        }
        return date($pattern === 'EEEE' ? 'l' : 'D', (int)$ts);
      }));
      # asset('/assets/js/x.js') adds the file's modification time, so browsers fetch a
      # changed file after an update instead of using their cached copy
      $twig->addFunction(new \Twig\TwigFunction('asset', function ($path) {
        $mtime = @filemtime(dirname(__DIR__) . '/public' . $path);
        return $mtime ? $path . '?v=' . $mtime : $path;
      }));
    }

    echo $twig->render($template, $args);
  }
}

?>
