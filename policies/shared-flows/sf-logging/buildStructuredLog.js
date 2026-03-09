/**
 * buildStructuredLog.js
 * SharedFlow : sf-logging
 * Purpose    : Construct a structured JSON log object from Apigee flow variables.
 *              Stored in 'logging.payload' for the MessageLogging policy.
 *
 * Log levels:
 *   ERROR  — 5xx response or fault.name is set
 *   WARN   — 4xx response
 *   INFO   — everything else
 */

(function buildLog() {
  "use strict";

  // ── Helper: safely get a flow variable ──────────────────────────────────────
  function getVar(name, fallback) {
    var val = context.getVariable(name);
    return (val !== null && val !== undefined) ? String(val) : (fallback || "");
  }

  // ── Timestamp ────────────────────────────────────────────────────────────────
  var now = new Date();
  var timestamp = now.toISOString();

  // ── Correlation ID ────────────────────────────────────────────────────────────
  // Use incoming header if present; otherwise use Apigee message ID.
  var correlationId = getVar("request.header.x-correlation-id") ||
                      getVar("messageid") ||
                      "no-correlation-id";

  // ── HTTP Details ──────────────────────────────────────────────────────────────
  var method      = getVar("request.verb",        "UNKNOWN");
  var path        = getVar("request.uri",          "/");
  var statusCode  = parseInt(getVar("response.status.code", "0"), 10);
  var clientIp    = getVar("client.ip",            "0.0.0.0");

  // ── Latency ───────────────────────────────────────────────────────────────────
  var startTime   = parseInt(getVar("client.received.start.timestamp", "0"), 10);
  var endTime     = parseInt(getVar("client.sent.end.timestamp", "0"), 10);
  var latencyMs   = (endTime > 0 && startTime > 0) ? (endTime - startTime) : -1;

  // ── Apigee Context ────────────────────────────────────────────────────────────
  var proxyName   = getVar("apiproxy.name",        "unknown-proxy");
  var environment = getVar("environment.name",      "unknown-env");
  var revision    = getVar("apiproxy.revision",     "0");
  var faultName   = getVar("fault.name",            "");
  var faultSource = getVar("fault.source",          "");

  // ── Auth Context (set by sf-auth) ─────────────────────────────────────────────
  var authClient  = getVar("auth.client_id",       "anonymous");
  var authMethod  = getVar("auth.method",          "none");
  var devEmail    = getVar("auth.developer_email", "");

  // ── Target ────────────────────────────────────────────────────────────────────
  var targetUrl   = getVar("target.url",           "");
  var targetLatency = parseInt(getVar("target.duration", "0"), 10);

  // ── Severity ──────────────────────────────────────────────────────────────────
  var severity;
  if (faultName || statusCode >= 500) {
    severity = "ERROR";
  } else if (statusCode >= 400) {
    severity = "WARN";
  } else {
    severity = "INFO";
  }

  // ── Assemble Log Payload ──────────────────────────────────────────────────────
  var logPayload = {
    timestamp:        timestamp,
    severity:         severity,
    proxy:            proxyName,
    revision:         revision,
    environment:      environment,
    correlation_id:   correlationId,
    client_ip:        clientIp,
    method:           method,
    path:             path,
    status_code:      statusCode,
    latency_ms:       latencyMs,
    target_latency_ms: targetLatency,
    target_url:       targetUrl,
    auth: {
      client:         authClient,
      method:         authMethod,
      developer:      devEmail
    },
    error: faultName ? {
      code:    faultName,
      source:  faultSource
    } : null
  };

  // ── Remove null fields for cleaner logs ───────────────────────────────────────
  Object.keys(logPayload).forEach(function(key) {
    if (logPayload[key] === null || logPayload[key] === "") {
      delete logPayload[key];
    }
  });

  // ── Store for MessageLogging policy ───────────────────────────────────────────
  context.setVariable("logging.payload", JSON.stringify(logPayload));
  context.setVariable("logging.severity", severity);

}());
