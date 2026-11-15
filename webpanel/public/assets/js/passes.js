// Passes page: station bar, next pass / recording card, live row states, day/night
// icons, folding of earlier passes, and a tapped pass opens on the Satellites tab's map.
(function () {
  'use strict';
  var T = window.RL1_PASS_TEXT || {};
  var tr = window.tr || function (k, d) { return d; };
  var U = { h: tr('unit_h', 'h'), min: tr('unit_min', 'min'), s: tr('unit_s', 's') };
  var list = document.getElementById('passes');
  if (!list) { return; }

  var LAT = parseFloat(list.dataset.lat), LON = parseFloat(list.dataset.lon);
  var SUN_MIN = parseFloat(list.dataset.sunMin || '0');
  var rows = Array.prototype.slice.call(list.querySelectorAll('.pass-row')).map(function (el) {
    return {
      el: el,
      sat: el.dataset.sat,
      start: parseInt(el.dataset.start, 10) * 1000,
      end: parseInt(el.dataset.end, 10) * 1000,
      elev: parseInt(el.dataset.elev, 10),
      dir: el.dataset.dir,
      captured: !!el.dataset.capture,
      skipped: el.classList.contains('skipped'),
      status: el.querySelector('.st-live')
    };
  });

  // ---- helpers ----------------------------------------------------------------
  function pad(n) { return (n < 10 ? '0' : '') + n; }
  // times in the station's time zone, like the rest of the page (rendered by PHP)
  var TZ = list.dataset.tz || undefined;
  function hhmm(ms) {
    try {
      return new Date(ms).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });
    } catch (e) { var d = new Date(ms); return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  }

  function grid(lat, lon) {                       // Maidenhead locator, 6 characters
    var a = lon + 180, b = lat + 90, A = 'ABCDEFGHIJKLMNOPQR';
    return A[Math.floor(a / 20)] + A[Math.floor(b / 10)] +
      Math.floor((a % 20) / 2) + Math.floor(b % 10) +
      'abcdefghijklmnopqrstuvwx'[Math.floor((a % 2) * 12)] +
      'abcdefghijklmnopqrstuvwx'[Math.floor((b % 1) * 24)];
  }

  function compass(az) {
    var p = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
    var letters = tr('compass_letters', 'NESW');   // the page language's N, E, S, W
    return p[Math.round(((az % 360) + 360) % 360 / 22.5) % 16].replace(/[NESW]/g, function (c) {
      return letters.charAt('NESW'.indexOf(c));
    });
  }

  // sun elevation (degrees) at the station - low-precision solar formulas (Astronomical Almanac), good to a fraction of a degree
  function sunElevation(ms) {
    var rad = Math.PI / 180, d = ms / 86400000 + 2440587.5 - 2451545.0;
    var g = (357.529 + 0.98560028 * d) * rad;
    var q = 280.459 + 0.98564736 * d;
    var L = (q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * rad;
    var e = (23.439 - 0.00000036 * d) * rad;
    var ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L));
    var dec = Math.asin(Math.sin(e) * Math.sin(L));
    var gmst = (18.697374558 + 24.06570982441908 * d) % 24;
    var ha = (gmst * 15 + LON) * rad - ra;
    var lat = LAT * rad;
    return Math.asin(Math.sin(lat) * Math.sin(dec) + Math.cos(lat) * Math.cos(dec) * Math.cos(ha)) / rad;
  }

  function duration(ms, withSeconds) {
    var s = Math.max(0, Math.round(ms / 1000)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    if (h > 0) { return h + ' ' + U.h + ' ' + m + ' ' + U.min; }
    if (withSeconds || m < 10) { return m + ' ' + U.min + ' ' + pad(s % 60) + ' ' + U.s; }
    return m + ' ' + U.min;
  }

  // ---- static parts -------------------------------------------------------------
  var gridEl = document.getElementById('station-grid');
  if (gridEl && !isNaN(LAT)) { gridEl.textContent = grid(LAT, LON); }

  rows.forEach(function (r) {
    r.day = sunElevation((r.start + r.end) / 2) > SUN_MIN;
    var dn = r.el.querySelector('.c-dn');
    dn.innerHTML = '<i class="fas fa-' + (r.day ? 'sun' : 'moon') + '"></i>';
    dn.title = r.day ? T.day : T.night;
    var from = r.el.querySelector('.dir-from');
    if (from) { from.textContent = tr('from', 'from') + ' ' + compass(parseFloat(from.dataset.az)); }
  });

  // ---- earlier passes fold --------------------------------------------------------
  var showEarlier = false;
  function updateFolds(now) {
    Array.prototype.forEach.call(list.querySelectorAll('.pass-day'), function (day) {
      var btn = day.querySelector('.earlier-toggle');
      var earlier = day.querySelectorAll('.pass-row.past').length;
      if (!earlier) { btn.hidden = true; day.classList.remove('folded'); return; }
      btn.hidden = false;
      day.classList.toggle('folded', !showEarlier);
      btn.setAttribute('aria-expanded', showEarlier ? 'true' : 'false');
      btn.innerHTML = showEarlier ? '<i class="fas fa-chevron-up"></i> ' + T.hide
                                  : '<i class="fas fa-chevron-down"></i> ' + earlier + ' ' + T.earlier;
    });
  }
  list.addEventListener('click', function (ev) {
    var btn = ev.target.closest('.earlier-toggle');
    if (btn) { showEarlier = !showEarlier; updateFolds(Date.now()); return; }
    var head = ev.target.closest('.day-head');
    if (head) { toggleDay(head.parentNode); }
  });
  list.addEventListener('keydown', function (ev) {
    var head = ev.target.closest && ev.target.closest('.day-head');
    if (head && ev.target === head && (ev.key === 'Enter' || ev.key === ' ')) { ev.preventDefault(); toggleDay(head.parentNode); }
  });

  // ---- collapsible days: today open, the others closed, unless opened or closed by hand
  // (kept for this browser tab, so the half-hourly reload doesn't undo it) -------------------
  var dayState = {};
  try { dayState = JSON.parse(sessionStorage.getItem('rl1-days') || '{}'); } catch (e) {}
  var days = Array.prototype.slice.call(list.querySelectorAll('.pass-day'));
  var openByDefault = list.querySelector('.pass-day.is-today') || days[0];
  function setDay(day, open) {
    day.classList.toggle('collapsed', !open);
    day.querySelector('.day-head').setAttribute('aria-expanded', open ? 'true' : 'false');
  }
  function toggleDay(day) {
    var open = day.classList.contains('collapsed');
    setDay(day, open);
    dayState[day.dataset.day] = open;
    try { sessionStorage.setItem('rl1-days', JSON.stringify(dayState)); } catch (e) {}
  }
  days.forEach(function (day) {
    var key = day.dataset.day;
    setDay(day, key in dayState ? dayState[key] : day === openByDefault);
    // summary shown while closed: number of passes per satellite and the best elevation
    var rowsOfDay = day.querySelectorAll('.pass-row:not(.skipped)'), best = 0, per = {};
    Array.prototype.forEach.call(rowsOfDay, function (r) {
      best = Math.max(best, parseInt(r.dataset.elev, 10) || 0);
      var c = /sat-(m2[34])/.exec(r.className); c = c ? c[1] : 'other';
      per[c] = (per[c] || 0) + 1;
    });
    var html = rowsOfDay.length + ' ' + tr('passes_lower', 'passes');
    Object.keys(per).sort().forEach(function (c) { html += '<span class="sat-dot sat-' + c + '"></span>' + per[c]; });
    if (best) { html += ' · ' + tr('best', 'best') + ' ' + best + '°'; }
    day.querySelector('.day-sum').innerHTML = html;
  });

  // ---- live state -------------------------------------------------------------------
  var card = document.getElementById('next-card');
  var el = function (id) { return document.getElementById(id); };
  var stateEl = document.getElementById('station-state');
  var lastPastCount = -1;

  function tick() {
    var now = Date.now(), live = null, next = null, pastCount = 0;
    rows.forEach(function (r) {
      var isLive = !r.skipped && now >= r.start && now < r.end;
      var isPast = now >= r.end;
      r.el.classList.toggle('live', isLive);
      r.el.classList.toggle('past', isPast);
      if (isPast) { pastCount++; }
      if (r.status) {
        r.status.className = 'st-live' + (isLive ? ' rec' : (isPast && !r.captured ? ' fas fa-times missed' : ''));
        r.status.title = isLive ? T.recording : (isPast && !r.captured ? T.missed : '');
      }
      if (isLive && !live) { live = r; }
      if (!r.skipped && now < r.start && !next) { next = r; }
    });

    if (pastCount !== lastPastCount) { lastPastCount = pastCount; updateFolds(now); }

    var show = live || next;
    if (stateEl) {
      stateEl.className = 'station-state' + (live ? ' rec' : '');
      stateEl.lastChild.textContent = live ? T.recording : (next ? T.waiting : T.idle);
    }
    if (!show) { card.hidden = true; return; }
    card.hidden = false;
    card.className = 'next-card sat-' + (show.el.classList.contains('sat-m24') ? 'm24' : 'm23') + (live ? ' rec' : '');
    el('next-label').textContent = live ? T.recording : T.next;
    el('next-count').textContent = live ? duration(show.end - now, true) + ' ' + T.left
                                        : tr('in_time', 'in') + ' ' + duration(show.start - now, false);
    el('next-chip').textContent = show.sat.replace('METEOR-', '');
    el('next-times').textContent = hhmm(show.start) + ' – ' + hhmm(show.end);
    el('next-extra').innerHTML = show.elev + '° ' + tr('max', 'max') + ' · <i class="fas fa-arrow-' +
      (show.dir === 'Northbound' ? 'up' : 'down') + '"></i> ' + (show.dir === 'Northbound' ? T.north : T.south);
    el('next-daynight').innerHTML = '<i class="fas fa-' + (show.day ? 'sun' : 'moon') + '"></i> ' + (show.day ? T.day : T.night);
    el('next-bar').style.width = live ? Math.min(100, (now - show.start) / (show.end - show.start) * 100) + '%' : '0';
  }
  tick();
  setInterval(tick, 1000);

  // ---- show a pass on the map: the Satellites tab draws its track --------------------------
  var mapUrl = list.dataset.map;
  function open(r) {
    window.location.href = mapUrl + '#pass=' + encodeURIComponent(r.sat) + '|' + r.start / 1000 + '|' + r.end / 1000;
  }
  if (mapUrl) {
    rows.forEach(function (r) {
      r.el.addEventListener('click', function (ev) { if (!ev.target.closest('a')) { open(r); } });
      r.el.addEventListener('keydown', function (ev) {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); open(r); }
      });
    });
  }

  // pick up schedule changes (the scheduler runs nightly and after reboots)
  setTimeout(function () { if (!document.hidden) { window.location.reload(); } }, 30 * 60000);
})();
