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
    modal.classList.add('is-open');
    document.documentElement.classList.add('u-dialog-open-scroll');
    loadPdf();
  }

  function closeModal() {
    modal.classList.remove('is-open');
    document.documentElement.classList.remove('u-dialog-open-scroll');
  }

  trigger.addEventListener('click', openModal, true);
  closeBtn.addEventListener('click', closeModal);
  backdrop.addEventListener('click', closeModal);
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && modal.classList.contains('is-open')) closeModal();
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
