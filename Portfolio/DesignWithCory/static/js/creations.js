// static/js/creations.js — Creations page gallery modal.
//
// Two closing paths, on purpose:
//   - the shaded backdrop (and Escape) is the *real* close control: a brief "Here, let me
//     get that for you" line, then the modal actually closes.
//   - the visible "X" does not close anything. It opens a second, smaller modal — a joke,
//     styled like a speech bubble anchored to the X — instead. See
//     templates/includes/creations_exit_saga.html for the copy.
(function () {
  var modal = document.getElementById('creations-modal');
  if (!modal) return;

  var backdrop = modal.querySelector('[data-role="backdrop"]');
  var stage = modal.querySelector('.creations-modal__stage');
  var image = document.getElementById('creations-modal-image');
  var caption = document.getElementById('creations-modal-caption');
  var closeBtn = document.getElementById('creations-modal-close');
  var bubble = document.getElementById('creations-exit-bubble');
  var bubbleDismiss = document.getElementById('creations-exit-dismiss');
  var grid = document.querySelector('.creations-grid');

  var lastTrigger = null;
  var closeTimer = null;
  var CLOSE_DELAY_MS = 650; // matches the toast/fade transition length in creations.css

  function openModal(trigger) {
    lastTrigger = trigger;
    image.src = trigger.dataset.image;
    image.alt = trigger.dataset.title || '';
    caption.textContent = trigger.dataset.caption || '';

    clearTimeout(closeTimer);
    modal.classList.remove('is-closing');
    modal.classList.add('is-open');
    modal.setAttribute('aria-hidden', 'false');
    document.body.style.overflow = 'hidden';

    closeBtn.focus();
  }

  // The "real" close: shows the polite line, then actually closes after the fade finishes.
  function politeClose() {
    if (!modal.classList.contains('is-open') || modal.classList.contains('is-closing')) return;
    modal.classList.add('is-closing');
    closeTimer = setTimeout(finishClose, CLOSE_DELAY_MS);
  }

  function finishClose() {
    modal.classList.remove('is-open', 'is-closing');
    modal.setAttribute('aria-hidden', 'true');
    document.body.style.overflow = '';
    hideBubble();
    image.src = '';
    if (lastTrigger) {
      lastTrigger.focus();
      lastTrigger = null;
    }
  }

  function showBubble() {
    bubble.hidden = false;
    bubbleDismiss.focus();
  }

  function hideBubble() {
    if (bubble.hidden) return;
    bubble.hidden = true;
    if (modal.classList.contains('is-open') && !modal.classList.contains('is-closing')) {
      closeBtn.focus();
    }
  }

  if (grid) {
    grid.addEventListener('click', function (event) {
      var trigger = event.target.closest('.creations-grid__item');
      if (trigger) openModal(trigger);
    });
  }

  backdrop.addEventListener('click', politeClose);

  // The X: opens the joke bubble. Never closes the modal directly — that's the whole bit.
  closeBtn.addEventListener('click', function (event) {
    event.stopPropagation();
    showBubble();
  });

  bubbleDismiss.addEventListener('click', function (event) {
    event.stopPropagation();
    hideBubble();
  });

  // Clicking the frame (image/caption/close area) shouldn't bubble to the backdrop and
  // trigger a close — only genuine backdrop clicks should.
  stage.addEventListener('click', function (event) {
    if (event.target === stage) politeClose();
  });

  document.addEventListener('keydown', function (event) {
    if (!modal.classList.contains('is-open')) return;
    if (event.key === 'Escape') {
      if (!bubble.hidden) {
        hideBubble();
      } else {
        politeClose();
      }
      return;
    }
    // Minimal focus trap: keep Tab cycling within whichever layer is currently in front.
    if (event.key === 'Tab') {
      var container = !bubble.hidden ? bubble : modal;
      var focusable = container.querySelectorAll(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
      );
      if (!focusable.length) return;
      var first = focusable[0];
      var last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  });
})();
