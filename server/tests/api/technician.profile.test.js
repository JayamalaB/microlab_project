// Technician Profile: edit name/email, own photo, and Today's Summary counts.
jest.mock('../../config/db');
jest.mock('../../socket/bookingSocket', () => ({
  forceTechnicianOffline: jest.fn(), unassignAndRedispatch: jest.fn(),
}));
jest.mock('../../services/technicianBranches', () => ({ getTechnicianBranches: jest.fn().mockResolvedValue([]) }));
jest.mock('../../utils/sms');
jest.mock('../../utils/dbLogger');

const db = require('../../config/db');
const technicianController = require('../../controllers/technicianController');

const mockRes = () => ({ json: jest.fn(), status: jest.fn().mockReturnThis() });
const techReq = (body = {}, extra = {}) => ({ body, user: { id: 7, mobile: '9000000002' }, ...extra });

beforeEach(() => {
  jest.clearAllMocks();
  db.execute.mockReset().mockResolvedValue([[], {}]);
});

describe('updateProfile', () => {
  test('saves name and email to ip_users for this technician', async () => {
    db.execute.mockResolvedValueOnce([{ affectedRows: 1 }]);
    const res = mockRes();
    await technicianController.updateProfile(techReq({ name: '  Nirosh   Kumar ', email: 'nk@example.com' }), res);

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toMatch(/UPDATE ip_users u\s+JOIN ip_technicians t/);
    expect(params).toEqual(['Nirosh Kumar', 'nk@example.com', 7]);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
  });

  test('an empty email is saved as NULL', async () => {
    db.execute.mockResolvedValueOnce([{ affectedRows: 1 }]);
    await technicianController.updateProfile(techReq({ name: 'Nirosh', email: '' }), mockRes());
    expect(db.execute.mock.calls[0][1]).toEqual(['Nirosh', null, 7]);
  });

  test.each([
    ['', 'x@y.com'],
    ['N', 'x@y.com'],
    ['Nirosh123', 'x@y.com'],
    ['Nirosh', 'not-an-email'],
  ])('rejects name=%p email=%p', async (name, email) => {
    const res = mockRes();
    await technicianController.updateProfile(techReq({ name, email }), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(db.execute).not.toHaveBeenCalled();
  });
});

describe('profile photo', () => {
  test('upload saves the full URL on ip_technicians', async () => {
    db.execute
      .mockResolvedValueOnce([[{ tech_photo: null }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);
    const res = mockRes();
    await technicianController.uploadProfilePhoto(
      techReq({}, { file: { filename: 'technician_7_1700000000000_abc123.jpg' } }), res);

    const [sql, params] = db.execute.mock.calls[1];
    expect(sql).toMatch(/UPDATE ip_technicians SET tech_photo = \?/);
    expect(params[0]).toMatch(/\/uploads\/technician_7_1700000000000_abc123\.jpg$/);
    expect(params[1]).toBe(7);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
  });

  test('upload without a file is refused', async () => {
    const res = mockRes();
    await technicianController.uploadProfilePhoto(techReq(), res);
    expect(res.status).toHaveBeenCalledWith(422);
  });

  test('remove clears the photo', async () => {
    db.execute.mockResolvedValueOnce([[{ tech_photo: 'https://x/registry.jpg' }]]);
    const res = mockRes();
    await technicianController.removeProfilePhoto(techReq(), res);
    expect(db.execute.mock.calls[1][0]).toMatch(/SET tech_photo = NULL/);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true, tech_photo: null }));
  });
});

