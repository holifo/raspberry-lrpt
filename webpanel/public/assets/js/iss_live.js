// Passes page: the live ISS panel (#iss-card). While an ISS pass is on (an ISS row's data-start /
// data-end, a minute either side) it polls /passes/isslive once a second. The ISS on its own
// RTL-SDR is recorded over the whole band (receive_iss.sh + iq_fm.py), so this draws:
//   - the whole band (2.38 MHz) as a spectrum and scrolling waterfall, the ISS frequency marked
//   - the ISS channel (±22 kHz) with the expected Doppler shift drawn on its waterfall
//   - the signal level in the channel and its history
//   - APRS: the stations Dire Wolf has decoded so far; SSTV: the FM audio 0-3 kHz as a waterfall
//   - the ISS on a live map (/satellite/map?live=ISS, with the APRS stations heard) beside the
//     stations list, or beside the newest SSTV picture live_sstv.sh has decoded
// Outside an ISS pass, or with the ISS sharing the Meteors' dongle, it shows nothing.
(function () {
  'use strict';
  var card = document.getElementById('iss-card');
  if (!card) { return; }
  var T = window.RL1_ISS_LIVE_TEXT || {};
  var $ = function (id) { return document.getElementById(id); };
  var rows = Array.prototype.slice.call(document.querySelectorAll('.pass-row.sat-iss[data-start]'));
  var C = {};
  ['il-wide', 'il-wide-wf', 'il-zoom', 'il-zoom-wf', 'il-hist', 'il-audio'].forEach(function (id) {
    C[id] = $(id); C[id + 'X'] = C[id].getContext('2d');
  });
  var timer = null, polling = false, seen = false, lastPass = null, lastT = 0, history = [], known = {};
  var scale = {};
  var DPR = window.devicePixelRatio || 1;

  function inPass() {
    var now = Date.now() / 1000;
    return rows.some(function (r) { return now >= r.dataset.start - 60 && now <= +r.dataset.end + 60; });
  }
  function size(c) {
    var w = c.clientWidth, h = c.clientHeight;
    if (!w || !h) { return; }
    var W = Math.round(w * DPR), H = Math.round(h * DPR);
    if (c.width !== W || c.height !== H) {
      var keep = c.width && c.height ? c.getContext('2d').getImageData(0, 0, c.width, c.height) : null;
      c.width = W; c.height = H;
      if (keep) { c.getContext('2d').putImageData(keep, 0, 0); }
    }
  }
  function colour(v) {                   // the Meteor panel's palette, violet-tinted top for the ISS
    var stops = [[11, 18, 32], [24, 50, 100], [60, 120, 170], [167, 139, 250], [250, 245, 255]];
    v = Math.max(0, Math.min(1, v)) * (stops.length - 1);
    var i = Math.min(stops.length - 2, Math.floor(v)), f = v - i, a = stops[i], b = stops[i + 1];
    return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
  }
  // a smoothed display range per plot: from just under the noise floor to just over the peaks
  function range(key, arr) {
    var s = arr.slice().sort(function (a, b) { return a - b; }), n = s.length;
    var lo = s[Math.floor(n * 0.2)], hi = s[n - 1], r = scale[key];
    if (!r) { r = scale[key] = { lo: lo, hi: Math.max(hi, lo + 12) }; }
    r.lo = r.lo * 0.9 + lo * 0.1;
    r.hi = Math.max(r.hi * 0.97 + hi * 0.03, r.lo + 12);
    return [r.lo - 4, r.hi + 2];
  }
  function line(c, x, arr, rg, colourStr, marks) {
    size(c);
    var w = c.width, h = c.height, n = arr.length, min = rg[0], max = rg[1];
    x.fillStyle = '#0b1220'; x.fillRect(0, 0, w, h);
    x.strokeStyle = 'rgba(159,179,200,0.13)'; x.lineWidth = 1;
    for (var db = Math.ceil(min / 10) * 10; db < max; db += 10) {
      var gy = h - (db - min) / (max - min) * h;
      x.beginPath(); x.moveTo(0, gy); x.lineTo(w, gy); x.stroke();
    }
    (marks || []).forEach(function (m) {
      x.strokeStyle = m.c; x.setLineDash(m.dash || []);
      x.beginPath(); x.moveTo(m.f * w, 0); x.lineTo(m.f * w, h); x.stroke();
      x.setLineDash([]);
    });
    x.beginPath();
    for (var i = 0; i < n; i++) {
      var px = i / (n - 1) * w, py = h - (arr[i] - min) / (max - min) * h;
      if (i === 0) { x.moveTo(px, py); } else { x.lineTo(px, py); }
    }
    x.strokeStyle = colourStr; x.lineWidth = 1.4 * DPR; x.stroke();
    x.lineTo(w, h); x.lineTo(0, h); x.closePath();
    x.fillStyle = 'rgba(167,139,250,0.10)'; x.fill();
  }
  function waterfall(c, x, arr, rg, marks, rowH) {
    size(c);
    var w = c.width, h = c.height, n = arr.length, min = rg[0], max = rg[1];
    rowH = Math.max(1, Math.round((rowH || 2) * DPR));
    if (!w || !h) { return; }
    x.drawImage(c, 0, 0, w, h - rowH, 0, rowH, w, h - rowH);
    var img = x.createImageData(w, rowH);
    for (var px = 0; px < w; px++) {
      var col = colour((arr[Math.min(n - 1, Math.floor(px / w * n))] - min) / (max - min));
      for (var ry = 0; ry < rowH; ry++) {
        var o = (ry * w + px) * 4;
        img.data[o] = col[0]; img.data[o + 1] = col[1]; img.data[o + 2] = col[2]; img.data[o + 3] = 255;
      }
    }
    (marks || []).forEach(function (m) {   // a dot on the new row: the track builds up as it scrolls
      var mx = Math.round(m.f * w);
      for (var dx = -DPR; dx <= DPR; dx++) {
        var q = mx + Math.round(dx);
        if (q < 0 || q >= w) { continue; }
        for (var ry2 = 0; ry2 < rowH; ry2++) {
          var o2 = (ry2 * w + q) * 4;
          img.data[o2] = m.rgb[0]; img.data[o2 + 1] = m.rgb[1]; img.data[o2 + 2] = m.rgb[2];
        }
      }
    });
    x.putImageData(img, 0, 0);
  }
  function dopplerAt(d, t) {               // the expected shift now, from the 5 s track
    var tr = d.doppler || [];
    if (!tr.length) { return null; }
    for (var i = 1; i < tr.length; i++) {
      if (tr[i][0] >= t) {
        var a = tr[i - 1], b = tr[i], f = (t - a[0]) / Math.max(1, b[0] - a[0]);
        return a[1] + (b[1] - a[1]) * Math.max(0, Math.min(1, f));
      }
    }
    return tr[tr.length - 1][1];
  }
  function mmss(s) { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ':' + ('0' + s % 60).slice(-2); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  function drawHistory() {
    var c = C['il-hist'], x = C['il-histX'];
    size(c);
    var w = c.width, h = c.height;
    x.fillStyle = '#0b1220'; x.fillRect(0, 0, w, h);
    if (history.length < 2) { return; }
    var max = Math.max(20, Math.max.apply(null, history.map(function (p) { return p.v; })));
    var t0 = history[0].t, dt = Math.max(1, history[history.length - 1].t - t0);
    x.beginPath();
    history.forEach(function (p, i) {
      var px = (p.t - t0) / dt * w, py = h - p.v / max * (h - 4) - 2;
      if (i === 0) { x.moveTo(px, py); } else { x.lineTo(px, py); }
    });
    x.strokeStyle = '#a78bfa'; x.lineWidth = 1.5 * DPR; x.stroke();
  }

  function showAprs(list) {
    var ul = $('il-list');
    list = (list || []).slice().sort(function (a, b) { return b.last - a.last; });
    var packets = list.reduce(function (n, s) { return n + (s.packets || 0); }, 0);
    $('il-count').textContent = list.length;
    $('il-aprs-n').textContent = list.length ? list.length + ' · ' + packets + ' ' + (T.packets || 'packets') : '';
    if (!list.length) { ul.innerHTML = '<li class="il-none">' + esc(T.none || 'No packets yet') + '</li>'; return; }
    ul.innerHTML = list.map(function (s) {
      var fresh = !known[s.call + s.last];
      known[s.call + s.last] = 1;
      var meta = [s.via_iss ? 'via ISS' : (T.direct || 'direct')];
      if (s.lat !== null && s.lat !== undefined) { meta.push(s.lat.toFixed(2) + ', ' + s.lon.toFixed(2)); }
      if (s.comment) { meta.push(s.comment); }
      return '<li' + (fresh && seen ? ' class="il-new"' : '') + '><span class="il-call">' + esc(s.call) +
        '</span><span class="il-meta">' + esc(meta.join(' · ')) + '</span></li>';
    }).join('');
  }

  // the live map: loaded once, told the pass's times (it draws the track and fits it to the frame)
  var mapFrame = $('il-map'), mapPass = null, picSrc = '';
  function sendPass() {
    if (mapPass && mapFrame.contentWindow) { mapFrame.contentWindow.postMessage(mapPass, window.location.origin); }
  }
  mapFrame.addEventListener('load', sendPass);
  function showMap(d) {
    if (!d.start || !d.end) { return; }
    if (d.max_elev) { $('il-map-info').textContent = (T.max || 'max') + ' ' + Math.round(d.max_elev) + '°'; }
    if (mapPass && mapPass.aos === d.start * 1000) { return; }
    mapPass = { type: 'rl1-pass', sat: 'ISS', aos: d.start * 1000, los: d.end * 1000 };
    if (!mapFrame.getAttribute('src')) { mapFrame.src = '/satellite/map?live=ISS'; } else { sendPass(); }
  }
  function showPicture(d) {               // live_sstv.sh: the newest picture in the audio so far
    if (!d.picture) { return; }
    $('il-pic-wait').hidden = true;
    $('il-pic-img').hidden = false;
    $('il-pic-info').textContent = d.picture_mode + ' · ' + d.picture_rows + ' ' + (T.lines || 'lines') +
      (d.picture_complete ? ' · ' + (T.complete || 'complete') : '');
    if (d.picture !== picSrc) { picSrc = d.picture; $('il-pic-img').src = d.picture; }
  }

  function show(d) {
    card.hidden = false;
    showMap(d);
    var now = Date.now() / 1000;
    $('il-mode').textContent = (d.mode || '') + (d.frequency ? ' · ' + (+d.frequency).toFixed(3) + ' MHz' : '');
    $('il-left').textContent = d.end && d.end > now ? mmss(d.end - now) + ' ' + (T.left || 'left') : '';
    $('il-freq').textContent = d.frequency ? (+d.frequency).toFixed(3) + ' MHz' : '–';
    var aprs = d.mode === 'APRS';
    $('il-aprs').hidden = !aprs;
    $('il-sstv').hidden = aprs;
    $('il-pic').hidden = aprs;
    if (!aprs) { showPicture(d); }
    $('il-count-t').textContent = aprs ? (T.stations || 'Stations heard') : 'SSTV';
    if (aprs) { showAprs(d.stations); } else { $('il-count').textContent = '–'; }
    if (!d.live) {
      card.classList.remove('is-live');
      $('il-state').textContent = d.end && now > d.end ? (T.done || 'Recording finished: decoding') : (T.wait || 'Waiting for the receiver…');
      return;
    }
    card.classList.add('is-live');
    if (d.t === lastT) { return; }        // the same second again: nothing new to draw
    lastT = d.t;
    var dop = dopplerAt(d, Date.now() / 1000);
    $('il-dop').textContent = dop === null ? '–' : (dop >= 0 ? '+' : '') + (dop / 1000).toFixed(1) + ' kHz';
    var lv = d.level || 0;
    $('il-level').textContent = lv.toFixed(1) + ' dB';
    $('il-level-bar').style.width = Math.max(0, Math.min(100, lv / 30 * 100)) + '%';
    $('il-level-bar').className = lv >= 12 ? 'good' : (lv >= 6 ? 'fair' : '');
    $('il-state').textContent = lv >= 10 ? (T.heard || 'Signal heard') : (T.listening || 'Listening');
    history.push({ t: d.t, v: lv });
    if (history.length > 1500) { history.shift(); }
    var best = Math.max.apply(null, history.map(function (p) { return p.v; }));
    $('il-peak').textContent = (T.peak || 'peak') + ' ' + best.toFixed(1) + ' dB';
    drawHistory();

    // whole band: the ISS frequency sits 264.6 kHz above the centre
    if (d.wide && d.wide.length) {
      var span = d.rate || 2381400, cen = d.center_hz || 0, tgt = (+d.frequency || 0) * 1e6;
      var fIss = 0.5 + (tgt + (dop || 0) - cen) / span;
      $('il-band').textContent = ((cen - span / 2) / 1e6).toFixed(2) + '–' + ((cen + span / 2) / 1e6).toFixed(2) + ' MHz';
      var w = d.wide.slice(), mid = w.length / 2;
      w[mid] = (w[mid - 1] + w[mid + 1]) / 2;       // the dongle's DC spike
      var rg = range('wide', w);
      line(C['il-wide'], C['il-wideX'], w, rg, '#a78bfa', [{ f: fIss, c: 'rgba(167,139,250,0.6)', dash: [3, 4] }]);
      waterfall(C['il-wide-wf'], C['il-wide-wfX'], w, rg, [], 1);
    }
    // ISS channel: ±22.05 kHz around the ISS frequency, the expected Doppler marked
    if (d.zoom && d.zoom.length) {
      var zs = d.zoom_span || 44100, fd = 0.5 + (dop || 0) / zs;
      var rz = range('zoom', d.zoom);
      line(C['il-zoom'], C['il-zoomX'], d.zoom, rz, '#a78bfa',
           [{ f: 0.5, c: 'rgba(159,179,200,0.35)' }, { f: fd, c: 'rgba(242,179,61,0.8)', dash: [3, 3] }]);
      waterfall(C['il-zoom-wf'], C['il-zoom-wfX'], d.zoom, rz, dop === null ? [] : [{ f: fd, rgb: [242, 179, 61] }], 1);
    }
    // SSTV: the FM audio, 0-3 kHz, with the sync (1200 Hz) and picture (1500-2300 Hz) tones marked
    if (!aprs && d.audio && d.audio.length) {
      var n = d.audio.length, hz = 3000 / (n - 1);
      var ra = range('audio', d.audio);
      waterfall(C['il-audio'], C['il-audioX'], d.audio, ra,
                [1200, 1500, 2300].map(function (f) { return { f: f / hz / n, rgb: f === 1200 ? [95, 211, 138] : [111, 131, 153] }; }), 2);
    }
  }

  function reset() {
    history = []; known = {}; scale = {}; lastT = 0;
    picSrc = ''; $('il-pic-img').hidden = true; $('il-pic-img').removeAttribute('src'); $('il-pic-wait').hidden = false;
    ['il-wide-wf', 'il-zoom-wf', 'il-audio'].forEach(function (id) {
      var c = C[id]; C[id + 'X'].clearRect(0, 0, c.width, c.height);
    });
  }
  function poll() {
    fetch('/passes/isslive', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      if (!d.active) { return; }
      if (d.start !== lastPass) { lastPass = d.start; reset(); }
      show(d); seen = true;
    }).catch(function () {}).then(function () {
      if (polling) { timer = setTimeout(poll, document.hidden ? 5000 : 1000); }
    });
  }
  function check() {
    var want = inPass();
    if (want && !polling) { polling = true; poll(); }
    if (!want && polling) {
      polling = false; clearTimeout(timer);
      if (seen) { setTimeout(function () { card.hidden = true; seen = false; }, 30000); }
    }
  }
  check();
  setInterval(check, 5000);
})();
