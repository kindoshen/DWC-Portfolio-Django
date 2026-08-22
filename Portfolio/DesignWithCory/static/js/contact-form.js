// Wires the contact form (includes/contact_me.html) to the Django crm app
// instead of the Nicepage-hosted form service the markup originally posted to.
//
// nicepage.js binds its own click handler to .u-btn-submit for the original
// Nicepage form flow, and it fires alongside a naive listener here (it ran
// first and stopPropagation() couldn't unwind it) — every submit doubled up.
// Intercepting in the capture phase runs this before nicepage.js's
// bubble-phase handler even sees the event, so stopImmediatePropagation()
// here reliably keeps it from also submitting.
document.addEventListener('DOMContentLoaded', function () {
  var form = document.getElementById('contact-form');
  if (!form) return;

  var submitLink = form.querySelector('.u-btn-submit');
  var successEl = form.querySelector('.u-form-send-success');
  var errorEl = form.querySelector('.u-form-send-error');
  var defaultErrorText = errorEl.textContent;
  var defaultSubmitText = submitLink ? submitLink.textContent : '';
  var submitting = false;

  function submitForm() {
    if (submitting) return;
    submitting = true;
    successEl.style.display = 'none';
    errorEl.style.display = 'none';
    // .u-btn-submit is an <a>, not a <button>/<input>, so it has no native `disabled` —
    // aria-disabled + a CSS class (pages.css) covers both the visual and a11y side.
    if (submitLink) {
      submitLink.setAttribute('aria-disabled', 'true');
      submitLink.classList.add('is-submitting');
      submitLink.textContent = 'Sending…';
    }

    fetch(form.action, {
      method: 'POST',
      body: new FormData(form),
      headers: { 'X-Requested-With': 'XMLHttpRequest' },
    })
      .then(function (response) {
        return response.json().then(function (data) {
          return { ok: response.ok, data: data };
        });
      })
      .then(function (result) {
        if (result.ok) {
          successEl.style.display = 'block';
          form.reset();
        } else {
          errorEl.textContent = result.data.error || defaultErrorText;
          errorEl.style.display = 'block';
        }
      })
      .catch(function () {
        errorEl.textContent = defaultErrorText;
        errorEl.style.display = 'block';
      })
      .finally(function () {
        submitting = false;
        if (submitLink) {
          submitLink.removeAttribute('aria-disabled');
          submitLink.classList.remove('is-submitting');
          submitLink.textContent = defaultSubmitText;
        }
      });
  }

  if (submitLink) {
    submitLink.addEventListener(
      'click',
      function (event) {
        event.preventDefault();
        event.stopImmediatePropagation();
        if (submitting) return; // aria-disabled isn't a real disabled — guard the click too
        submitForm();
      },
      true
    );
  }

  form.addEventListener(
    'submit',
    function (event) {
      event.preventDefault();
      event.stopImmediatePropagation();
      submitForm();
    },
    true
  );
});
