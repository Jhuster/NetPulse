//#region src/config/defaultConfig.d.ts
interface LatencyMeasurementConfig {
  type: 'latency';
  /** Number of latency pings to send in this phase. */
  numPackets: number;
}
interface BandwidthMeasurementConfig {
  type: 'download' | 'upload';
  /** Payload size per HTTP request in bytes (e.g., 1e5 = 100KB, 1e7 = 10MB). */
  bytes: number;
  /** Number of requests to issue at this payload size. */
  count: number;
  /** If `true`, skip the minimum-duration filter for this round. */
  bypassMinDuration?: boolean;
}
/** WebRTC TURN-based packet loss measurement phase. */
interface PacketLossMeasurementConfig {
  type: 'packetLoss';
  /** Total number of UDP messages to send through the TURN relay. */
  numPackets: number;
  /** Number of messages sent in each batch. */
  batchSize: number;
  /** Delay between consecutive batches (ms). */
  batchWaitTime: number;
  /** Time to wait for outstanding responses after the last batch (ms). */
  responsesWaitTime: number;
  /** Timeout for the WebRTC connection setup (ms). */
  connectionTimeout?: number;
}
type MeasurementConfig = LatencyMeasurementConfig | BandwidthMeasurementConfig | PacketLossMeasurementConfig;
/**
 * Fully-specified speed test configuration — every option present.
 *
 * This is the shape of {@link defaultConfig}. Consumers don't construct this
 * directly; they pass a {@link ConfigOptions} (a partial) to the engine, which
 * merges it over the defaults.
 */
interface Config {
  /** Whether to start the test immediately on construction. Default: `true`. */
  autoStart: boolean;
  /** URL for download requests. Default: `https://speed.cloudflare.com/__down`. */
  downloadApiUrl: string;
  /** URL for upload requests. Default: `https://speed.cloudflare.com/__up`. */
  uploadApiUrl: string;
  /** URL for per-measurement logging. Set to `null` to disable. Default: `null`. */
  logMeasurementApiUrl: string | null;
  /** URL for logging test results. Set to `null` to disable. Default: `https://speed.cloudflare.com/__results`. */
  logAimApiUrl: string | null;
  /**
   * TURN server URI for packet loss measurement, e.g. `turn.cloudflare.com:3478`.
   * Default: `null`, so a `packetLoss` measurement needs your own TURN setup.
   */
  turnServerUri: string | null;
  /** URL for fetching TURN server credentials. Default: `null`. */
  turnServerCredsApiUrl: string | null;
  /** Static TURN username override. Set to `null` to fetch credentials dynamically. */
  turnServerUser: string | null;
  /** Static TURN password override. Set to `null` to fetch credentials dynamically. */
  turnServerPass: string | null;
  /** Hostname used to test RPKI invalid-route filtering. */
  rpkiInvalidHost: string;
  /** Whether to include credentials (cookies) in fetch requests. Default: `false`. */
  includeCredentials: boolean;
  /** Optional session ID attached to measurement logs. */
  sessionId: string | undefined;
  /**
   * Opaque token attributing this test to a registered customer, sent as an
   * `Authorization: Bearer` header on the measurement, TURN credential and
   * results-logging requests. Requires {@link authorizationEnabled}; on its own
   * it is never sent. Not sent over plain HTTP. Default: `null`.
   *
   * @experimental Unstable — may change or be removed in any release.
   */
  authorizationToken: string | null;
  /**
   * Opts in to sending {@link authorizationToken}, which is otherwise withheld
   * even when set.
   *
   * `'header'` and `true` both send it as `Authorization: Bearer`; `true` is a
   * permanent alias for `'header'`, so a future transport can be added without
   * changing what an existing config does. `false` and `undefined` send
   * nothing. Default: `undefined`.
   *
   * @experimental Unstable — may change or be removed in any release.
   */
  authorizationEnabled: 'header' | boolean | undefined;
  /**
   * Sends {@link authorizationToken} even when the endpoint is not HTTPS, for
   * local development against an `http://` server.
   *
   * Never enable this in production: the server treats a token seen over
   * plaintext as compromised and revokes it. Default: `false`.
   *
   * @experimental Unstable — may change or be removed in any release.
   */
  allowInsecureAuthorizationToken: boolean;
  /**
   * Ordered list of measurement phases to execute.
   *
   * Each entry describes a latency, bandwidth, or packet loss step.
   * The engine executes them sequentially, skipping further rounds of a
   * bandwidth type once its finish threshold is reached.
   *
   * Multiple `latency`, `download`, and `upload` steps accumulate their
   * results. Other measurement types (e.g. `packetLoss`) replace prior
   * results if multiple steps of the same type are configured.
   */
  measurements: MeasurementConfig[];
  measureDownloadLoadedLatency: boolean;
  measureUploadLoadedLatency: boolean;
  /** Minimum interval between loaded-latency pings (ms). Default: `400`. */
  loadedLatencyThrottle: number;
  /**
   * Per-request duration threshold (ms) that, once reached, stops further
   * measurement rounds of that bandwidth type. Default: `1000`.
   */
  bandwidthFinishRequestDuration: number;
  /**
   * Estimated server processing time (ms) subtracted from raw latency when
   * the server doesn't report its own processing time in headers. Default: `0`.
   */
  estimatedServerTime: number;
  /**
   * Per-request duration (ms) at which to abort the current request and stop
   * further rounds of that bandwidth type. Set to `0` to disable. Default: `0`.
   */
  bandwidthAbortRequestDuration: number;
  /** Percentile used to compute latency from the sample set (0–1). Default: `0.5` (median). */
  latencyPercentile: number;
  /** Percentile used to compute bandwidth from the sample set (0–1). Default: `0.9`. */
  bandwidthPercentile: number;
  /** Minimum request duration (ms) for a sample to be included in bandwidth calculation. Default: `10`. */
  bandwidthMinRequestDuration: number;
  /** Minimum request duration (ms) for a download/upload round to be considered "loading" the connection. Default: `250`. */
  loadedRequestMinDuration: number;
  /** Maximum number of loaded-latency data points to retain (most recent kept). Default: `20`. */
  loadedLatencyMaxPoints: number;
}
/**
 * User-facing configuration for the speed test engine.
 *
 * A partial of {@link Config}: pass any subset to the engine constructor to
 * override individual options; omitted properties fall back to their defaults
 * in {@link defaultConfig}.
 */
