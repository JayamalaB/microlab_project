// Jest configuration for the Microlab backend.
//
// testEnvironment 'node' (not the default 'jsdom') because this is a
// server — no browser DOM is ever involved.
//
// testTimeout is raised from Jest's 5s default because the Socket.IO
// integration tests spin up a real (local, ephemeral) server and client
// and wait for real network round-trips between them, which is slower
// than a pure-function assertion.
module.exports = {
  testEnvironment: 'node',
  testTimeout: 10000,
  testMatch: ['**/tests/**/*.test.js'],
  setupFiles: ['<rootDir>/tests/setupEnv.js'],
  verbose: true,
};
