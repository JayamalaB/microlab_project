// Integration test for services/clientSync.js: syncVisitCompletionToClient
// — the "consolidated Jayamala visit_completed request" from the task brief.
//
// Unlike the controller tests, this file does NOT mock clientSync itself —
// the whole point here is to prove the actual JSON payload it builds and
// posts contains package (blood_test_list), payment (payment_details),
// family booking (multiple bookings[] entries sharing one visit_group_id),
// collection photo (proof_photo), and patient/booking identification.
//
// The only things mocked are the two real I/O boundaries: the DB (config/db)
// and the outbound HTTP call itself (Node's core http module, since
// postJson — clientSync.js's internal, non-exported request function — uses
// http.request directly, not fetch). This is exactly the network-mocking
// helper (mockHttpRequest) built earlier in this test suite for this
// purpose but not yet used until now.
jest.mock('../../config/db');
jest.mock('../../config/settings');
const db       = require('../../config/db');
const settings = require('../../config/settings');
const http     = require('http');
const { syncVisitCompletionToClient } = require('../../services/clientSync');

// IMPORTANT: unlike a user module (which Jest sandboxes per test FILE), core
// Node modules like 'http' are the one real, process-wide singleton — every
// test file in the same worker process shares the exact same object. That
// means overwriting http.request here, if left in place, silently breaks
// (or hangs) whatever other suite happens to run afterward in the same
// worker — which is exactly what happened the first time this file was
// added: the full `npx jest` run hung indefinitely. The fix is to always
// restore the original after each test, not just mock it.
const realHttpRequest = http.request;
afterEach(() => {
  http.request = realHttpRequest;
});

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  settings.getBool.mockReset().mockReturnValue(true); // client_sync_enabled + visit_completion_sync_enabled both default on
  settings.get.mockReset().mockReturnValue('10000');  // client_sync_timeout_ms
});

// Wires http.request to respond with `jsonBody` and returns a way to read
// back exactly what was POSTed — the real assertion surface for this file.
function mockHttpAndCapture(jsonBody, statusCode = 200) {
  const reqHandle = { write: jest.fn(), end: jest.fn(), on: jest.fn(), setTimeout: jest.fn(), destroy: jest.fn() };
  http.request = jest.fn((options, callback) => {
    const res = {
      statusCode,
      on: (event, handler) => {
        if (event === 'data') handler(Buffer.from(JSON.stringify(jsonBody)));
        if (event === 'end') handler();
      },
    };
    queueMicrotask(() => callback(res));
    return reqHandle;
  });
  return () => JSON.parse(reqHandle.write.mock.calls[0][0]);
}