type ConfigOptions = Partial<Config>;
//#endregion
//#region src/config/internalConfig.d.ts
type AimMetricKey = 'packetLoss' | 'latency' | 'loadedLatencyIncrease' | 'jitter' | 'download' | 'upload';
type AimExperienceKey = 'streaming' | 'gaming' | 'rtc';
interface AimExperienceDef {
  input: AimMetricKey[];
  pointThresholds: number[];
}
interface InternalConfig {
  aimMeasurementScoring: Record<AimMetricKey, (value: number) => number>;
  aimExperiencesDefs: Record<AimExperienceKey, AimExperienceDef>;
}
//#endregion
//#region src/types.d.ts
/**
 * Shared interfaces used across the speed-test library.
 *
 * Data-structure types consumed by {@link Results} and the measurement engines.
 */
interface LatencyTiming {
  /** Round-trip latency to the measurement endpoint (ms). */
  ping: number;
}
/**
 * Raw timing data produced by a single bandwidth (download / upload) request.
 */
interface BandwidthTiming {
  /** Bits per second. */
  bps: number;
  /** Total request duration excluding server processing time (ms). */
  duration: number;
  /** Round-trip latency to the measurement endpoint (ms). */
  ping: number;
  /** Timestamp when the measurement sample was recorded. */
  measTime: Date;
  /**
   * Server-side processing time in milliseconds, extracted from the
   * `Server-Timing` response header. `-1` when unavailable.
   */
  serverTime: number;
  /** Actual number of bytes transferred (from `PerformanceResourceTiming`). */
  transferSize: number;
}
/**
 * A single data point derived from a bandwidth measurement, enriched with the
 * originating payload size. Returned by `getBandwidthPoints()`.
 */
