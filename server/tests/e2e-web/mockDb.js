// A plain-Node (no Jest) stand-in for config/db.js, used only by the
// standalone test server that Flutter's web integration_test drives — Jest
// isn't in the process here, so there's no jest.fn()/jest.mock() available;
// this hand-rolls the same "match the real query text, return a safe
// canned response" technique already proven throughout the Jest e2e suite
// (see tests/e2e/dispatch.e2e.test.js's installDispatchDbDefaults for the
// same pattern under Jest).
//
// Deliberately generic: a real Flutter integration_test drives the app
// through real, click-by-click navigation rather than one hand-scripted
// call sequence, so this can't be a strict ordered queue like the Jest
// e2e tests use — it has to answer whatever the app asks for, in whatever
// order the UI actually calls it. Unmatched queries fall back to an empty
// SELECT-shaped result, which every controller in this codebase already
// handles as "nothing found" without crashing (proven throughout the Jest
// suite's own default mock, which uses the identical fallback).
let nextId = 9000;

function fakeUserRow(mobile) {
  return {
    user_id: 501, client_id: 10, user_name: `user_${mobile}`,
    user_microlab_type: 'patient_user', user_mobile_no: mobile,
    user_auth_token: null, user_token_expiry: null, deleted_at: null,
  };
}

async function query(sql, params = []) {
  const s = sql.replace(/\s+/g, ' ').trim();

  // sendOtp: existing-user lookup — always "not found" so every run hits
  // the clean registration path deterministically.
  if (s.startsWith('SELECT') && s.includes('FROM ip_users') && s.includes('user_mobile_no')
      && !s.includes('user_otp')) {
    return [[]];
  }
  if (s.startsWith('INSERT INTO ip_users')) return [{ insertId: nextId++ }];
  if (s.startsWith('INSERT INTO ip_clients')) return [{ insertId: nextId++ }];
  if (s.startsWith('UPDATE ip_users') && s.includes('client_id')) return [{}];

  // verifyOtp: OTP is checked against whatever this mock says is on file —
  // authoritative by design (same technique as every Jest e2e OTP test in
  // this suite) — so ANY 4-digit code the Flutter app's real OTP screen
  // sends is accepted, without this test needing to know a real random OTP.
  if (s.startsWith('SELECT') && s.includes('FROM ip_users') && s.includes('user_otp = ?')) {
    const mobile = params[0];
    return [[fakeUserRow(mobile)]];
  }
  if (s.startsWith('UPDATE ip_users') && s.includes('user_otp = NULL')) return [{}];
  if (s.startsWith('SELECT * FROM ip_patients')) return [[]]; // new patient every run
  if (s.startsWith('INSERT INTO ip_patients')) return [{ insertId: nextId++ }];
  if (s.startsWith('UPDATE ip_users') && s.includes('user_auth_token')) return [{ affectedRows: 1 }]; // session claim

  return [[], {}];
}

async function execute(sql, params) { return query(sql, params); }

function getConnection() {
  return Promise.resolve({
    beginTransaction: async () => {},
    commit:           async () => {},
    rollback:         async () => {},
    release:          () => {},
    query,
    execute: query,
  });
}

module.exports = { query, execute, getConnection };
