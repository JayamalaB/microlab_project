// Plain-Node stand-in for config/firebase.js — never initializes a real
// Firebase Admin SDK. See mockDb.js's header for why this can't use
// jest.mock().
module.exports = { messaging: null };
