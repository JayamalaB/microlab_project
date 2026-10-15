// Manual Jest mock for utils/sms.js.
//
// The real module makes an actual HTTP call to a live SMS gateway — even
// with missing API credentials, it still fires the request (confirmed: it
// got a real response back in an early test run before this mock existed).
// Every test that exercises sendOtp/resendBookingOtp MUST mock this module,
// or it will send a real SMS to whatever phone number the test data uses.
module.exports = {
  sendLoginOtp:   jest.fn().mockResolvedValue('101'),
  sendBookingOtp: jest.fn().mockResolvedValue('101'),
};
