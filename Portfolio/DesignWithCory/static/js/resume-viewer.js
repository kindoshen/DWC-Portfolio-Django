// resume-viewer.js — renders the resume PDF into the modal via PDF.js canvases
// instead of an <iframe>/<embed>, so there's no native browser PDF toolbar
// offering a one-click download, and no direct link to the file anywhere in
// the page. A watermark is drawn over every rendered page and the context
// menu is disabled inside the viewer.
//
// Honest limitation: this deters casual scraping/right-click-saving. It is
// not DRM — a sufficiently determined visitor can still screenshot the
// canvas. There is no client-side technique that prevents that.
import * as pdfjsLib from '/static/js/pdfjs/pdf.min.mjs';

pdfjsLib.GlobalWorkerOptions.workerSrc = '/static/js/pdfjs/pdf.worker.min.mjs';

document.addEventListener('DOMContentLoaded', function () {
  var modal = document.getElementById('resume-modal');
  var trigger = document.getElementById('resume-trigger');
  if (!modal || !trigger) return;

  var pagesEl = modal.querySelector('.resume-modal__pages');
  var zoomLevelEl = modal.querySelector('.resume-modal__zoom-level');
  var zoomInBtn = modal.querySelector('.resume-modal__zoom-in');
  var zoomOutBtn = modal.querySelector('.resume-modal__zoom-out');
  var closeBtn = modal.querySelector('.resume-modal__close');
  var backdrop = modal.querySelector('.resume-modal__backdrop');
  var viewerEl = modal.querySelector('.resume-modal__viewer');

  var pdfDoc = null;
  var BASE_SCALE = 1.2;
  var scale = BASE_SCALE;
  var loaded = false;
  var lastFocused = null;
  // Every focusable control inside the dialog, in tab order — used for the focus trap below.
  var focusable = [closeBtn, zoomOutBtn, zoomInBtn];

  // Tiles the watermark text diagonally across the whole page, not just one corner —
  // a single mark is trivial to crop out of a screenshot. The translate+rotate moves the
  // canvas's origin to its own center and tilts the whole coordinate system -30°, so the
  // nested loop below can just lay out a plain upright grid (row spacing 90px, column
  // spacing 260px) and get a diagonal tiling for free. Looping from -canvas.height/-width
  // (not 0) overshoots past every edge in both directions so the rotated grid still fully
  // covers the visible canvas corner-to-corner instead of leaving gaps where the tilted
  // rows no longer line up with the untilted canvas bounds.
  function watermark(ctx, canvas) {
    ctx.save();
    ctx.globalAlpha = 0.08;
    ctx.fillStyle = '#111111';
    ctx.font = '16px sans-serif';
    ctx.translate(canvas.width / 2, canvas.height / 2);
    ctx.rotate((-30 * Math.PI) / 180);
    for (var y = -canvas.height; y < canvas.height; y += 90) {
      for (var x = -canvas.width; x < canvas.width; x += 260) {
        ctx.fillText('designwithcory.com', x, y);
      }
    }
    ctx.restore();
  }

  function renderPage(pageNum) {
    return pdfDoc.getPage(pageNum).then(function (page) {
      var viewport = page.getViewport({ scale: scale });
      var canvas = pagesEl.children[pageNum - 1];
      if (!canvas) {
        canvas = document.createElement('canvas');
        pagesEl.appendChild(canvas);
      }
      var ctx = canvas.getContext('2d');
      canvas.width = viewport.width;
      canvas.height = viewport.height;
      return page.render({ canvasContext: ctx, viewport: viewport }).promise.then(function () {
        watermark(ctx, canvas);
      });
    });
  }

  function renderAll() {
    var renders = [];
    for (var i = 1; i <= pdfDoc.numPages; i++) {
      renders.push(renderPage(i));
    }
    zoomLevelEl.textContent = Math.round((scale / BASE_SCALE) * 100) + '%';
    return Promise.all(renders);
  }

  function loadPdf() {
    if (loaded) return renderAll();
    pagesEl.innerHTML = '<p class="resume-modal__status">Loading resume…</p>';
    return pdfjsLib
      .getDocument('/resume/')
      .promise.then(function (doc) {
        pdfDoc = doc;
        loaded = true;
        pagesEl.innerHTML = '';
        return renderAll();
      })
      .catch(function () {
        pagesEl.innerHTML = '<p class="resume-modal__status">Couldn’t load the resume right now — try again shortly.</p>';
      });
  }

  function openModal(event) {
    if (event) event.preventDefault();
    lastFocused = document.activeElement;
    modal.classList.add('is-open');
    modal.setAttribute('aria-hidden', 'false');
    document.documentElement.classList.add('u-dialog-open-scroll');
    closeBtn.focus();
    loadPdf();
  }

  function closeModal() {
    modal.classList.remove('is-open');
    modal.setAttribute('aria-hidden', 'true');
    document.documentElement.classList.remove('u-dialog-open-scroll');
    // Return focus to whatever opened the dialog (normally #resume-trigger) rather than
    // leaving it on the now-hidden close button, or dropped back to <body>.
    if (lastFocused && typeof lastFocused.focus === 'function') lastFocused.focus();
  }

  trigger.addEventListener('click', openModal, true);
  closeBtn.addEventListener('click', closeModal);
  backdrop.addEventListener('click', closeModal);
  document.addEventListener('keydown', function (e) {
    if (!modal.classList.contains('is-open')) return;
    if (e.key === 'Escape') {
      closeModal();
      return;
    }
    if (e.key !== 'Tab') return;
    // Focus trap: Tab/Shift+Tab cycles only through the dialog's own controls so focus
    // never escapes to the page behind the backdrop while the modal is open.
    var first = focusable[0];
    var last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  });
  viewerEl.addEventListener('contextmenu', function (e) {
    e.preventDefault();
  });

  zoomInBtn.addEventListener('click', function () {
    scale = Math.min(scale + 0.2, 2.4);
    if (loaded) renderAll();
  });
  zoomOutBtn.addEventListener('click', function () {
    scale = Math.max(scale - 0.2, 0.6);
    if (loaded) renderAll();
  });
});
