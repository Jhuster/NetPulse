const SpeedTest = window.CloudflareSpeedTest;

let engine, session, active = false, scheduled = 0, requests = 0, phase = 'preparing';
const controllers = new Set();
const originalFetch = window.fetch.bind(window);
const emit = (event, extra = {}) => {
  if (session) window.webkit.messageHandlers.speed.postMessage({event, session, phase, scheduledBytes: scheduled, ...extra});
};
const finite = value => Number.isFinite(value) && value >= 0 ? value : null;
const snapshot = () => {
  if (!engine) return {};
  const summary = Object.fromEntries(Object.entries(engine.results.getSummary()).map(([k, v]) => [k, finite(v)]));
  const points = ['download', 'upload'].flatMap(kind => {
    const values = kind === 'download' ? engine.results.getDownloadBandwidthPoints() : engine.results.getUploadBandwidthPoints();
    return values.map((p, i) => ({id: `${kind}-${i}`, kind, bps: finite(p.bps), duration: finite(p.duration), date: new Date(p.measTime).toISOString()}));
  }).filter(p => p.bps !== null).slice(-1000);
  return {summary, points};
};
const stop = () => {
  active = false;
  try { engine?.pause(); } catch (_) {}
  for (const controller of controllers) controller.abort();
  controllers.clear();
};
window.netpulse = {
  start(config) {
    stop(); session = config.session; scheduled = 0; requests = 0; active = true;
    window.fetch = async (input, init = {}) => {
      const url = new URL(typeof input === 'string' ? input : input.url);
      if (!active || url.origin !== 'https://speed.cloudflare.com' || !['/__down', '/__up'].includes(url.pathname)) throw new Error('Request not allowed');
      const body = init.body;
      const bytes = url.pathname === '/__down' ? Number(url.searchParams.get('bytes') || 0) : (typeof body === 'string' ? new TextEncoder().encode(body).byteLength : body?.size ?? body?.byteLength ?? 0);
      if (!Number.isSafeInteger(bytes) || bytes < 0 || scheduled + bytes > config.budget || ++requests > 512) {
        emit('error', {message: '已到测试数据预算或请求上限'}); stop(); throw new Error('Payload budget exceeded');
      }
      scheduled += bytes;
      const controller = new AbortController(); controllers.add(controller);
      const abort = () => controller.abort();
      if (init.signal?.aborted) controller.abort();
      else init.signal?.addEventListener('abort', abort, {once: true});
      const timeout = setTimeout(abort, 20000);
      const cleanup = () => { clearTimeout(timeout); controllers.delete(controller); init.signal?.removeEventListener('abort', abort); };
      try {
        const response = await originalFetch(input, {...init, signal: controller.signal, credentials: 'omit', cache: 'no-store'});
        if (!response.ok) cleanup();
        // Keep cancellation and timeout alive through body consumption. fetch()
        // itself resolves at headers, before the transfer has finished.
        for (const method of ['text', 'arrayBuffer', 'blob', 'json']) {
          const consume = response[method].bind(response);
          response[method] = async () => { try { return await consume(); } finally { cleanup(); } };
        }
        return response;
      } catch (error) { cleanup(); throw error; }
    };
    engine = new SpeedTest({autoStart: false, logAimApiUrl: null, logMeasurementApiUrl: null,
      measurements: config.measurements, measureDownloadLoadedLatency: true, measureUploadLoadedLatency: true,
      bandwidthAbortRequestDuration: 10000, bandwidthFinishRequestDuration: 1000});
    engine.onPhaseChange = payload => { if (active) { phase = payload.measurement.type; emit('update', {...snapshot(), step: payload.measurementId + 1}); } };
    engine.onResultsChange = () => { if (active) emit('update', snapshot()); };
    engine.onError = message => { if (active) { emit('error', {...snapshot(), message: String(message).slice(0, 500)}); stop(); } };
    engine.onFinish = () => { if (active) { emit('finish', snapshot()); stop(); } };
    engine.play();
  },
  stop() { stop(); emit('stopped', snapshot()); }
};
window.webkit.messageHandlers.speed.postMessage({event: 'ready'});