describe('syncVisitCompletionToClient — outbound payload content', () => {
  // Safety/negative case: the feature flag being off must mean NO network
  // call is even attempted — proves the kill-switch actually works.
  test('does not call out to Jayamala when client_sync_enabled is false', async () => {
    settings.getBool.mockImplementation((key) => key !== 'client_sync_enabled');
    const getPayload = mockHttpAndCapture({ status: 'success' });

    await syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

    expect(http.request).not.toHaveBeenCalled();
  });

  // Negative case: a booking_id that doesn't resolve to a real row must
  // bail out before ever reaching the network.
  test('skips silently when the primary booking cannot be found', async () => {
    db.execute.mockResolvedValueOnce([[]]); // primaryBooking lookup — nothing
    mockHttpAndCapture({ status: 'success' });

    await syncVisitCompletionToClient(999999, { mobile: '9000000001', type: 'technician', technicianId: 17 });

    expect(http.request).not.toHaveBeenCalled();
  });

  // TC-SYNC-01 — the core content check for a single (non-family) booking:
  // package, payment, and collection-photo data must all be present in the
  // one bookings[] entry actually posted.
  test('a standalone booking payload carries its package, payment, and collection photo', async () => {
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, booking_ref: 'BK900', patient_id: 501, status: 'completed', bill_id: null, visit_group_id: null }]]) // primaryBooking
      .mockResolvedValueOnce([[{ booking_id: 900, booking_ref: 'BK900', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 878, patient_id: 501, client_id: 10, status: 'completed', bill_id: null, visit_group_id: null, slot_time: '10:00 AM' }]]) // single-booking branch → [[b]]
      .mockResolvedValueOnce([{}])                                       // UPDATE client_sync_status='pending'
      // _fetchPatientTestsPayment(booking 900):
      .mockResolvedValueOnce([[{                                         // patient — already synced before (has patient_id_ref)
        patient_id: 501, patient_id_ref: 'JAYA501', patient_name: 'Ravi Kumar', patient_mobile: '9876543210',
        patient_gender: 'M', patient_city: 'Chennai', patient_address: '12 MG Road', patient_email: null,
        patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null,
      }]])
      .mockResolvedValueOnce([[{                                         // tests (the "package" data)
        booking_item_id: 1, product_id: 7, name: 'Complete Blood Count', price: 878,
        document_required: 0, prescription_url: null,
      }]])
      .mockResolvedValueOnce([[{ payment_type: 'RAZORPAY', amount_paid: 878, amount_due: 0, gateway_transaction_id: 'pay_test123' }]]) // payment
      .mockResolvedValueOnce([[{ file_path: '/uploads/collection/900_proof.jpg' }]])  // collection-proof photo
      // technician name lookup (initiator.technicianId set)
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
      // post-send success bookkeeping
      .mockResolvedValueOnce([{}])                                       // UPDATE client_sync_status='synced'
      .mockResolvedValueOnce([{}]);                                      // UPDATE bill_id (result.bill_id below)

    const getPayload = mockHttpAndCapture({ status: 'success', bill_id: 55555 });

    await syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

    expect(http.request).toHaveBeenCalledTimes(1);
    const payload = getPayload();

    expect(payload.action).toBe('visit_completed');
    expect(payload.booking_ref).toBe('BK900');
    expect(payload.technician_details).toEqual({ technician_id: 17, name: 'Tech Suresh' });
    expect(payload.bookings).toHaveLength(1);

    const entry = payload.bookings[0];
    // Package data
    expect(entry.blood_test_list).toEqual([
      { id: 7, name: 'Complete Blood Count', price: 878, document_required: 'no', document: 'no' },
    ]);
    // Payment data
    expect(entry.payment_details).toEqual({
      total_amount: 878, paid_amount: 878, payment_type: 'full payment', razorpay_payment_id: 'pay_test123',
    });
    // Collection photo
    expect(entry.proof_photo).toBe('/uploads/collection/900_proof.jpg');
    // Patient identification — an already-linked patient is sent by reference id, not full details.
    expect(entry.patient_id).toBe('JAYA501');
    expect(entry.patient_details).toBeUndefined();

    // bill_id returned by Jayamala gets saved back to the primary booking.
    expect(db.execute).toHaveBeenCalledWith(
      expect.stringContaining('UPDATE ip_bookings SET bill_id'),
      ['55555', 900]
    );
  });

  // TC-SYNC-02 — family booking: verifying OTP on one sibling produces ONE
  // consolidated request whose bookings[] contains every member of the
  // visit_group, each carrying their own package/payment independently.
  test('a family visit payload contains one bookings[] entry per member, all sharing visit_group_id', async () => {
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, booking_ref: 'BK900', patient_id: 501, status: 'completed', bill_id: null, visit_group_id: 'VG123' }]]) // primaryBooking
      .mockResolvedValueOnce([[                                          // bookingRows — visit_group_id branch, 2 siblings
        { booking_id: 900, booking_ref: 'BK900', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 500, patient_id: 501, client_id: 10, status: 'completed', bill_id: null, visit_group_id: 'VG123', slot_time: '10:00 AM' },
        { booking_id: 901, booking_ref: 'BK901', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 300, patient_id: 502, client_id: 10, status: 'completed', bill_id: null, visit_group_id: 'VG123', slot_time: '10:00 AM' },
      ]])
      .mockResolvedValueOnce([{}])                                       // UPDATE client_sync_status='pending' (both ids)
      // _fetchPatientTestsPayment(booking 900, member 1 — self)
      .mockResolvedValueOnce([[{
        patient_id: 501, patient_id_ref: 'JAYA501', patient_name: 'Ravi Kumar', patient_mobile: '9876543210',
        patient_gender: 'M', patient_city: 'Chennai', patient_address: '12 MG Road', patient_email: null,
        patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null,
      }]])
      .mockResolvedValueOnce([[{ booking_item_id: 1, product_id: 7, name: 'CBC', price: 500, document_required: 0, prescription_url: null }]])
      .mockResolvedValueOnce([[{ payment_type: 'PAY_LATER', amount_paid: 0, amount_due: 500, gateway_transaction_id: null }]])
      .mockResolvedValueOnce([[]])                                       // no collection photo for this member
      // _fetchPatientTestsPayment(booking 901, member 2 — spouse, brand-new patient never synced before)
      .mockResolvedValueOnce([[{
        patient_id: 502, patient_id_ref: null, patient_name: 'Meena Kumar', patient_mobile: '9876543211',
        patient_gender: 'F', patient_city: 'Chennai', patient_address: '12 MG Road', patient_email: null,
        patient_dob: '1992-05-05', patient_age: 34, patient_relation: 'Spouse', health_conditions: null, patient_photo: null,
      }]])
      .mockResolvedValueOnce([[{ booking_item_id: 2, product_id: 9, name: 'Lipid Profile', price: 300, document_required: 0, prescription_url: null }]])
      .mockResolvedValueOnce([[{ payment_type: 'PAY_LATER', amount_paid: 0, amount_due: 300, gateway_transaction_id: null }]])
      .mockResolvedValueOnce([[]])                                       // no collection photo for member 2 either
      // technician name lookup
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
      // post-send success bookkeeping — no bill_id / patient_id in this response
      .mockResolvedValueOnce([{}]);                                      // UPDATE client_sync_status='synced'

    const capture = mockHttpAndCapture({ status: 'success' });
    await syncVisitCompletionToClient(900, { mobile: '9000000001', type: 'technician', technicianId: 17 });

    const payload = capture();
    expect(payload.visit_group_id).toBe('VG123');
    expect(payload.bookings).toHaveLength(2);

    const [self, spouse] = payload.bookings;
    expect(self.booking_ref).toBe('BK900');
    expect(self.patient_id).toBe('JAYA501');            // already-linked patient → sent by reference
    expect(self.blood_test_list[0].name).toBe('CBC');

    expect(spouse.booking_ref).toBe('BK901');
    expect(spouse.patient_details).toBeDefined();        // brand-new patient → full details sent instead of an id
    expect(spouse.patient_details.name).toBe('Meena Kumar');
    expect(spouse.blood_test_list[0].name).toBe('Lipid Profile');
    expect(spouse.payment_details.total_amount).toBe(300);
  });
});
