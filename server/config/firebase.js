const admin = require('firebase-admin');
const path  = require('path');

let messaging = null;

try {
  const serviceAccount = require(path.join(__dirname, '../firebase-service-account.json'));
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  messaging = admin.messaging();
  console.log('✅ [Firebase] Admin SDK initialized — FCM push enabled');
} catch (e) {
  console.warn('⚠️  [Firebase] Admin SDK not initialized:', e.message);
  console.warn('   Place firebase-service-account.json in server/ to enable push notifications.');
}

module.exports = { messaging };
