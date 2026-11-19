// Satellites tab (/satellite): sends the tapped pass to the live map frame, marks the pass in
// progress, makes the map's full-screen button work, shows the pass the Passes page linked
// to (#pass=<satellite>|<aos>|<los>, Unix seconds), and fills in the selected satellite's
// details from the map's 'rl1-sat-state' messages.
(function () {
  'use strict';
  var frame = document.getElementById('meteor-map-frame');
  if (!frame) { return; }
  var layout = document.querySelector('.sat-layout');
  var TZ = (layout && layout.dataset.tz) || undefined;
  var clearBtn = document.getElementById('sat-clear');
  var items = Array.prototype.slice.call(document.querySelectorAll('.sat-pass'));
  var selected = null;
  var chosen = null;                    // satellite picked with a tab or a pass; null = automatic

  function hhmm(ms) {
    try {
      return new Date(ms).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false });
    } catch (e) { var d = new Date(ms); return d.getHours() + ':' + ('0' + d.getMinutes()).slice(-2); }
  }

  // the map keeps a message that comes before its orbit data is loaded and draws it once ready
  function send(p) {
    if (!frame.contentWindow) { return; }
    frame.contentWindow.postMessage(p
      ? { type: 'rl1-pass', sat: p.sat, aos: p.aos, los: p.los, aosText: hhmm(p.aos), losText: hhmm(p.los) }
      : { type: 'rl1-pass', clear: true }, window.location.origin);
  }

  function show(p, el) {
    items.forEach(function (b) { b.classList.toggle('selected', b === el); });
    selected = p;
    if (p) { pick(p.sat); }
    if (clearBtn) { clearBtn.hidden = !p; }
    send(p);
  }

  items.forEach(function (b) {
    b.addEventListener('click', function () {
      var p = { sat: b.dataset.sat, aos: parseInt(b.dataset.start, 10) * 1000, los: parseInt(b.dataset.end, 10) * 1000 };
      if (selected && selected.sat === p.sat && selected.aos === p.aos) { show(null, null); }
      else { show(p, b); }
      if (window.innerWidth < 992) { frame.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
    });
  });
  if (clearBtn) { clearBtn.addEventListener('click', function () { show(null, null); }); }

  // a pass from the Passes page
  var m = /[#&]pass=([^|&]+)\|(\d+)\|(\d+)/.exec(decodeURIComponent(window.location.hash));
  if (m) {
    var want = { sat: m[1], aos: parseInt(m[2], 10) * 1000, los: parseInt(m[3], 10) * 1000 };
    var match = items.filter(function (b) {
      return b.dataset.sat === want.sat && parseInt(b.dataset.start, 10) * 1000 === want.aos;
    })[0] || null;
    selected = want;
    chosen = want.sat;
    items.forEach(function (b) { b.classList.toggle('selected', b === match); });
    if (clearBtn) { clearBtn.hidden = false; }
    if (match) { match.scrollIntoView({ block: 'nearest' }); }
  }
  // (re)send the chosen pass whenever the map frame (re)loads
  frame.addEventListener('load', function () { if (selected) { send(selected); } });
  if (selected && frame.contentDocument && frame.contentDocument.readyState === 'complete' &&
      frame.contentWindow.location.pathname === '/satellite/map') { send(selected); }

  // the pass in progress
  function tick() {
    var now = Date.now();
    items.forEach(function (b) {
      var live = now >= b.dataset.start * 1000 && now <= b.dataset.end * 1000;
      b.classList.toggle('live', live);
      var tag = b.querySelector('.sp-live');
      if (tag) { tag.hidden = !live; }
      if (now > b.dataset.end * 1000) { b.parentNode.hidden = true; }
    });
  }
  tick();
  setInterval(tick, 15000);

  // full screen: the map's own button asks for it; the map redraws itself to the new size
  if (window.RL1FS) {
    var toggleMap = RL1FS.bind(frame.parentNode, function (on) {
      frame.contentWindow.postMessage({ type: 'rl1-fullscreen-state', on: on }, window.location.origin);
    });
    window.addEventListener('message', function (ev) {
      if (ev.origin === window.location.origin && ev.source === frame.contentWindow &&
          ev.data && ev.data.type === 'rl1-fullscreen') { toggleMap(); }
    });
  }

  // ---- the selected satellite's details ---------------------------------------------------
  var T = window.RL1_SAT_TEXT || {};
  var tr = window.tr || function (k, d) { return d; };
  var infoBody = document.getElementById('si-body');
  var tabs = Array.prototype.slice.call(document.querySelectorAll('.si-tab'));
  var DOWNLINK = { 'METEOR-M2 3': '137.900 MHz LRPT', 'METEOR-M2 4': '137.900 MHz LRPT',
                   'ISS': (window.RL1_ISS_APRS ? '145.825 MHz APRS · ' : '') +                  // iss_aprs
                          (window.RL1_ISS_FREQ || '437.550') + ' MHz FM (SSTV, ARISS events)' };  // iss_sstv_frequency
  var COLOUR = { 'M2 3': 'm23', 'M2 4': 'm24', 'ISS': 'iss' };
  var lastState = null;

  function pick(sat) {
    chosen = sat;
    if (lastState) { render(lastState); }
  }
  tabs.forEach(function (t) { t.addEventListener('click', function () { pick(t.dataset.sat); }); });

  function esc(x) { return String(x).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function num(x, d) {
    try { return x.toLocaleString(document.documentElement.lang || 'en', { minimumFractionDigits: d, maximumFractionDigits: d }); }
    catch (e) { return x.toFixed(d); }
  }
  function compass(az) {
    var p = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
    var letters = tr('compass_letters', 'NESW');
    return p[Math.round(((az % 360) + 360) % 360 / 22.5) % 16].replace(/[NESW]/g, function (c) {
      return letters.charAt('NESW'.indexOf(c));
    });
  }
  function latlon(lat, lon) {
    var L = tr('compass_letters', 'NESW');
    return num(Math.abs(lat), 2) + '° ' + (lat >= 0 ? L.charAt(0) : L.charAt(2)) + ', ' +
           num(Math.abs(lon), 2) + '° ' + (lon >= 0 ? L.charAt(1) : L.charAt(3));
  }
  function span(ms) {                   // 1 h 05 min, 4 min 20 s
    var sec = Math.max(0, Math.round(ms / 1000)), h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), x = sec % 60;
    var H = tr('unit_h', 'h'), M = tr('unit_min', 'min'), S = tr('unit_s', 's');
    return h ? h + ' ' + H + ' ' + ('0' + m).slice(-2) + ' ' + M : m + ' ' + M + ' ' + ('0' + x).slice(-2) + ' ' + S;
  }
  function dayName(ms) {
    var f = function (t) { try { return new Date(t).toLocaleDateString('en-CA', { timeZone: TZ }); } catch (e) { return new Date(t).toDateString(); } };
    var d = f(ms), now = Date.now();
    if (d === f(now)) { return T.today || 'Today'; }
    if (d === f(now + 86400000)) { return T.tomorrow || 'Tomorrow'; }
    try { return new Date(ms).toLocaleDateString(document.documentElement.lang || 'en', { timeZone: TZ, weekday: 'short' }); }
    catch (e) { return ''; }
  }
  function row(label, value, cls) {
    return '<dt>' + esc(label) + '</dt><dd' + (cls ? ' class="' + cls + '"' : '') + '>' + value + '</dd>';
  }
  function head(label) { return '<div class="si-sec">' + esc(label) + '</div>'; }

  function current(state) {
    var sats = state.sats;
    if (chosen) { return sats.filter(function (x) { return x.name === chosen; })[0] || null; }
    // the pass being recorded (from the schedule), then a satellite in range, then the next to rise
    var rec = items.filter(function (b) { return b.classList.contains('live'); })[0];
    if (rec) {
      var r = sats.filter(function (x) { return x.name === rec.dataset.sat; })[0];
      if (r) { return r; }
    }
    var live = sats.filter(function (x) { return x.inRange; })[0];
    if (live) { return live; }
    return sats.slice().sort(function (a, b) {
      return (a.next ? a.next.aos : Infinity) - (b.next ? b.next.aos : Infinity);
    })[0] || null;
  }

  function render(state) {
    var s = current(state), now = state.time;
    tabs.forEach(function (t) {
      var on = !!s && t.dataset.sat === s.name;
      t.classList.toggle('active', on);
      t.setAttribute('aria-selected', on ? 'true' : 'false');
    });
    if (!s) { return; }
    var o = s.orbit, html = '';
    html += '<div class="si-name sat-' + (COLOUR[s.short] || 'm23') + '"><span class="sat-dot"></span>' + esc(s.name) +
      (s.inRange ? '<span class="si-badge on">' + esc(T.in_range || 'In range') + '</span>'
                 : '<span class="si-badge">' + esc(T.below || 'Below the horizon') + '</span>') + '</div>';
    html += '<dl>';
    html += head(T.now || 'Now');
    html += row(T.position || 'Position', latlon(s.lat, s.lon));
    html += row(T.altitude || 'Altitude', num(s.alt, 0) + ' km');
    html += row(T.speed || 'Speed', num(s.speed, 2) + ' km/s');
    html += row(T.azel || 'Azimuth / elevation', num(s.az, 0) + '° ' + compass(s.az) + ' · ' + num(s.el, 1) + '°',
                s.el >= s.minEl ? 'si-good' : (s.el < 0 ? 'si-dim' : ''));
    html += row(T.range || 'Distance', num(s.range, 0) + ' km');
    html += row(T.light || 'Sunlight', '<i class="fas fa-' + (s.sunlit ? 'sun' : 'moon') + ' dn"></i> ' +
                esc(s.sunlit ? (T.sunlit || 'In sunlight') : (T.shadow || "In Earth's shadow")));
    if (s.inRange && s.pass) {
      html += head(T.this_pass || 'This pass');
      html += row(T.los_in || 'LOS in', span(s.pass.los - now), 'si-good');
      html += row(T.window || 'AOS – LOS', hhmm(s.pass.aos) + ' – ' + hhmm(s.pass.los));
      html += row(T.max_el || 'Max elevation', num(s.pass.maxEl, 0) + '°');
    } else {
      html += head(T.next_pass || 'Next pass');
      if (s.next) {
        html += row(T.aos_in || 'AOS in', span(s.next.aos - now));
        html += row(T.window || 'AOS – LOS', esc(dayName(s.next.aos)) + ' ' + hhmm(s.next.aos) + ' – ' + hhmm(s.next.los));
        html += row(T.max_el || 'Max elevation', num(s.next.maxEl, 0) + '°');
      } else {
        html += row('', esc(T.none || 'None in the next 24 h'));
      }
    }
    html += head(T.orbit || 'Orbit');
    html += row(T.orbit_no || 'Orbit number', num(s.orbitNo, 0));
    html += row(T.period || 'Period', num(o.period, 1) + ' ' + tr('unit_min', 'min'));
    html += row(T.incl || 'Inclination', '<span title="' + esc(T.sso || 'sun-synchronous') + '">' + num(o.incl, 2) + '°</span>');
    html += row(T.height || 'Perigee / apogee', num(o.perigee, 0) + ' / ' + num(o.apogee, 0) + ' km');
    html += row(T.ids || 'NORAD / COSPAR', o.norad + ' / ' + esc(o.cospar));
    html += row(T.downlink || 'Downlink', esc(DOWNLINK[s.name] || '137.900 MHz LRPT'));
    var days = (now - o.epoch) / 86400000;
    html += row(T.tle_age || 'Orbit data age', (days < 1 ? span(now - o.epoch) : num(days, 1) + ' d'),
                days > 4 ? 'si-warn' : '');
    html += '</dl>';
    infoBody.innerHTML = html;
  }

  window.addEventListener('message', function (ev) {
    if (ev.origin !== window.location.origin || ev.source !== frame.contentWindow ||
        !ev.data || ev.data.type !== 'rl1-sat-state' || !infoBody) { return; }
    lastState = ev.data;
    render(lastState);
  });

  // pick up schedule changes (the scheduler runs nightly and after reboots)
  setTimeout(function () { if (!document.hidden) { window.location.reload(); } }, 60 * 60000);
})();
