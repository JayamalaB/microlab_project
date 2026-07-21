const http = require('http');

const API_KEY = process.env.PING4SMS_API_KEY;
const SENDER  = process.env.PING4SMS_SENDER_ID;

function _send(mobile, message, templateId) {
  const url =
    `http://site.ping4sms.com/api/smsapi` +
    `?key=${API_KEY}` +
    `&route=2` +
    `&sender=${SENDER}` +
    `&number=91${mobile}` +
    `&sms=${encodeURIComponent(message)}` +
    `&templateid=${templateId}`;

  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

exports.sendLoginOtp = (mobile, otp) => {
  const message = `Your OTP for Login is ${otp}. Valid for 10 minutes. Do not share this code with anyone. - Microlab`;
  return _send(mobile, message, process.env.PING4SMS_LOGIN_TEMPLATE_ID);
};

exports.sendBookingOtp = (mobile, otp) => {
  const template = process.env.PING4SMS_BOOKING_OTP_MESSAGE ||
    `Your OTP for sample collection completion is ${otp}. It is valid for 10 minutes. Please do not share this code with anyone.- Microlab`;
  // DLT templates use {#var#} as the variable placeholder
  const message = template.replace('{#var#}', otp);
  return _send(mobile, message, process.env.PING4SMS_BOOKING_OTP_TEMPLATE_ID);
};
