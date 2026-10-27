// Tests server/scheduler/technicianReminderScheduler.js — which alert is due
// for an assigned technician who hasn't started the journey, the message
// text, and that each alert is claimed once and only sent while still
// 'assigned'.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: { send: jest.fn().mockResolvedValue('ok') } }));
jest.mock('../../utils/dbLogger', () => ({ logTechnicianEvent: jest.fn() }));

const db = require('../../config/db');
const { messaging } = require('../../config/firebase');
const { decideAlert, buildMessage, timeLabel, _tick } = require('../../scheduler/technicianReminderScheduler');

const cfg = { enabled: true, before: 60, skipWithin: 10, late: [5, 10] };
const row = (over = {}) => ({
  booking_id: 900, technician_id: 17, mins_to_appt: 60, mins_since_assigned: 120,
  reminder_sent_at: null, late_alert_1_sent_at: null, late_alert_2_sent_at: null,
  appt_time: '10:30:00', patient_name: 'Vishwa', city: 'Gandhipuram', ...over,
});

describe('decideAlert', () => {
  test('reminder at 60 minutes before', () => {
    expect(decideAlert(row({ mins_to_appt: 60 }), cfg)).toEqual({ kind: 'reminder', column: 'reminder_sent_at' });
  });

  test('nothing more than 60 minutes before', () => {
    expect(decideAlert(row({ mins_to_appt: 61 }), cfg)).toBeNull();
  });

  test('reminder skipped (but marked) when accepted in the last 10 minutes', () => {
    expect(decideAlert(row({ mins_to_appt: 59, mins_since_assigned: 1 }), cfg))
      .toEqual({ kind: 'reminder_skipped', column: 'reminder_sent_at' });
  });

  test('reminder is not repeated', () => {
    expect(decideAlert(row({ mins_to_appt: 30, reminder_sent_at: '2026-10-26 09:30' }), cfg)).toBeNull();
  });

  test('no late alert before 5 minutes past the time', () => {
    expect(decideAlert(row({ mins_to_appt: 0 }), cfg)).toBeNull();
    expect(decideAlert(row({ mins_to_appt: -4 }), cfg)).toBeNull();
  });

  test('first late alert at +5 minutes', () => {
    expect(decideAlert(row({ mins_to_appt: -5 }), cfg))
      .toEqual({ kind: 'late1', column: 'late_alert_1_sent_at', lateBy: 5 });
  });

  test('second late alert at +10 minutes', () => {
    expect(decideAlert(row({ mins_to_appt: -10, late_alert_1_sent_at: 'x' }), cfg))
      .toEqual({ kind: 'late2', column: 'late_alert_2_sent_at', alsoMark: 'late_alert_1_sent_at', lateBy: 10 });
  });

  test('first late alert is not repeated between +5 and +10', () => {
    expect(decideAlert(row({ mins_to_appt: -7, late_alert_1_sent_at: 'x' }), cfg)).toBeNull();
  });

  test('nothing after both late alerts, or long after the time', () => {
    expect(decideAlert(row({ mins_to_appt: -15, late_alert_1_sent_at: 'x', late_alert_2_sent_at: 'x' }), cfg)).toBeNull();
    expect(decideAlert(row({ mins_to_appt: -90 }), cfg)).toBeNull();
  });
});

describe('messages', () => {
  test('time label in 12-hour format', () => {
    expect(timeLabel('10:30:00')).toBe('10:30 AM');
    expect(timeLabel('14:05:00')).toBe('2:05 PM');
    expect(timeLabel('00:15:00')).toBe('12:15 AM');
  });

  test('reminder and late alert text', () => {
    expect(buildMessage({ kind: 'reminder' }, row({ mins_to_appt: 60 }))).toEqual({
      type: 'booking_reminder',
      title: 'Upcoming booking in 60 min ⏰',
      body: '10:30 AM · Vishwa · Gandhipuram. Start your journey on time.',
    });
    expect(buildMessage({ kind: 'late1', lateBy: 5 }, row()).title).toBe("You're 5 minutes late ⚠️");
    expect(buildMessage({ kind: 'late2', lateBy: 10 }, row()).body).toMatch(/customer is waiting/);
  });
});

describe('tick', () => {
  beforeEach(() => {
    db.execute.mockReset();
    messaging.send.mockClear();
  });

  test('claims the alert, then pushes to the technician', async () => {
    db.execute
      .mockResolvedValueOnce([[row({ mins_to_appt: -5 })]])                 // due rows
      .mockResolvedValueOnce([{ affectedRows: 1 }])                         // claim
      .mockResolvedValueOnce([[{ user_notification_token: 'tok' }]]);       // token
    await _tick();
    const [claimSql, claimParams] = db.execute.mock.calls[1];
    expect(claimSql).toMatch(/SET late_alert_1_sent_at = NOW\(\)/);
    expect(claimSql).toMatch(/late_alert_1_sent_at IS NULL AND collection_status = 'assigned'/);
    expect(claimParams).toEqual([900]);
    expect(messaging.send).toHaveBeenCalledWith(expect.objectContaining({
      token: 'tok',
      data: { type: 'booking_late_alert', booking_id: '900' },
      android: expect.objectContaining({ notification: { channelId: 'booking_updates' } }),
    }));
  });

  test('does not push when the claim fails (already sent, or journey started meanwhile)', async () => {
    db.execute
      .mockResolvedValueOnce([[row({ mins_to_appt: -5 })]])
      .mockResolvedValueOnce([{ affectedRows: 0 }]);
    await _tick();
    expect(messaging.send).not.toHaveBeenCalled();
  });

  test('a skipped reminder is marked but not pushed', async () => {
    db.execute
      .mockResolvedValueOnce([[row({ mins_to_appt: 55, mins_since_assigned: 2 })]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);
    await _tick();
    expect(db.execute.mock.calls[1][0]).toMatch(/SET reminder_sent_at = NOW\(\)/);
    expect(messaging.send).not.toHaveBeenCalled();
  });

  test('only bookings whose journey has not started are selected', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    await _tick();
    expect(db.execute.mock.calls[0][0]).toMatch(/tc\.collection_status = 'assigned'/);
  });
});
