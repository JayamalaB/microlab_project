// services/clientSync.js: syncVisitCompletionToClient — charge packages the
// technician added on site reach the ASMX at Handed to Lab as test lines in
// blood_test_list (like the customer's service charge). payment_details has
// no additional_charge_* fields; every charge is inside total_amount.
//
// DB answers are keyed on the SQL text (not call order).
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

const patient = (id) => ({
  patient_id: id, patient_id_ref: `J${id}`, patient_name: `Patient ${id}`, patient_mobile: '9876543210',
  patient_gender: 'M', patient_city: 'Erode', patient_address: '12 MG Road', patient_email: null,
  patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null,
});

const row = (over) => ({
  booking_id: 900, booking_ref: '100000900', booking_type: 'home_collection', booking_date: '2026-10-26',
  home_collection_fare: '0.00', total_amount: '1250.00', additional_charge_amount: '450.00',
  additional_charge_reason: null, amount_due: '0.00',
  patient_id: 501, client_id: 10, status: 'completed', reference_no: null, visit_group_id: null, slot_time: '10:00',
  ...over,
});

// charges: booking_id → its active ip_booking_additional_charges rows.
function wireDb(bookingRows, charges) {
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    if (/FROM ip_bookings WHERE booking_id = \?/.test(sql) && /reference_no, visit_group_id\s+FROM/.test(sql)) {
      return [[{ booking_id: 900, booking_ref: '100000900', patient_id: 501, client_id: 10, branch_id: 4,
        status: 'completed', reference_no: null, visit_group_id: bookingRows.length > 1 ? 'VG1' : null }]];
    }
    if (/partial_payment_reason, (b\.)?amount_due/.test(sql)) return [bookingRows];
    if (/FROM ip_booking_additional_charges/.test(sql)) return [charges[params[0]] ?? []];
    if (/FROM ip_patients WHERE patient_id = \?/.test(sql)) return [[patient(params[0])]];
    if (/FROM ip_booking_items bi/.test(sql)) {
      return [[{ booking_item_id: 1, product_id: 7, name: 'CBC', price: '800.00', test_code: 'T7' }]];
    }
    if (/FROM ip_payment_transactions/.test(sql)) return [[{ payment_type: 'CASH', amount_paid: 1250, amount_due: 0, gateway_transaction_id: null }]];
    if (/FROM ip_technicians t/.test(sql)) return [[{ user_name: 'Tech Suresh', technician_id_ref: '262' }]];
    if (/FROM ip_clients c/.test(sql)) return [[{ mobile: '9000000002' }]];
    return [[], {}];
  });
}

function captureAsmx() {
  const reqHandle = { write: jest.fn(), end: jest.fn(), on: jest.fn(), setTimeout: jest.fn(), destroy: jest.fn() };
  http.request = jest.fn((options, callback) => {
    const body = `<?xml version="1.0"?><string xmlns="http://tempuri.org/">${JSON.stringify({ status: 'success' })}</string>`;
    const res = {
      statusCode: 200,
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

const send = () => syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

beforeEach(() => {
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockImplementation((key, def) => (key === 'client_sync_timeout_ms' ? '10000' : def));
});

test('each package is its own test line, and payment_details has no additional charge fields', async () => {
  wireDb([row()], {
    900: [
      { product_name: 'Home Visit Extra', test_code: 'SC2', price: '100.00' },
      { product_name: 'Vitamin D', test_code: 'T22', price: '350.00' },
    ],
  });
  const payload = captureAsmx();
  await send();

  const b = payload().bookings[0];
  expect(b.blood_test_list).toEqual([
    { TestId: 'T7', TestName: 'CBC', Rate: '800.00' },
    { TestId: 'SC2', TestName: 'Home Visit Extra', Rate: 100 },
    { TestId: 'T22', TestName: 'Vitamin D', Rate: 350 },
  ]);
  expect(b.payment_details.total_amount).toBe(1250);
  expect(b.payment_details).not.toHaveProperty('additional_charge_amount');
  expect(b.payment_details).not.toHaveProperty('additional_charge_reason');
});

test('an older typed charge is not sent as its own field — it is inside total_amount', async () => {
  wireDb([row({ total_amount: '1300.00', additional_charge_amount: '500.00', additional_charge_reason: 'Waited 30 min' })], {
    900: [{ product_name: 'Vitamin D', test_code: 'T22', price: '450.00' }],
  });
  const payload = captureAsmx();
  await send();

  const pd = payload().bookings[0].payment_details;
  expect(pd.total_amount).toBe(1300);
  expect(pd).not.toHaveProperty('additional_charge_amount');
  expect(pd).not.toHaveProperty('additional_charge_reason');
});

test('a package without a test code is not a test line; its price stays in total_amount', async () => {
  wireDb([row({ total_amount: '900.00', additional_charge_amount: '100.00' })], {
    900: [{ product_name: 'No Code Charge', test_code: null, price: '100.00' }],
  });
  const payload = captureAsmx();
  await send();

  const b = payload().bookings[0];
  expect(b.blood_test_list.map(t => t.TestId)).toEqual(['T7']);
  expect(b.payment_details.total_amount).toBe(900);
  expect(b.payment_details).not.toHaveProperty('additional_charge_amount');
});

test('family visit: each member sends only their own packages', async () => {
  wireDb([
    row({ visit_group_id: 'VG1', additional_charge_amount: '100.00' }),
    row({ booking_id: 901, booking_ref: '100000901', patient_id: 502, visit_group_id: 'VG1', additional_charge_amount: '0.00' }),
  ], {
    900: [{ product_name: 'Home Visit Extra', test_code: 'SC2', price: '100.00' }],
  });
  const payload = captureAsmx();
  await send();

  const [self, member] = payload().bookings;
  expect(self.blood_test_list.map(t => t.TestId)).toEqual(['T7', 'SC2']);
  expect(member.blood_test_list.map(t => t.TestId)).toEqual(['T7']);
});

test('before the migration (no table) the visit still syncs', async () => {
  wireDb([row({ additional_charge_amount: '0.00' })], {});
  const base = db.execute.getMockImplementation();
  db.execute.mockImplementation(async (sql, params) => {
    if (/FROM ip_booking_additional_charges/.test(sql)) throw Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' });
    return base(sql, params);
  });
  const payload = captureAsmx();
  await send();

  expect(http.request).toHaveBeenCalledTimes(1);
  expect(payload().bookings[0].blood_test_list.map(t => t.TestId)).toEqual(['T7']);
});
