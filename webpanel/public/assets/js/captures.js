// Captures and Daily map pages: days fold open and shut (the newest is open), and on Captures
// filter chips show only one satellite, or only day or night passes. Open days and the filter are kept for this browser tab
// (sessionStorage), so they survive paging and going back from a capture. Without JavaScript
// every day stays open and the tools stay hidden.
(function () {
  'use strict';
  var root = document.getElementById('cap-days');
  if (!root) { return; }
  var days = Array.prototype.slice.call(root.querySelectorAll('.cap-day'));
  var tools = document.getElementById('cap-tools');
  var foldAll = document.getElementById('cap-fold-all');
  var KEY_DAYS = root.dataset.store || 'rl1-cap-days', KEY_FILTER = 'rl1-cap-filter';

  function load(key, fallback) {
    try { var v = JSON.parse(sessionStorage.getItem(key)); return v === null ? fallback : v; } catch (e) { return fallback; }
  }
  function save(key, v) { try { sessionStorage.setItem(key, JSON.stringify(v)); } catch (e) {} }

  var state = load(KEY_DAYS, {});
  var filter = load(KEY_FILTER, 'all');

  function setOpen(day, open, remember) {
    day.classList.toggle('is-closed', !open);
    day.querySelector('.cap-day-head').setAttribute('aria-expanded', open ? 'true' : 'false');
    // a folded day's videos stop
    if (!open) { Array.prototype.forEach.call(day.querySelectorAll('video'), function (v) { v.pause(); }); }
    if (remember) { state[day.dataset.day] = open; save(KEY_DAYS, state); }
  }
  function updateFoldAll() {
    var anyClosed = days.some(function (d) { return d.classList.contains('is-closed'); });
    foldAll.textContent = anyClosed ? foldAll.dataset.open : foldAll.dataset.close;
  }

  days.forEach(function (day, i) {
    var saved = state[day.dataset.day];
    setOpen(day, saved === undefined ? i === 0 : saved, false);
    day.querySelector('.cap-day-head').addEventListener('click', function () {
      setOpen(day, day.classList.contains('is-closed'), true);
      updateFoldAll();
    });
  });

  foldAll.addEventListener('click', function () {
    var open = days.some(function (d) { return d.classList.contains('is-closed'); });
    days.forEach(function (d) { setOpen(d, open, true); });
    updateFoldAll();
  });

  // filters: a card shows when it matches; a day with nothing left says so
  var filters = tools.querySelectorAll('.cap-f');
  function applyFilter() {
    if (!filters.length) { return; }
    Array.prototype.forEach.call(tools.querySelectorAll('.cap-f'), function (b) {
      b.classList.toggle('is-on', b.dataset.f === filter);
      b.setAttribute('aria-pressed', b.dataset.f === filter ? 'true' : 'false');
    });
    days.forEach(function (day) {
      var shown = 0;
      Array.prototype.forEach.call(day.querySelectorAll('.cap-card'), function (card) {
        var ok = filter === 'all' || card.dataset.sat === filter || card.dataset.dn === filter;
        card.hidden = !ok;
        if (ok) { shown++; }
      });
      var none = day.querySelector('.cap-none');
      if (none) { none.hidden = shown > 0; }
      day.classList.toggle('is-filtered-out', shown === 0);
    });
  }
  Array.prototype.forEach.call(tools.querySelectorAll('.cap-f'), function (b) {
    b.addEventListener('click', function () {
      filter = b.dataset.f;
      save(KEY_FILTER, filter);
      applyFilter();
    });
  });

  tools.hidden = false;
  root.classList.add('js-fold');
  applyFilter();
  updateFoldAll();
})();
