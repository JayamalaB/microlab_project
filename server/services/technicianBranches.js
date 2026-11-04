'use strict';
const db = require('../config/db');
const { branchCodeKey } = require('./branchCodes');

// The branches a technician works at, for showing to people. Follows the same
// rule dispatch uses to decide who gets a booking (_isAllowedAtBranch in
// bookingSocket.js): their own branch, plus every ASMX branch code that matches
// a branch. Default branch first; a code that matches nothing is left out.
async function getTechnicianBranches(technicianId) {
  const [[tech]] = await db.execute(
    'SELECT branch_id, branch_ids, default_branch_id FROM ip_technicians WHERE technician_id = ? LIMIT 1',
    [technicianId]
  );
  if (!tech) return [];

  let codes = tech.branch_ids;
  if (typeof codes === 'string') {
    try { codes = JSON.parse(codes); } catch { codes = []; }
  }
  codes = Array.isArray(codes) ? codes : [];

  const [rows] = await db.execute(
    `SELECT branch_id, branch_name, branch_city, branch_address, branch_pincode, branch_code
     FROM ip_branches WHERE deleted_at IS NULL`
  );
  const byCode = new Map();
  const byId   = new Map();
  for (const r of rows) {
    const key = branchCodeKey(r.branch_code);
    if (key != null && !byCode.has(key)) byCode.set(key, r);
    byId.set(Number(r.branch_id), r);
  }

  const defaultBranch = byCode.get(branchCodeKey(tech.default_branch_id)) ?? byId.get(Number(tech.branch_id));
  const found = [defaultBranch, byId.get(Number(tech.branch_id)), ...codes.map(c => byCode.get(branchCodeKey(c)))];

  const unique = new Map();
  for (const b of found) if (b) unique.set(Number(b.branch_id), b);

  return [...unique.values()].map(b => ({
    branchId:  Number(b.branch_id),
    name:      b.branch_name,
    location:  b.branch_city,
    address:   b.branch_address,
    pincode:   b.branch_pincode,
    isDefault: b === defaultBranch,
  }));
}

module.exports = { getTechnicianBranches };
