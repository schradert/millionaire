import { getWebInstrumentations, initializeFaro } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';
import { version } from '../package.json';

// Browser telemetry to the cluster's Alloy (nixidy/system/observability/alloy.nix, `faro.receiver`):
// errors, console, web vitals and navigation/session events go to Loki, traces to Tempo.
initializeFaro({
	url: 'https://faro.trdos.me/collect',
	app: { name: 'sveltekit-demo', version, environment: 'production' },
	sessionTracking: { enabled: true },
	instrumentations: [...getWebInstrumentations({ captureConsole: true }), new TracingInstrumentation()]
});
