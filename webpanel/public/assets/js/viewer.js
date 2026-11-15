/*
 * Image viewer for a capture's page: clicking a card opens the full image in an overlay
 * with zoom in / out / reset, previous / next, a link to the original file and close.
 *   mouse: wheel zooms at the pointer, drag pans, double-click toggles 1x / 2.5x
 *   touch: pinch zooms, one finger pans when zoomed, swipe left / right when not
 *   keys:  + / - / 0, arrows for previous / next, Esc closes
 * Any card link inside a .cap-grid with data-viewer opens it; the href is the full image.
 */
(function () {
  'use strict';
  // every card of every .cap-grid[data-viewer] on the page, in order (the Daily map page has one
  // grid per day)
  var tr = window.tr || function (k, d) { return d; };
  var links = Array.prototype.slice.call(document.querySelectorAll('.cap-grid[data-viewer] a.cap-card'));
  if (!links.length) { return; }

  var MIN = 1, MAX = 8;
  var box = document.createElement('div');
  box.className = 'iv';
  box.hidden = true;
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-modal', 'true');
  box.innerHTML =
    '<div class="iv-stage"><img class="iv-img" alt=""><div class="iv-spin"></div></div>' +
    '<div class="iv-top"><span class="iv-title"></span><span class="iv-count"></span>' +
      '<a class="iv-btn iv-raw" target="_blank" rel="noopener"><i class="fas fa-external-link-alt"></i></a>' +
      '<button type="button" class="iv-btn iv-close"><i class="fas fa-times"></i></button></div>' +
    '<div class="iv-zoom">' +
      '<button type="button" class="iv-btn" data-z="in">+</button>' +
      '<button type="button" class="iv-btn" data-z="out">&minus;</button>' +
      '<button type="button" class="iv-btn" data-z="reset"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" ' +
        'stroke-width="1.6"><circle cx="8" cy="8" r="5"/><circle cx="8" cy="8" r="1.2" fill="currentColor"/>' +
        '<path d="M8 1v2.5M8 12.5V15M1 8h2.5M12.5 8H15"/></svg></button>' +
      '<span class="iv-pct">100%</span></div>' +
    '<button type="button" class="iv-btn iv-nav iv-prev"><i class="fas fa-chevron-left"></i></button>' +
    '<button type="button" class="iv-btn iv-nav iv-next"><i class="fas fa-chevron-right"></i></button>';
  document.body.appendChild(box);

  var stage = box.querySelector('.iv-stage'), img = box.querySelector('.iv-img');
  img.draggable = false;
  var pctEl = box.querySelector('.iv-pct'), raw = box.querySelector('.iv-raw');
  function label(el, key, def) { el.title = tr(key, def); el.setAttribute('aria-label', el.title); }
  label(box.querySelector('[data-z="in"]'), 'zoom_in', 'Zoom in');
  label(box.querySelector('[data-z="out"]'), 'zoom_out', 'Zoom out');
  label(box.querySelector('[data-z="reset"]'), 'reset_view', 'Reset view');
  label(box.querySelector('.iv-close'), 'close', 'Close');
  label(raw, 'open_original', 'Open the original image');
  label(box.querySelector('.iv-prev'), 'previous', 'Previous');
  label(box.querySelector('.iv-next'), 'next_image', 'Next');

  var index = -1, s = 1, tx = 0, ty = 0, lastFocus = null;

  // ---- view transform: the image is fitted to the stage at scale 1 ----
  function bounds() {
    var w = stage.clientWidth, h = stage.clientHeight;
    var iw = img.naturalWidth || 1, ih = img.naturalHeight || 1;
    var fit = Math.min(w / iw, h / ih, 1);     // never enlarge small images past their size at 1x
    return { w: w, h: h, bw: iw * fit, bh: ih * fit };
  }
  function clamp() {
    var b = bounds();
    var mx = Math.max(0, (b.bw * s - b.w) / 2), my = Math.max(0, (b.bh * s - b.h) / 2);
    tx = Math.max(-mx, Math.min(mx, tx));
    ty = Math.max(-my, Math.min(my, ty));
  }
  function apply(animate) {
    clamp();
    var b = bounds();
    img.style.width = b.bw + 'px';
    img.style.height = b.bh + 'px';
    img.style.transition = animate ? 'transform 0.2s ease' : 'none';
    img.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + s + ')';
    pctEl.textContent = Math.round(s * 100) + '%';
    box.querySelector('[data-z="in"]').disabled = s >= MAX;
    box.querySelector('[data-z="out"]').disabled = s <= MIN;
    stage.classList.toggle('zoomed', s > MIN);
  }
  // zoom to scale ns keeping the stage point (px, py), relative to the stage centre, still
  function zoomTo(ns, px, py, animate) {
    ns = Math.max(MIN, Math.min(MAX, ns));
    px = px || 0; py = py || 0;
    tx = px - (px - tx) * ns / s;
    ty = py - (py - ty) * ns / s;
    s = ns;
    apply(animate);
  }
  function reset(animate) { s = 1; tx = 0; ty = 0; apply(animate); }
  function stagePoint(clientX, clientY) {
    var r = stage.getBoundingClientRect();
    return [clientX - r.left - r.width / 2, clientY - r.top - r.height / 2];
  }

  // ---- open / close / step ----
  function show(i) {
    index = (i + links.length) % links.length;
    var a = links[index];
    box.querySelector('.iv-title').textContent = (a.querySelector('.cap-label') || {}).textContent || '';
    box.querySelector('.iv-count').textContent = links.length > 1 ? (index + 1) + ' / ' + links.length : '';
    raw.href = a.href;
    box.classList.add('loading');
    img.onload = function () { box.classList.remove('loading'); reset(false); };
    img.onerror = function () { box.classList.remove('loading'); };
    img.src = a.href;
    img.alt = box.querySelector('.iv-title').textContent;
    box.querySelector('.iv-prev').hidden = box.querySelector('.iv-next').hidden = links.length < 2;
  }
  function open(i) {
    lastFocus = document.activeElement;
    box.hidden = false;
    document.documentElement.classList.add('fs-lock');
    show(i);
    box.querySelector('.iv-close').focus();
  }
  function close() {
    box.hidden = true;
    img.removeAttribute('src');
    document.documentElement.classList.remove('fs-lock');
    if (lastFocus) { lastFocus.focus(); }
  }

  links.forEach(function (a, i) {
    a.addEventListener('click', function (ev) {
      if (ev.ctrlKey || ev.metaKey || ev.shiftKey || ev.button === 1) { return; }   // new tab as usual
      ev.preventDefault();
      open(i);
    });
  });
  box.querySelector('.iv-close').addEventListener('click', close);
  box.querySelector('.iv-prev').addEventListener('click', function () { show(index - 1); });
  box.querySelector('.iv-next').addEventListener('click', function () { show(index + 1); });
  box.querySelector('.iv-zoom').addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-z]');
    if (!b) { return; }
    var z = b.getAttribute('data-z');
    if (z === 'in') { zoomTo(s * 1.6, 0, 0, true); }
    else if (z === 'out') { zoomTo(s / 1.6, 0, 0, true); }
    else { reset(true); }
  });
  document.addEventListener('keydown', function (ev) {
    if (box.hidden) { return; }
    if (ev.key === 'Escape') { close(); }
    else if (ev.key === 'ArrowLeft') { show(index - 1); }
    else if (ev.key === 'ArrowRight') { show(index + 1); }
    else if (ev.key === '+' || ev.key === '=') { zoomTo(s * 1.6, 0, 0, true); }
    else if (ev.key === '-') { zoomTo(s / 1.6, 0, 0, true); }
    else if (ev.key === '0') { reset(true); }
  });
  window.addEventListener('resize', function () { if (!box.hidden) { apply(false); } });

  // ---- mouse ----
  stage.addEventListener('wheel', function (ev) {
    ev.preventDefault();
    var p = stagePoint(ev.clientX, ev.clientY);
    zoomTo(s * Math.exp(-ev.deltaY * (ev.deltaMode === 1 ? 0.05 : 0.0015)), p[0], p[1], false);
  }, { passive: false });
  stage.addEventListener('dblclick', function (ev) {
    var p = stagePoint(ev.clientX, ev.clientY);
    if (s > 1.01) { reset(true); } else { zoomTo(2.5, p[0], p[1], true); }
  });
  // a click on the dark area around the image closes the viewer
  stage.addEventListener('click', function (ev) {
    if (ev.target === stage && !moved) { close(); }
  });

  // ---- pointer drag (mouse and touch), pinch with two touches ----
  var pts = {}, start = null, moved = false;
  function count() { return Object.keys(pts).length; }
  function pair() { var k = Object.keys(pts); return [pts[k[0]], pts[k[1]]]; }
  stage.addEventListener('pointerdown', function (ev) {
    if (ev.button !== undefined && ev.button > 0) { return; }
    stage.setPointerCapture(ev.pointerId);
    pts[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
    moved = false;
    if (count() === 1) {
      start = { x: ev.clientX, y: ev.clientY, tx: tx, ty: ty, s: s, swipe: true };
    } else if (count() === 2) {
      var p = pair();
      var mid = stagePoint((p[0].x + p[1].x) / 2, (p[0].y + p[1].y) / 2);
      start = { d: Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y) || 1, s: s, tx: tx, ty: ty, mx: mid[0], my: mid[1] };
    }
  });
  stage.addEventListener('pointermove', function (ev) {
    if (!pts[ev.pointerId] || !start) { return; }
    pts[ev.pointerId] = { x: ev.clientX, y: ev.clientY };
    if (count() === 1 && start.x !== undefined) {
      var dx = ev.clientX - start.x, dy = ev.clientY - start.y;
      if (Math.abs(dx) + Math.abs(dy) > 4) { moved = true; }
      if (s > 1.01) { tx = start.tx + dx; ty = start.ty + dy; apply(false); }
    } else if (count() === 2 && start.d) {
      var p = pair(), d = Math.hypot(p[0].x - p[1].x, p[0].y - p[1].y);
      var mid = stagePoint((p[0].x + p[1].x) / 2, (p[0].y + p[1].y) / 2);
      s = start.s; tx = start.tx; ty = start.ty;
      zoomTo(start.s * d / start.d, start.mx, start.my, false);
      tx += mid[0] - start.mx; ty += mid[1] - start.my; apply(false);
      moved = true;
    }
  });
  function up(ev) {
    if (!pts[ev.pointerId]) { return; }
    // a swipe at 1x steps to the previous / next image
    if (count() === 1 && start && start.swipe && s <= 1.01) {
      var dx = ev.clientX - start.x;
      if (Math.abs(dx) > 60 && Math.abs(ev.clientY - start.y) < 80) { show(index + (dx < 0 ? 1 : -1)); }
    }
    delete pts[ev.pointerId];
    start = null;
    if (count() === 1) {               // one finger left after a pinch: keep panning from here
      var k = Object.keys(pts)[0];
      start = { x: pts[k].x, y: pts[k].y, tx: tx, ty: ty, s: s, swipe: false };
    }
  }
  stage.addEventListener('pointerup', up);
  stage.addEventListener('pointercancel', up);
})();
