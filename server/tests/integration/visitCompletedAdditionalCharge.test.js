// services/clientSync.js: syncVisitCompletionToClient — the technician's
// additional charge (amount + reason) reaches the ASMX in each booking's
// payment_details at Handed to Lab, with total_amount = the updated total.
//
// DB answers are keyed on the SQL text (not call order), so this only pins
// what the payment_details carry.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/secretCache', () => ({ getSecret: jest.fn().mockResolvedValue('test-secret'), refreshSecret: jest.fn() }));
jest.mock('../../services/asmxLogger', () => ({ logAsmx: jest.fn().mockResolvedValue() }));
jest.mock('../../services/branchCodes', () => ({ getBranchCode: jest.fn().mockResolvedValue('04') }));
const db       = require('../../config/db');
const settings = require('../../config/settings');
const http     = require('http');
const { syncVisitCompletionToClient } = require('../../services/clientSync');

const realHttpRequest = http.request;
afterEach(() => { http.request = realHttpRequest; });

const patient = (id, ref) => ({
  patient_id: id, patient_id_ref: ref, patient_name: `Patient ${id}`, patient_mobile: '9876543210',
  patient_gender: 'M', patient_city: 'Erode', patient_address: '12 MG Road', patient_email: null,
  patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null,
});

function wireDb(bookingRows) {
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    if (/FROM ip_bookings WHERE booking_id = \?/.test(sql) && /reference_no, visit_group_id\s+FROM/.test(sql)) {
      return [[{ booking_id: 900, booking_ref: '100000900', patient_id: 501, client_id: 10, branch_id: 4,
        status: 'completed', reference_no: null, visit_group_id: bookingRows.length > 1 ? 'VG1' : null }]];
    }
    if (/additional_charge_amount, (b\.)?additional_charge_reason/.test(sql)) return [bookingRows];
    if (/FROM ip_patients WHERE patient_id = \?/.test(sql)) return [[patient(params[0], `J${params[0]}`)]];
    if (/FROM ip_booking_items bi/.test(sql)) {
      return params[1] === 901
        ? [[{ booking_item_id: 3, product_id: 9, name: 'Lipid Profile', price: '300.00', test_code: 'T9' }]]
        : [[{ booking_item_id: 1, product_id: 7, name: 'CBC', price: '800.00', test_code: 'T7' },
            { booking_item_id: 2, product_id: 8, name: 'HbA1c', price: '400.00', test_code: 'T8' }]];
    }
    if (/FROM ip_payment_transactions/.test(sql)) return [[{ payment_type: 'CASH', amount_paid: 1299, amount_due: 0, gateway_transaction_id: null }]];
    if (/FROM ip_technicians t/.test(sql)) return [[{ user_name: 'Tech Suresh', technician_id_ref: '262' }]];
    if (/FROM ip_clients c/.test(sql)) return [[{ mobile: '9000000002' }]];
    return [[], {}];
  });
}

function captureAsmx() {
  const reqHandle = { write: jest.fn(), end: jest.fn(), on: jest.fn(), setTimeout: jest.fn(), destroy: jest.fn() };
  http.request = jest.fn((options, callback) => {
    const body = `<?xml version="1.0"?><string xmlns="http://tempuri.org/">${JSON.stringify({ status: 'success', results: [] })}</string>`;
    const res = {
      statusCode: 200,
      setEncoding: () => {},
      on: (event, handler) => {
        if (event === 'data') handler(Buffer.from(body));
        if (event === 'end') handler();
        return res;
      },
    };
    queueMicrotask(() => callback(res));
    return reqHandle;
  });
  return () => {
    const raw = String(reqHandle.write.mock.calls[0][0]);
    return JSON.parse(decodeURIComponent(raw.replace(/^visitCompleteJson=/, '')));
  };
}

beforeEach(() => {
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockImplementation((key, def) => (key === 'client_sync_timeout_ms' ? '10000' : def));
});

const row = (over) => ({
  booking_id: 900, booking_ref: '100000900', booking_type: 'home_collection', booking_date: '2026-10-26',
  total_amount: '1299.00', additional_charge_amount: '50.00', additional_charge_reason: 'Waited 30 min at customer location',
  patient_id: 501, client_id: 10, status: 'completed', reference_no: null, visit_group_id: null, slot_time: '10:00',
  ...over,
});

test('payment_details: test + service charge + additional charge = total, with the reason', async () => {
  wireDb([row()]);
  const payload = captureAsmx();
  await syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

  expect(http.request).toHaveBeenCalledTimes(1);
  // Exact keys and order of the agreed structure.
  expect(JSON.stringify(payload().bookings[0].payment_details)).toBe(JSON.stringify({
    test_amount:              1200,
    service_charge_amount:    49,
    additional_charge_amount: 50,
    additional_charge_reason: 'Waited 30 min at customer location',
    total_amount:             1299,
    paid_amount:              1299,
    payment_type:             'pay_later',
    razorpay_payment_id:      null,
  }));
});

test('a booking without an additional charge sends 0 and an empty reason', async () => {
  wireDb([row({ total_amount: '1249.00', additional_charge_amount: '0.00', additional_charge_reason: null })]);
  const payload = captureAsmx();
  await syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

  expect(payload().bookings[0].payment_details).toMatchObject({
    test_amount: 1200, service_charge_amount: 49,
    additional_charge_amount: 0, additional_charge_reason: '', total_amount: 1249,
  });
});

test('family visit — each booking carries its own additional charge', async () => {
  wireDb([
    row({ visit_group_id: 'VG1' }),
    row({ booking_id: 901, booking_ref: '100000901', patient_id: 502, visit_group_id: 'VG1',
      total_amount: '300.00', additional_charge_amount: '0.00', additional_charge_reason: null }),
  ]);
  const payload = captureAsmx();
  await syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

  const [self, member] = payload().bookings;
  expect(self.payment_details).toMatchObject({ test_amount: 1200, service_charge_amount: 49, additional_charge_amount: 50, total_amount: 1299 });
  expect(member.payment_details).toMatchObject({
    test_amount: 300, service_charge_amount: 0, additional_charge_amount: 0, additional_charge_reason: '', total_amount: 300,
  });
});
