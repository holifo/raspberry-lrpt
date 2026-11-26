// Passes page: the live decode panel. While a scheduled pass is on (its row's data-start /
// data-end, with a minute either side) it polls /passes/live once a second and draws SatDump's
// spectrum (with a scrolling waterfall), SNR, Viterbi and frame-sync locks, BER, Reed-Solomon
// corrections and frequency offset. The constellation is an estimate drawn from the SNR:
// SatDump 1.2.3 does not share its real one. Below them, the satellite on a live map
// (/satellite/map?live=<satellite>, told the pass's times with postMessage 'rl1-pass') beside the
// picture live_preview.sh decodes from the frames so far. Outside a pass it makes no requests.
(function () {
  'use strict';
  var card = document.getElementById('live-card');
  if (!card) { return; }
  var T = window.RL1_LIVE_TEXT || {};
  var $ = function (id) { return document.getElementById(id); };
  var fftC = $('live-fft'), wfC = $('live-wf'), iqC = $('live-iq'), histC = $('live-hist');
  var fftX = fftC.getContext('2d'), wfX = wfC.getContext('2d'), iqX = iqC.getContext('2d'), histX = histC.getContext('2d');
  var rows = Array.prototype.slice.call(document.querySelectorAll('.pass-row[data-start]'));
  var timer = null, polling = false, last = null, history = [], seen = false, lastPass = null;

  function inPass() {
    var now = Date.now() / 1000;
    return rows.some(function (r) { return now >= r.dataset.start - 60 && now <= +r.dataset.end + 60; });
  }

  // ---- drawing ------------------------------------------------------------------------------
  function sizeCanvas(c) {               // sharp on high-density screens, follows the layout width
    var w = c.clientWidth, h = c.clientHeight, r = window.devicePixelRatio || 1;
    if (!w || !h) { return; }
    if (c.width !== Math.round(w * r) || c.height !== Math.round(h * r)) {
      var keep = null;
      if (c === wfC && c.width && c.height) { keep = wfX.getImageData(0, 0, c.width, c.height); }
      c.width = Math.round(w * r); c.height = Math.round(h * r);
      if (keep) { wfX.putImageData(keep, 0, 0); }
    }
  }
  function colour(v) {                   // waterfall palette, v in 0..1: navy, teal, amber, white
    var stops = [[11, 18, 32], [20, 60, 110], [47, 160, 160], [242, 179, 61], [255, 250, 230]];
    v = Math.max(0, Math.min(1, v)) * (stops.length - 1);
    var i = Math.min(stops.length - 2, Math.floor(v)), f = v - i, a = stops[i], b = stops[i + 1];
    return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
  }
  var floor = null, top = null;
  function drawSpectrum(fft, locked) {
    sizeCanvas(fftC); sizeCanvas(wfC);
    var w = fftC.width, h = fftC.height, n = fft.length;
    var sorted = fft.slice().sort(function (a, b) { return a - b; });
    var lo = sorted[Math.floor(n * 0.1)], hi = sorted[n - 1];
    floor = floor === null ? lo : floor * 0.9 + lo * 0.1;           // smooth the scale
    top = top === null ? Math.max(hi, floor + 15) : Math.max(top * 0.95 + hi * 0.05, floor + 15);
    var min = floor - 8, max = top + 3;
    fftX.clearRect(0, 0, w, h);
    fftX.fillStyle = '#0b1220'; fftX.fillRect(0, 0, w, h);
    // grid: 10 dB steps and the LRPT bandwidth (±60 kHz) around the centre
    fftX.strokeStyle = 'rgba(159,179,200,0.15)'; fftX.lineWidth = 1;
    for (var db = Math.ceil(min / 10) * 10; db < max; db += 10) {
      var gy = h - (db - min) / (max - min) * h;
      fftX.beginPath(); fftX.moveTo(0, gy); fftX.lineTo(w, gy); fftX.stroke();
    }
    var span = last && last.span ? last.span : 320000, bw = 120000 / span * w;
    fftX.fillStyle = locked ? 'rgba(95,211,138,0.10)' : 'rgba(242,179,61,0.08)';
    fftX.fillRect(w / 2 - bw / 2, 0, bw, h);
    fftX.strokeStyle = 'rgba(159,179,200,0.35)';
    fftX.beginPath(); fftX.moveTo(w / 2, 0); fftX.lineTo(w / 2, h); fftX.stroke();
    // the spectrum line, filled under
    fftX.beginPath();
    for (var i = 0; i < n; i++) {
      var x = i / (n - 1) * w, y = h - (fft[i] - min) / (max - min) * h;
      if (i === 0) { fftX.moveTo(x, y); } else { fftX.lineTo(x, y); }
    }
    fftX.strokeStyle = locked ? '#5fd38a' : '#4fd1c5'; fftX.lineWidth = 1.5 * (window.devicePixelRatio || 1); fftX.stroke();
    fftX.lineTo(w, h); fftX.lineTo(0, h); fftX.closePath();
    fftX.fillStyle = locked ? 'rgba(95,211,138,0.12)' : 'rgba(79,209,197,0.12)'; fftX.fill();
    // waterfall: shift down a row, newest on top
    var ww = wfC.width, wh = wfC.height, rowH = Math.max(1, Math.round(2 * (window.devicePixelRatio || 1)));
    if (ww && wh) {
      wfX.drawImage(wfC, 0, 0, ww, wh - rowH, 0, rowH, ww, wh - rowH);
      var img = wfX.createImageData(ww, rowH);
      for (var px = 0; px < ww; px++) {
        var v = (fft[Math.min(n - 1, Math.floor(px / ww * n))] - min) / (max - min);
        var c = colour(v);
        for (var ry = 0; ry < rowH; ry++) {
          var o = (ry * ww + px) * 4;
          img.data[o] = c[0]; img.data[o + 1] = c[1]; img.data[o + 2] = c[2]; img.data[o + 3] = 255;
        }
      }
      wfX.putImageData(img, 0, 0);
    }
  }

  // estimated constellation: QPSK points at (±1, ±1)/√2 with Gaussian noise for the measured SNR
  // (σ per axis = 1/√(2·SNR)); older points fade, so a better signal tightens the four clusters
  function gauss() { var u = 1 - Math.random(), v = Math.random(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); }
  function drawConstellation(snr, locked) {
    sizeCanvas(iqC);
    var w = iqC.width, h = iqC.height, s = Math.min(w, h) / 2;
    iqX.fillStyle = 'rgba(11,18,32,0.35)'; iqX.fillRect(0, 0, w, h);
    iqX.strokeStyle = 'rgba(159,179,200,0.25)'; iqX.lineWidth = 1;
    iqX.beginPath(); iqX.moveTo(w / 2, 0); iqX.lineTo(w / 2, h); iqX.moveTo(0, h / 2); iqX.lineTo(w, h / 2); iqX.stroke();
    if (snr === null || snr === undefined) { return; }
    var sigma = 1 / Math.sqrt(2 * Math.pow(10, Math.max(-5, snr) / 10)), a = Math.SQRT1_2;
    iqX.fillStyle = locked ? 'rgba(95,211,138,0.75)' : 'rgba(242,179,61,0.7)';
    var r = Math.max(1, (window.devicePixelRatio || 1) * 1.2);
    for (var k = 0; k < 260; k++) {
      var x = (Math.random() < 0.5 ? -a : a) + gauss() * sigma, y = (Math.random() < 0.5 ? -a : a) + gauss() * sigma;
      iqX.fillRect(w / 2 + x * s * 0.62 - r / 2, h / 2 - y * s * 0.62 - r / 2, r, r);
    }
  }

  function drawHistory() {
    sizeCanvas(histC);
    var w = histC.width, h = histC.height;
    histX.clearRect(0, 0, w, h);
    histX.fillStyle = '#0b1220'; histX.fillRect(0, 0, w, h);
    if (history.length < 2) { return; }
    var max = Math.max(15, Math.max.apply(null, history.map(function (p) { return p.snr; })));
    // green where the decoder had frame sync
    var t0 = history[0].t, t1 = history[history.length - 1].t, dt = Math.max(1, t1 - t0);
    histX.fillStyle = 'rgba(95,211,138,0.18)';
    history.forEach(function (p, i) {
      if (!p.sync || i === 0) { return; }
      var xa = (history[i - 1].t - t0) / dt * w, xb = (p.t - t0) / dt * w;
      histX.fillRect(xa, 0, Math.max(1, xb - xa), h);
    });
    histX.beginPath();
    history.forEach(function (p, i) {
      var x = (p.t - t0) / dt * w, y = h - Math.max(0, p.snr) / max * (h - 4) - 2;
      if (i === 0) { histX.moveTo(x, y); } else { histX.lineTo(x, y); }
    });
    histX.strokeStyle = '#f2b33d'; histX.lineWidth = 1.5 * (window.devicePixelRatio || 1); histX.stroke();
  }

  // ---- figures --------------------------------------------------------------------------------
  function mmss(s) { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ':' + ('0' + s % 60).slice(-2); }
  function lamp(id, on) {
    $(id).classList.toggle('on', !!on);
    $(id + '-t').textContent = on ? (T.locked || 'locked') : (T.searching || 'searching');
  }
  var picSrc = '';
  function showPicture(d) {               // live_preview.sh: the frames decoded so far
    // the box shows while a picture is on its way (preview_on) or once there is one
    $('live-pic').hidden = !(d.preview || d.preview_on);
    if (!d.preview) { return; }
    $('live-pic-wait').hidden = true;
    $('live-pic-img').hidden = false;
    $('live-pic-info').textContent = (T.channel || 'channel') + ' ' + d.preview_channel +
      (d.preview_lines ? ' · ' + d.preview_lines + ' ' + (T.lines || 'lines') : '');
    if (d.preview !== picSrc) { picSrc = d.preview; $('live-pic-img').src = d.preview; }
  }
  // the live map: loaded once per satellite, told the pass being recorded (it draws its track and
  // fits it to the frame); the message is sent again when the frame (re)loads
  var mapFrame = $('live-map'), mapSat = '', mapPass = null;
  function sendPass() {
    if (mapPass && mapFrame.contentWindow) {
      mapFrame.contentWindow.postMessage(mapPass, window.location.origin);
    }
  }
  mapFrame.addEventListener('load', sendPass);
  function showMap(d) {
    if (!d.sat || !d.start || !d.end) { return; }
    if (d.max_elev) { $('live-map-info').textContent = (T.max || 'max') + ' ' + Math.round(d.max_elev) + '°'; }
    var key = d.sat + '|' + d.start;
    if (mapPass && mapPass.key === key) { return; }
    mapPass = { type: 'rl1-pass', key: key, sat: d.sat, aos: d.start * 1000, los: d.end * 1000 };
    if (mapSat !== d.sat) {
      mapSat = d.sat;
      mapFrame.src = '/satellite/map?live=' + encodeURIComponent(d.sat);   // sends the pass on load
    } else {
      sendPass();
    }
  }
  function show(d) {
    last = d;
    card.hidden = false;
    showMap(d);
    showPicture(d);
    var chip = $('live-sat');
    chip.textContent = (d.sat || '').replace('METEOR-', '');
    chip.className = 'sat-chip sat-' + (/4$/.test(d.sat || '') ? 'm24' : 'm23');
    var now = Date.now() / 1000;
    $('live-left').textContent = d.end && d.end > now ? mmss(d.end - now) + ' ' + (T.left || 'left') : '';
    if (!d.live) {
      $('live-state').textContent = d.end && now > d.end ? (T.done || 'Recording finished: decoding the images') : (T.wait || 'Waiting for SatDump…');
      card.classList.remove('is-live');
      return;
    }
    card.classList.add('is-live');
    var sync = d.deframer_lock;
    $('live-state').textContent = sync ? (T.decoding || 'Decoding') : (T.no_signal || 'No lock yet');
    $('live-snr').textContent = d.snr !== null ? d.snr.toFixed(1) + ' dB' : '–';
    $('live-peak').textContent = d.peak_snr !== null ? (T.peak || 'peak') + ' ' + d.peak_snr.toFixed(1) + ' dB' : '';
    $('live-snr-bar').style.width = Math.max(0, Math.min(100, (d.snr || 0) / 15 * 100)) + '%';
    $('live-snr-bar').className = (d.snr || 0) >= 6 ? 'good' : ((d.snr || 0) >= 3 ? 'fair' : '');
    lamp('live-vit', d.viterbi_lock);
    lamp('live-sync', sync);
    $('live-ber').textContent = d.ber !== null ? d.ber.toFixed(3) : '–';
    $('live-ber').className = d.ber !== null && d.ber < 0.17 ? 'good' : '';
    $('live-rs').textContent = d.rs_avg !== null ? d.rs_avg.toFixed(1) : '–';
    $('live-freq').textContent = d.freq !== null ? (d.freq >= 0 ? '+' : '') + Math.round(d.freq) + ' Hz' : '–';
    if (d.span) { $('live-span').textContent = '±' + Math.round(d.span / 2000) + ' kHz'; }
    if (d.fft) { drawSpectrum(d.fft, sync); }
    drawConstellation(d.snr, sync);
    if (d.snr !== null) { history.push({ t: d.time, snr: d.snr, sync: sync }); if (history.length > 1200) { history.shift(); } }
    drawHistory();
  }

  // ---- polling --------------------------------------------------------------------------------
  function poll() {
    fetch('/passes/live', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      if (d.start && d.start !== lastPass) {
        lastPass = d.start; history = []; floor = top = null;
        picSrc = ''; $('live-pic').hidden = true; $('live-pic-img').removeAttribute('src');
        $('live-pic-img').hidden = true; $('live-pic-wait').hidden = false;
      }
      if (d.live || d.end) { seen = true; show(d); }
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
