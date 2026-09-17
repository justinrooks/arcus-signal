/* Presentation scenarios only. All meaningful content is present in the HTML. */
(() => {
  const scenario = document.querySelector('#scenario');
  const density = document.querySelector('#density');
  const connection = document.querySelector('.connection');
  const age = document.querySelector('.snapshot-age');
  const notice = document.querySelector('.freshness-notice');
  const originalConnection = connection.textContent;
  const originalAge = age.textContent;
  const params = new URLSearchParams(location.search);
  function update() {
    document.body.dataset.scenario = scenario.value;
    document.body.dataset.density = density.value;
    connection.textContent = originalConnection;
    age.textContent = originalAge;
    notice.textContent = '';
    if (scenario.value === 'stale') {
      connection.textContent = 'Stale · sample';
      age.textContent = 'Snapshot 8m ago';
      notice.textContent = 'Snapshot is stale. Showing the last available data; current system health is not confirmed.';
    } else if (scenario.value === 'offline') {
      connection.textContent = 'Disconnected · sample';
      age.textContent = 'Last snapshot 8m ago';
      notice.textContent = 'Connection lost. Values below are from the last successful snapshot, not current observations.';
    }
  }
  if (['sample','stale','offline','empty'].includes(params.get('scenario'))) scenario.value = params.get('scenario');
  scenario.addEventListener('change', update);
  density.addEventListener('change', update);
  update();
})();
