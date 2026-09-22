// Guards against any test accidentally making a real outbound network call —
// exactly the mistake caught in auth.sendOtp.test.js (the real SMS gateway
// got hit before utils/sms.js had a mock). Two different mechanisms are
// used in this codebase for outbound calls, so two different guards:
//
// 1. fetchFromRegistry (authController.js) uses the built-in global fetch()
//    — used for the Jayamala technician/patient registry lookups.
// 2. postJson (clientSync.js) uses Node's core http/https modules directly,
//    not fetch — used for every Jayamala sync (package_added, visit_completed,
//    etc). It is an internal, non-exported function, so it can't be mocked
//    directly without changing clientSync.js — instead, the underlying
//    http.request/https.request are mocked, which postJson calls into.

// ⚠️ SAME LEAK RISK AS mockHttpRequest BELOW, and worse: global.fetch is
// what BOTH the app's own outbound calls (fetchFromRegistry) AND, in an
// e2e/real-server test, your own test's calls to the real local server go
// through. Calling this without restoring afterward doesn't just risk
// breaking a later test file in the same worker — it can silently break
// every subsequent fetch() call in THIS SAME test file, including your own
// requests to the server under test (confirmed the hard way: an e2e login
// test called this once for the Jayamala registry lookup, and every fetch()
// call after it — including the test's own requests to the real backend —
// started returning the mocked Jayamala body instead of ever reaching the
// server). Callers MUST restore the original: `const real = global.fetch;
// afterEach(() => { global.fetch = real; })`.
// fetchFromRegistry (authController.js) reads the response via res.text(),
// not res.json() — it's an ASMX web service whose HTTP POST response wraps
// the real JSON payload in a <string xmlns="...">...</string> envelope,
// which fetchFromRegistry regexes out before JSON.parse'ing. Mocking only
// res.json() left res.text() undefined, which throws the moment real code
// calls it — silently swallowed by the customer path's own try/catch, but
// still not what a real registry response looks like.
function mockFetchOnce(jsonBody, status = 200) {
  global.fetch = jest.fn().mockResolvedValue({
    status,
    text: async () => `<string xmlns="http://tempuri.org/">${JSON.stringify(jsonBody)}</string>`,
  });
  return global.fetch;
}

// Mocks Node's http.request so nothing under test can open a real socket.
// Returns a controllable fake ClientRequest/response pair — call
// `respond(jsonBody)` after asserting the request was built correctly, or
// just call it immediately if the test doesn't need to inspect the request.
//
// ⚠️ CALLERS MUST RESTORE http.request AFTER EACH TEST (e.g.
// `const real = http.request; afterEach(() => { http.request = real; })`).
// Unlike a user module — which Jest sandboxes per test FILE — Node's core
// `http` module is one real, process-wide singleton shared by every test
// file in the same worker. Leaving this mock in place after the test that
// set it up will silently break (or hang) whatever suite runs next in that
// worker. This bit tests/integration/visitCompletedSync.test.js the first
// time it was written — `npx jest` (full suite) hung indefinitely until an
// afterEach restore was added there.
function mockHttpRequest(http, jsonBody, statusCode = 200) {
  const request = jest.fn((options, callback) => {
    const chunks = [];
    const res = {
      statusCode,
      on: (event, handler) => {
        if (event === 'data') handler(Buffer.from(JSON.stringify(jsonBody)));
        if (event === 'end') handler();
        return res;
      },
    };
    // Real http.request's callback fires asynchronously; queueMicrotask
    // keeps that same ordering instead of calling back synchronously.
    queueMicrotask(() => callback(res));
    return {
      write: jest.fn(),
      end: jest.fn(),
      on: jest.fn(),
      setTimeout: jest.fn(),
      destroy: jest.fn(),
    };
  });
  http.request = request;
  return request;
}

module.exports = { mockFetchOnce, mockHttpRequest };
