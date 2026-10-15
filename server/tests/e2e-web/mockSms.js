// Plain-Node stand-in for utils/sms.js — see mockDb.js's header for why
// this can't use jest.mock(). Never touches the real Ping4SMS gateway.
module.exports = {
  sendLoginOtp:   async () => '101',
  sendBookingOtp: async () => '101',
};