describe("getProfile Today's Summary", () => {
  test('counts per booking like History, leaves out cancelled, Completed = handed to lab or later', async () => {
    db.execute
      .mockResolvedValueOnce([[{ user_name: 'Nirosh', technician_id: 7 }]])
      .mockResolvedValueOnce([[{ assigned_today: 2, completed_today: 1, pending_today: 1, total_done: 9 }]]);
    const res = mockRes();
    await technicianController.getProfile({ params: { technicianId: '7' } }, res);

    const [sql, params] = db.execute.mock.calls[1];
    expect(sql).not.toContain('visit_group_id');
    expect(sql).toContain("'handed_to_lab_pending'");
    expect(sql).not.toContain("'sample_collected'");
    expect(sql).not.toContain("'collection_started'");
    expect(sql).toContain("<> 'cancelled'");
    expect(sql).toContain('BETWEEN ? AND ?');
    expect(params[2]).toBe(params[3]); // no period → today only
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: true,
      stats: expect.objectContaining({
        assigned_today: 2, completed_today: 1, pending_today: 1, total_done: 9,
        rescheduled: 0, period: 'today',
      }),
    }));
  });

  test('period filter uses its date range and counts reschedules', async () => {
    db.execute
      .mockResolvedValueOnce([[{ user_name: 'Nirosh', technician_id: 7 }]])
      .mockResolvedValueOnce([[{ assigned_today: 5, completed_today: 4, pending_today: 1, total_done: 9 }]])
      .mockResolvedValueOnce([[{ n: 2 }]]);
    const res = mockRes();
    await technicianController.getProfile({ params: { technicianId: '7' }, query: { period: 'last_month' } }, res);

    const { from, to } = technicianController._summaryRange('last_month');
    expect(db.execute.mock.calls[1][1]).toEqual(['7', '7', from, to]);
    // Rescheduled is counted by the appointment date it moved FROM (History's rule).
    expect(db.execute.mock.calls[2][0]).toContain('ip_booking_reschedules');
    expect(db.execute.mock.calls[2][0]).toContain('r.old_date BETWEEN');
    expect(db.execute.mock.calls[2][1]).toEqual(['7', from, to]);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      stats: expect.objectContaining({ rescheduled: 2, period: 'last_month', from, to }),
    }));
  });

  test('without the reschedule table the count is 0, not an error', async () => {
    db.execute
      .mockResolvedValueOnce([[{ user_name: 'Nirosh', technician_id: 7 }]])
      .mockResolvedValueOnce([[{ assigned_today: 0, completed_today: 0, pending_today: 0, total_done: 0 }]])
      .mockRejectedValueOnce(Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' }));
    const res = mockRes();
    await technicianController.getProfile({ params: { technicianId: '7' }, query: { period: 'this_week' } }, res);
    expect(res.status).not.toHaveBeenCalled();
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      stats: expect.objectContaining({ rescheduled: 0 }),
    }));
  });
});

describe('summary date ranges (IST, weeks Mon–Sun)', () => {
  // Wed 18 Nov 2026, 10:00 IST
  const now = new Date('2026-11-18T04:30:00Z');
  test.each([
    ['all',        '2000-01-01', '2999-12-31'],
    ['today',      '2026-11-18', '2026-11-18'],
    ['this_week',  '2026-11-16', '2026-11-18'],
    ['last_week',  '2026-11-09', '2026-11-15'],
    ['this_month', '2026-11-01', '2026-11-18'],
    ['last_month', '2026-10-01', '2026-10-31'],
    ['bogus',      '2026-11-18', '2026-11-18'],
  ])('%s → %s..%s', (period, from, to) => {
    expect(technicianController._summaryRange(period, now)).toEqual({ from, to });
  });

  test('last month in January is December of last year', () => {
    expect(technicianController._summaryRange('last_month', new Date('2027-01-10T06:00:00Z')))
      .toEqual({ from: '2026-12-01', to: '2026-12-31' });
  });

  test('late evening UTC is already the next day in IST', () => {
    // 20:00 UTC on Sun 22 Nov = 01:30 IST Mon 23 Nov
    expect(technicianController._summaryRange('today', new Date('2026-11-22T20:00:00Z')))
      .toEqual({ from: '2026-11-23', to: '2026-11-23' });
  });
});
