<?php

namespace Lib;

# The station software's release notes for the About page: CHANGELOG.md, copied next to the web
# panel by the install (like VERSION). Only the Raspberry-LRPT releases are read (the history
# from before the rename is left out). The file is the project's own Markdown; this turns the
# little of it that the changelog uses (### headings, "- " lists two deep, ``` code, `code`,
# **bold**, [links](…)) into HTML, escaping everything first.
class Changelog {
  const MAX = 40;   # releases shown; the full file is linked on GitHub

  public static function releases($repo = '') {
    $f = dirname(__DIR__) . '/CHANGELOG.md';
    if (!is_readable($f)) { return array(); }
    $out = array();
    $cur = null;
    foreach (preg_split('/\r?\n/', (string) file_get_contents($f)) as $line) {
      if (preg_match('/^# /', $line) && $cur !== null) { break; }          # "# Before the rename"
      if (preg_match('/^## Raspberry-LRPT v([0-9][0-9.]*)\s*(?:\(([0-9-]+)\))?/', $line, $m)) {
        if ($cur !== null) { $out[] = $cur; }
        if (count($out) >= self::MAX) { $cur = null; break; }
        $cur = array('version' => $m[1], 'date' => $m[2] ?? '', 'lines' => array());
        continue;
      }
      if ($cur !== null) { $cur['lines'][] = $line; }
    }
    if ($cur !== null && count($out) < self::MAX) { $out[] = $cur; }
    foreach ($out as &$r) {
      $r['html'] = self::html($r['lines'], $repo);
      $r['ts'] = $r['date'] ? strtotime($r['date'] . ' 12:00') : null;
      unset($r['lines']);
    }
    return $out;
  }

  private static function inline($text, $repo) {
    $s = htmlspecialchars($text, ENT_QUOTES, 'UTF-8');
    $codes = array();
    $s = preg_replace_callback('/`([^`]+)`/', function ($m) use (&$codes) {
      $codes[] = '<code>' . $m[1] . '</code>';
      return "\x01" . (count($codes) - 1) . "\x02";
    }, $s);
    $s = preg_replace('/\*\*(.+?)\*\*/', '<strong>$1</strong>', $s);
    $s = preg_replace_callback('/\[([^\]]+)\]\(([^)\s]+)\)/', function ($m) use ($repo) {
      $url = html_entity_decode($m[2], ENT_QUOTES, 'UTF-8');
      if (!preg_match('#^https?://#', $url)) {
        if ($repo === '' || !preg_match('#^[\w./-]+(\#[\w-]+)?$#', $url)) { return $m[1]; }
        $url = $repo . '/blob/main/' . ltrim($url, './');
      }
      return '<a href="' . htmlspecialchars($url, ENT_QUOTES, 'UTF-8') . '" target="_blank" rel="noopener">' . $m[1] . '</a>';
    }, $s);
    return preg_replace_callback("/\x01(\d+)\x02/", function ($m) use ($codes) { return $codes[(int) $m[1]]; }, $s);
  }

  private static function html($lines, $repo) {
    $html = '';
    $depth = 0;          # open <ul> levels
    $item = null;        # text of the list item being read
    $para = array();
    $code = null;
    $blank = false;      # the last line was empty
    $flushItem = function () use (&$item, &$html, $repo) {
      if ($item !== null) { $html .= '<li>' . self::inline($item, $repo); $item = null; }
    };
    $flushPara = function () use (&$para, &$html, $repo) {
      if ($para) { $html .= '<p>' . self::inline(implode(' ', $para), $repo) . '</p>'; $para = array(); }
    };
    $closeTo = function ($level) use (&$depth, &$html, $flushItem) {
      $flushItem();
      while ($depth > $level) { $html .= '</li></ul>'; $depth--; }
    };
    foreach ($lines as $line) {
      if ($code !== null) {
        if (preg_match('/^\s*```/', $line)) {
          $html .= '<pre><code>' . htmlspecialchars(implode("\n", $code), ENT_QUOTES, 'UTF-8') . '</code></pre>';
          $code = null;
        } else { $code[] = $line; }
        continue;
      }
      if (preg_match('/^\s*```/', $line)) { $flushPara(); $closeTo(0); $code = array(); continue; }
      if (trim($line) === '') { $flushPara(); $blank = true; continue; }
      $wasBlank = $blank;
      $blank = false;
      if (preg_match('/^#{3,6}\s+(.*)$/', $line, $m)) {
        $flushPara(); $closeTo(0);
        $html .= '<h4>' . self::inline($m[1], $repo) . '</h4>';
        continue;
      }
      if (preg_match('/^( *)[-*] (.*)$/', $line, $m)) {
        $flushPara();
        $level = strlen($m[1]) >= 2 ? 2 : 1;
        if ($level > $depth) {
          $flushItem();
          while ($depth < $level) { $html .= '<ul>'; $depth++; }
          # a nested list opens inside the open <li>, which the closing tags end later
        } else {
          $closeTo($level);
          $html .= '</li>';
        }
        $item = $m[2];
        continue;
      }
      if (($item !== null && !$wasBlank) || ($item !== null && preg_match('/^\s/', $line))) {
        $item .= ' ' . trim($line);          # a list item's next line
        continue;
      }
      $closeTo(0);
      $para[] = trim($line);
    }
    $flushPara(); $closeTo(0);
    if ($code !== null) {
      $html .= '<pre><code>' . htmlspecialchars(implode("\n", $code), ENT_QUOTES, 'UTF-8') . '</code></pre>';
    }
    return $html;
  }
}
