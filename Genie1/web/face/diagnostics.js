/* Standalone support tool. No employee images, embeddings, or credentials logged. */
(() => {
  const element = id => document.getElementById(id);
  const reports = [];
  let worker, timer, active;
  function render() { element('log').textContent = JSON.stringify(reports, null, 2); }
  function finish(status, error) {
    if (!active) return;
    active.status = status;
    if (error) active.error = error;
    worker?.terminate(); worker = null;
    clearTimeout(timer);
    active = null;
    element('run').disabled = false;
    element('cancel').disabled = true;
    render();
  }
  element('run').onclick = () => {
    if (active) return;
    const options = {
      mode: element('mode').value, optimization: element('optimization').value,
      noArena: element('noArena').checked, noPattern: element('noPattern').checked,
    };
    active = {
      startedAt: new Date().toISOString(), browser: navigator.userAgent,
      ...options, status: 'running', stages: [],
    };
    reports.push(active);
    element('run').disabled = true;
    element('cancel').disabled = false;
    render();
    try {
      worker = new Worker(new URL('face_worker.js', location.href));
      worker.onmessage = ({data}) => {
        if (!active) return;
        if (data.diagnostic) { active.stages.push(data.diagnostic); render(); return; }
        if (data.id !== 1) return;
        finish(data.error ? 'failed' : 'passed', data.error);
      };
      worker.onerror = () => finish('failed', 'Worker failed. Check the last started stage and browser console.');
      timer = setTimeout(() => finish('timed out', 'No completion within 120 seconds.'), 120000);
      worker.postMessage({id: 1, operation: 'diagnose', ...options});
    } catch (error) { finish('failed', error.message); }
  };
  element('cancel').onclick = () => finish('stopped');
  window.addEventListener('pagehide', () => finish('stopped'));
  element('download').onclick = () => {
    const url = URL.createObjectURL(new Blob([JSON.stringify(reports, null, 2)], {type:'application/json'}));
    const link = document.createElement('a');
    link.href = url; link.download = 'face-runtime-report.json';
    document.body.append(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
})();
