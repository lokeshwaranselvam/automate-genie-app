// Installed before bundled ERP page scripts. No SID, password or API token crosses this bridge.
(() => {
  if (window.parent === window || !window.name.startsWith('genie-erp-')) return;
  const token = window.name;
  const origin = location.origin;
  for (const channel of ['GenieLead', 'GenieExpenseClaim', 'GenieLeaveApplication',
    'GenieOpportunities', 'GeniePendingWork', 'GenieSalesSummary']) {
    window[channel] = {
      postMessage(message) {
        parent.postMessage({token, channel, message: String(message)}, origin);
      },
    };
  }
  // Iframe touch events do not reach Flutter's outer gesture listener.
  const doc = window.document;
  if (!doc) return;
  let pull;
  function atTop(node) {
    if (doc.readyState !== 'complete' ||
        doc.querySelector('dialog[open], .modal.show, [aria-busy="true"], fieldset[disabled]')) return false;
    if (!node || typeof node.closest !== 'function' || node.closest('input, textarea, select, button, [contenteditable="true"], iframe, canvas, [role="slider"]')) return false;
    while (node) {
      if (node.scrollHeight > node.clientHeight + 1 &&
          /auto|scroll|overlay/.test(window.getComputedStyle(node).overflowY) && node.scrollTop > 1) return false;
      node = node.parentElement;
    }
    return (doc.scrollingElement?.scrollTop || window.scrollY || 0) <= 1;
  }
  doc.addEventListener('touchstart', event => {
    pull = event.touches.length === 1 && atTop(event.target)
      ? {x:event.touches[0].clientX, y:event.touches[0].clientY, dx:0, dy:0, target:event.target}
      : null;
  }, {passive:true});
  doc.addEventListener('touchmove', event => {
    if (!pull) return;
    if (event.touches.length !== 1) { pull = null; return; }
    pull.dx = event.touches[0].clientX - pull.x;
    pull.dy = event.touches[0].clientY - pull.y;
    if (pull.dy > 0 && Math.abs(pull.dx) < pull.dy * .6) event.preventDefault();
  }, {passive:false});
  doc.addEventListener('touchend', () => {
    const gesture = pull; pull = null;
    if (gesture && gesture.dy >= 90 && Math.abs(gesture.dx) < gesture.dy * .6 && atTop(gesture.target)) {
      parent.postMessage({token, channel:'__refresh', message:''}, origin);
    }
  }, {passive:true});
  doc.addEventListener('touchcancel', () => { pull = null; }, {passive:true});
})();
