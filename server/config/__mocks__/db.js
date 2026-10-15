// Manual Jest mock for config/db.js.
//
// Jest has a convention: if a file calls jest.mock('../config/db'), and a
// sibling __mocks__/db.js file exists next to the real config/db.js, Jest
// automatically substitutes THIS file instead of the real one — no matter
// what relative path a test used to require it. That's why this file lives
// at config/__mocks__/db.js, not inside the tests folder.
//
// Every controller in this app calls db.execute(sql, params) and expects
// back either [rows] (for a SELECT) or [result] (for an INSERT/UPDATE,
// where result has .insertId / .affectedRows) — exactly like the real
// mysql2 pool.promise() does. This fake object has the same shape, but as
// jest.fn()s a test fully controls, so no real database connection is ever
// opened.
// Default to resolving with an empty result set, not jest's usual
// `undefined` — several places in this codebase (e.g. bookingSocket.js's
// dbRun helper) call db.execute(...).then(...).catch(...) fire-and-forget,
// without awaiting it. If a test doesn't explicitly mock that particular
// call, `undefined.then` would throw a real TypeError instead of the test
// just not caring about that call. mockResolvedValueOnce() in a test still
// takes priority over this default for whichever call it targets.
module.exports = {
  execute: jest.fn().mockResolvedValue([[], {}]),
  query:   jest.fn().mockResolvedValue([[], {}]),
  getConnection: jest.fn(),
};