interface BandwidthPoint {
  /** Payload size in bytes. */
  bytes: number;
  /** Bits per second. */
  bps: number;
  /** Total request duration excluding server processing time (ms). */
  duration: number;
  /** Round-trip latency to the measurement endpoint (ms). */
  ping: number;
  /** Timestamp when the measurement sample was recorded. */
  measTime: Date;
  /** Milliseconds. `-1` when unavailable. */
  serverTime: number;
  /** From `PerformanceResourceTiming`. */
  transferSize: number;
}
/** Results from a packet-loss measurement via WebRTC TURN relay. */
interface PacketLossResults {
  /** Total number of messages the test was configured to send. */
  totalMessages: number;
  /** Number of messages actually sent (may differ if sending was cut short). */
  numMessagesSent: number;
  /**
   * Fraction of sent messages that were lost (0 – 1).
   * Computed as `lostMessages.length / numMessagesSent`.
   */
  packetLoss: number;
  /** Sequence numbers of the messages that were not echoed back. */
  lostMessages: number[];
}
/** Results from a simple reachability (fetch) check against a host. */
interface ReachabilityResults {
  host: string;
  reachable: boolean;
}
//#endregion
//#region src/Results/MeasurementCalculations.d.ts
interface MeasurementCalcConfig {
  /** Percentile (0–1) used for latency calculation. */
  latencyPercentile: number;
  /** Percentile (0–1) used for bandwidth calculation. */
  bandwidthPercentile: number;
  /** Minimum request duration (ms) for a sample to count toward bandwidth. */
  bandwidthMinRequestDuration: number;
  /** Minimum request duration (ms) for a round to be considered "loading" the connection. */
  loadedRequestMinDuration: number;
  /** Maximum number of loaded-latency points to retain. */
  loadedLatencyMaxPoints: number;
}
//#endregion
//#region src/Results/ScoresCalculations.d.ts
/** Human-readable quality classification (worst to best). */
type ClassificationName = 'bad' | 'poor' | 'average' | 'good' | 'great';
/** AIM experience score for a single use-case (e.g. streaming, gaming, rtc). */
interface ExperienceScore {
  /** Aggregate point total (higher is better). */
  points: number;
  /** Classification bucket index (0 = bad, 4 = great). */
  classificationIdx: number;
  classificationName: ClassificationName;
}
type Scores = Record<string, ExperienceScore>;
/** Flat measurement summary values (the output of {@link Results.getSummary}). */
interface MeasurementSummary {
  /** Download bandwidth (bits per second). */
  download?: number;
  /** Upload bandwidth (bits per second). */
  upload?: number;
  /** Unloaded latency (ms). */
  latency?: number;
  /** Unloaded jitter (ms). */
  jitter?: number;
  /** Download loaded latency (ms). */
  downLoadedLatency?: number;
  /** Download loaded jitter (ms). */
  downLoadedJitter?: number;
  /** Upload loaded latency (ms). */
  upLoadedLatency?: number;
  /** Upload loaded jitter (ms). */
  upLoadedJitter?: number;
  /** Packet loss ratio (0–1). */
  packetLoss?: number;
  v4Reachability?: boolean;
  v6Reachability?: boolean;
  /** Total test duration excluding paused time (ms). */
  totalDurationMs?: number;
  [key: string]: number | boolean | undefined;
}
/** Definition of an AIM experience (e.g. streaming), listing its input metrics and score thresholds. */
interface ExperienceDef {
  /** Metric keys whose scores are summed to produce the experience score. */
  input: string[];
  /** Point thresholds that map the sum to a classification (bad → great). */
  pointThresholds: number[];
}
interface ScoresCalcConfig {
  /** Maps each metric key to a function that converts a raw value to AIM points. */
  aimMeasurementScoring: Record<string, (val: number) => number>;
  /** Defines each experience category, its input metrics, and classification thresholds. */
  aimExperiencesDefs: Record<string, ExperienceDef>;
}
//#endregion
//#region src/Results/index.d.ts
interface MeasurementDef {
  type: string;
  [key: string]: unknown;
}
interface ResultsConfig extends MeasurementCalcConfig, ScoresCalcConfig {
  measurements: MeasurementDef[];
}
interface RawMeasurementEntry {
  started: boolean;
  finished: boolean;
  /** Keyed by byte-size or measurement-specific keys. */
  results: Record<string, unknown>;
  /** Bandwidth types only — indicates the current round is done but more rounds remain. */
  finishedCurrentRound?: boolean;
  error?: string;
  [key: string]: unknown;
}
interface RawResults {
  /** Excluding paused time (ms). */
  totalDurationMs: number | undefined;
  [key: string]: RawMeasurementEntry | number | undefined;
}
/**
 * Aggregates raw measurement data and exposes computed metrics (latency,
 * bandwidth, jitter, packet loss, scores) via getter methods.
 *
 * Instances are created internally by `MeasurementEngine` — consumers read
 * results through the engine's `results` property.
 */
