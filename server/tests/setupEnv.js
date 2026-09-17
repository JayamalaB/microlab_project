// Runs once, before any test file's own code loads (wired in via
// jest.config.js's `setupFiles`). Fixed, fake values only — tests must never
// depend on a real .env file or real secrets being present. Anything a
// controller reads via process.env.* at call time needs a safe stand-in
// here so tests behave identically on any machine.
process.env.JWT_SECRET           = 'test-jwt-secret-not-a-real-secret';
process.env.CLIENT_SERVER_SECRET = 'test-client-server-secret';
process.env.CLIENT_BOOKING_URL   = 'http://localhost:0/mock-jayamala'; // never actually called — postJson is mocked per-test
process.env.OTP_MAX_ATTEMPTS     = '3';
process.env.OTP_EXPIRY_MINUTES   = '10';
