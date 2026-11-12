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

// ── Which technicians work at a branch ───────────────────────────────────────
// Same rule as dispatch: a technician works at their own branch
// (ip_technicians.branch_id) and at every branch whose code matches their
// default code or one of their ASMX codes (branch_ids). A technician's slots
// are stored once, under their own branch, but count for every branch they
// work at — the customer slot list, branch lookup and slot fallback all ask
// this instead of reading ip_technician_slots.branch_id.
//
// Rebuilt at most once a minute: it changes only when a technician logs in.
const CACHE_MS = 60 * 1000;
let cache = null; // { at, byBranch: Map<branchId, number[]>, names: Map<technicianId, string> }

async function _loadTechniciansByBranch() {
  const [techs] = await db.execute(
    `SELECT t.technician_id, t.branch_id, t.branch_ids, t.default_branch_id, u.user_name
     FROM ip_technicians t
     LEFT JOIN ip_users u ON u.user_id = t.user_id`
  );
  const [branches] = await db.execute(
    'SELECT branch_id, branch_code FROM ip_branches WHERE deleted_at IS NULL'
  );
  const byCode = new Map();
  for (const b of branches) {
    const key = branchCodeKey(b.branch_code);
    if (key != null && !byCode.has(key)) byCode.set(key, Number(b.branch_id));
  }

  const sets  = new Map();
  const names = new Map();
  const add = (branchId, technicianId) => {
    if (branchId == null || !Number.isInteger(branchId)) return;
    if (!sets.has(branchId)) sets.set(branchId, new Set());
    sets.get(branchId).add(technicianId);
  };
  for (const t of techs ?? []) {
    const technicianId = Number(t.technician_id);
    if (t.user_name) names.set(technicianId, t.user_name);
    if (t.branch_id != null && t.branch_id !== '') add(Number(t.branch_id), technicianId);
    let codes = t.branch_ids;
    if (typeof codes === 'string') {
      try { codes = JSON.parse(codes); } catch { codes = []; }
    }
    codes = Array.isArray(codes) ? codes : [];
    for (const code of [t.default_branch_id, ...codes]) add(byCode.get(branchCodeKey(code)), technicianId);
  }

  const byBranch = new Map();
  for (const [branchId, ids] of sets) byBranch.set(branchId, [...ids]);
  return { byBranch, names };
}

async function _cached() {
  if (!cache || Date.now() - cache.at > CACHE_MS) {
    cache = { at: Date.now(), ...(await _loadTechniciansByBranch()) };
  }
  return cache;
}

// technician_ids of everyone who works at branchId ([] when nobody does).
async function technicianIdsAtBranch(branchId) {
  return (await _cached()).byBranch.get(Number(branchId)) ?? [];
}

// "Elumalai P (13), Nirosh (6)" for logs — "none" when the list is empty.
// Never throws: it only feeds log lines.
async function describeTechnicians(ids) {
  if (!ids || ids.length === 0) return 'none';
  try {
    const { names } = await _cached();
    return ids.map(id => `${names.get(Number(id)) ?? 'Technician'} (${id})`).join(', ');
  } catch (_) {
    return ids.join(', ');
  }
}

// Forgets the cached list — for tests, and after a change that must show at once.
function clearTechnicianBranchCache() {
  cache = null;
}

// "?, ?, ?" for an IN (…) list of the given ids.
const placeholders = (ids) => ids.map(() => '?').join(', ');

module.exports = {
  getTechnicianBranches, technicianIdsAtBranch, describeTechnicians, clearTechnicianBranchCache, placeholders,
};