declare class Results {
  #private;
  constructor(config: ResultsConfig);
  /**
   * The underlying raw measurement data, keyed by measurement type.
   *
   * Updated in-place by the engine as results arrive. Useful for building
   * custom visualisations or debugging; prefer the typed getter methods
   * for computed values.
   */
  raw: RawResults;
  get isFinished(): boolean;
  clear(): void;
  /** Unloaded latency at the configured percentile (ms), or `undefined` if not yet measured. */
  getUnloadedLatency: () => number | undefined;
  /** Unloaded jitter (ms), `null` if fewer than 2 samples, or `undefined` if not yet measured. */
  getUnloadedJitter: () => number | null | undefined;
  /** Raw unloaded latency ping values (ms). Returns `[]` if not yet measured. */
  getUnloadedLatencyPoints: () => number[];
  /** Download loaded latency at the configured percentile (ms), or `undefined` if not yet measured. */
  getDownLoadedLatency: () => number | undefined;
  /** Download loaded jitter (ms), `null` if fewer than 2 samples, or `undefined` if not yet measured. */
  getDownLoadedJitter: () => number | null | undefined;
  /** Raw download loaded-latency ping values (ms). Returns `[]` if not yet measured. */
  getDownLoadedLatencyPoints: () => number[];
  /** Upload loaded latency at the configured percentile (ms), or `undefined` if not yet measured. */
  getUpLoadedLatency: () => number | undefined;
  /** Upload loaded jitter (ms), `null` if fewer than 2 samples, or `undefined` if not yet measured. */
  getUpLoadedJitter: () => number | null | undefined;
  /** Raw upload loaded-latency ping values (ms). Returns `[]` if not yet measured. */
  getUpLoadedLatencyPoints: () => number[];
  /** Download bandwidth at the configured percentile (bits per second), or `undefined` if not yet measured. */
  getDownloadBandwidth: () => number | undefined;
  /** Raw download bandwidth data points. Returns `[]` if not yet measured. */
  getDownloadBandwidthPoints: () => BandwidthPoint[];
  /** Upload bandwidth at the configured percentile (bits per second), or `undefined` if not yet measured. */
  getUploadBandwidth: () => number | undefined;
  /** Raw upload bandwidth data points. Returns `[]` if not yet measured. */
  getUploadBandwidthPoints: () => BandwidthPoint[];
  /** Packet loss ratio (0–1), or `undefined` if not yet measured. */
  getPacketLoss: () => number | undefined;
  /** Detailed packet loss results, an `{ error }` object on failure, or `undefined` if not yet measured. */
  getPacketLossDetails: () => PacketLossResults | {
    error: string;
  } | undefined;
  /** Total test duration excluding paused time (ms), or `undefined` if still running. */
  getTotalDurationMs: () => number | undefined;
  /**
   * Returns a flat summary of all available measurements.
   *
   * Only includes keys for measurement types that have produced results;
   * keys with `undefined` values are omitted from the returned object.
   */
  getSummary(): MeasurementSummary;
  /**
   * Computes AIM experience scores (streaming, gaming, rtc) from the current
   * measurement summary. Each score includes a point total, classification
   * index (0–4), and classification name (bad → great). Packet loss is left
   * out when no `packetLoss` measurement is configured.
   */
  getScores: () => Scores;
}
//#endregion
//#region src/utils/authorization.d.ts
/**
 * The token and the policy decisions that govern it, passed as one unit so a
 * transport change touches this module instead of every call site.
 */
interface AuthorizationOptions {
  /** See config `authorizationToken`. */
  token: string | null;
  /** See config `authorizationEnabled`. */
  enabled: 'header' | boolean | undefined;
  /** See config `allowInsecureAuthorizationToken`. */
  allowInsecure: boolean;
}
//#endregion
//#region src/logging/logFinalResults.d.ts
/** Response returned by the AIM logging endpoint. */
interface AimLogResponse {
  /** Unique identifier assigned to this measurement, used to look it up later. */
  requestId?: string;
}
//#endregion
//#region src/index.d.ts
/** All measurement types the engine can encounter at runtime. */
type MeasurementType = 'latency' | 'latencyUnderLoad' | 'download' | 'upload' | 'packetLoss' | 'packetLossUnderLoad' | 'v4Reachability' | 'v6Reachability' | 'rpki' | 'nxdomain';
/**
 * A single measurement step configuration. The exact properties depend on
 * `type`, but in the switch statement we destructure dynamically so we use a
 * loose shape that captures every property any branch may need.
 */
