/*
 * Full-screen panels (Passes map, Live log console).
 *
 * RL1FS.bind(el, onChange) returns a toggle function for el. It uses the browser's
 * Fullscreen API where it works, and otherwise (iPhone Safari, or a refused request)
 * pins the element over the whole window with the .fs-on class. onChange(on) runs after
 * every change, whichever way it happened (button, Esc key, browser UI).
 */
window.RL1FS = (function () {
  var bound = [];

  function nativeEl() {
    return document.fullscreenElement || document.webkitFullscreenElement || null;
  }
  function isOn(el) {
    return nativeEl() === el || el.classList.contains('fs-on');
  }
  function notify() {
    bound.forEach(function (b) {
      var on = isOn(b.el);
      if (on !== b.last) { b.last = on; b.onChange(on); }
    });
  }
  function pseudo(el, on) {
    el.classList.toggle('fs-on', on);
    document.documentElement.classList.toggle('fs-lock', on);
    notify();
  }
  function enter(el) {
    var req = el.requestFullscreen || el.webkitRequestFullscreen;
    if (!req) { pseudo(el, true); return; }
    try {
      var p = req.call(el);
      if (p && p.catch) { p.catch(function () { pseudo(el, true); }); }
    } catch (e) {
      pseudo(el, true);
    }
  }
  function exit(el) {
    if (nativeEl() === el) {
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    } else {
      pseudo(el, false);
    }
  }

  document.addEventListener('fullscreenchange', notify);
  document.addEventListener('webkitfullscreenchange', notify);
  document.addEventListener('keydown', function (ev) {
    if (ev.key !== 'Escape') { return; }
    bound.forEach(function (b) { if (b.el.classList.contains('fs-on')) { pseudo(b.el, false); } });
  });

  return {
    bind: function (el, onChange) {
      bound.push({ el: el, onChange: onChange || function () {}, last: false });
      return function toggle() { if (isOn(el)) { exit(el); } else { enter(el); } };
    }
  };
})();