interface MeasurementStep {
  /** Measurement type to execute (e.g., 'latency', 'download', 'packetLoss'). */
  type: MeasurementType;
  /** Number of latency pings to send (latency/latencyUnderLoad types). */
  numPackets?: number;
  /** Payload size per request in bytes (download/upload types). */
  bytes?: number;
  /** Number of requests to issue at this payload size (download/upload types). */
  count?: number;
  /** Skip the minimum-duration filter for this round (download/upload types). */
  bypassMinDuration?: boolean;
  /** Number of packets sent per batch (packetLoss types). */
  batchSize?: number;
  /** Delay between batches in ms (packetLoss types). */
  batchWaitTime?: number;
  /** Time to wait for outstanding responses after the last batch in ms (packetLoss types). */
  responsesWaitTime?: number;
  /** WebRTC connection setup timeout in ms (packetLoss types). */
  connectionTimeout?: number;
  /** Whether to generate download load during the measurement. */
  loadDown?: boolean;
  /** Whether to generate upload load during the measurement. */
  loadUp?: boolean;
  /** Target hostname for reachability probes. */
  host?: string;
  /** Target hostname for NXDOMAIN checks. */
  nxhost?: string;
  [key: string]: unknown;
}
/** The merged config object (defaultConfig + userConfig + internalConfig). */
type SpeedTestConfig = Config & InternalConfig & {
  measurements: MeasurementStep[];
} & {
  [key: string]: unknown;
};
/** Payload emitted when the engine advances to a new measurement phase. */
interface PhaseChangePayload {
  /** Index of the current measurement step within the configured measurements array. */
  measurementId: number;
  /** Configuration of the measurement phase that is starting. */
  measurement: MeasurementConfig;
}
/**
 * Core speed test engine that orchestrates measurement phases (latency,
 * download, upload, packet loss, reachability) and exposes results via
 * callbacks and the {@link results} property.
 *
 * @example
 * ```ts
 * const engine = new MeasurementEngine({ autoStart: false });
 * engine.onResultsChange = () => console.log(engine.results.getSummary());
 * engine.onFinish = results => console.log('Done!', results.getScores());
 * engine.play();
 * ```
 */
declare class MeasurementEngine {
  #private;
  constructor(userConfig?: ConfigOptions);
  get results(): Results;
  /** The merged config, so subclasses need not rebuild it. */
  protected get config(): SpeedTestConfig;
  /** The token and its transport policy, as one unit for the sub-engines. */
  protected get authorization(): AuthorizationOptions;
  /** Not paused and not finished. */
  get isRunning(): boolean;
  get isFinished(): boolean;
  onRunningChange: (running: boolean) => void;
  onResultsChange: (payload: {
    type: MeasurementType;
  }) => void;
  onPhaseChange: (payload: PhaseChangePayload) => void;
  set onFinish(f: (results: Results) => void);
  set onError(f: (message: string, status?: number) => void);
  /**
   * Pauses the test. The current measurement phase is suspended (if pausable)
   * and can be resumed with {@link play}. Accumulated runtime is preserved.
   */
  pause(): void;
  /**
   * Starts or resumes the test.
   *
   * On first call, clears the browser's resource timing buffer and begins
   * the measurement sequence. On subsequent calls after {@link pause},
   * resumes the current phase.
   */
  play(): void;
  restart(): void;
}
/**
 * Extended {@link MeasurementEngine} that automatically logs final AIM scores
 * to the configured `logAimApiUrl` when the test completes.
 *
 * This is the default export of the library and the recommended entry point
 * for most consumers.
 *
 * @example
 * ```ts
 * import SpeedTest from '@cloudflare/speedtest';
 *
 * const engine = new SpeedTest();
 * engine.onFinish = results => console.log(results.getScores());
 * engine.onResultsLogged = ({ requestId }) => console.log('Logged as', requestId);
 * ```
 */
declare class SpeedTestEngine extends MeasurementEngine {
  #private;
  constructor(userConfig?: ConfigOptions);
  /**
   * Called when all measurement phases have completed.
   *
   * The user-supplied callback runs first, then final results are logged
   * to the AIM API automatically.
   */
  set onFinish(onFinish: (results: Results) => void);
  /**
   * Called after the final results have been logged to the AIM API, with the
   * endpoint's parsed response (e.g. the assigned `requestId`).
   *
   * Fires whenever logging is attempted (`logAimApiUrl` is set), after the log
   * request completes — on success or failure. On failure, `requestId` is
   * `undefined`. Because the log request completes after {@link onFinish}, this
   * callback runs slightly later.
   */
  onResultsLogged: (response: AimLogResponse) => void;
}
//#endregion
export { type AimLogResponse, type BandwidthPoint, type BandwidthTiming, type ClassificationName, type ConfigOptions, type ExperienceScore, type LatencyTiming, type MeasurementConfig, type MeasurementSummary, type MeasurementType, type PacketLossResults, type PhaseChangePayload, type ReachabilityResults, type Results, type Scores, SpeedTestEngine as default };
//# sourceMappingURL=speedtest.d.ts.map