// Tests services/technicianBranches.js — the branches shown on a technician's
// profile, which must match who dispatch offers a booking to.
jest.mock('../../config/db');
const db = require('../../config/db');
const { getTechnicianBranches, technicianIdsAtBranch, clearTechnicianBranchCache } = require('../../services/technicianBranches');

const branch = (id, code) => ({
  branch_id: id, branch_name: `Branch ${id}`, branch_city: 'Erode', branch_address: '12 MG Road',
  branch_pincode: '638001', branch_code: code,
});
const ALL = [branch(1, '03'), branch(2, '04'), branch(3, '07'), branch(4, null)];

function wire(tech) {
  db.execute.mockReset().mockImplementation(async (sql) => (
    /FROM ip_technicians/.test(sql) ? [tech ? [tech] : []] : [ALL]
  ));
}
const ids = (list) => list.map(b => b.branchId);

test('every matched branch is listed, with the default first', async () => {
  wire({ branch_id: 3, default_branch_id: '07', branch_ids: '["03","04","07"]' });
  const list = await getTechnicianBranches(17);
  expect(ids(list)).toEqual([3, 1, 2]);
  expect(list.map(b => b.isDefault)).toEqual([true, false, false]);
  expect(list[0]).toEqual({
    branchId: 3, name: 'Branch 3', location: 'Erode', address: '12 MG Road', pincode: '638001', isDefault: true,
  });
});

test('codes match regardless of leading zeros', async () => {
  wire({ branch_id: null, default_branch_id: '7', branch_ids: '["3"]' });
  expect(ids(await getTechnicianBranches(17))).toEqual([3, 1]);
});

test('a JSON column that is already parsed works too', async () => {
  wire({ branch_id: null, default_branch_id: null, branch_ids: ['04'] });
  expect(ids(await getTechnicianBranches(17))).toEqual([2]);
});

test('a technician with only their own branch still sees it, as the default', async () => {
  wire({ branch_id: 4, default_branch_id: null, branch_ids: null });
  const list = await getTechnicianBranches(17);
  expect(ids(list)).toEqual([4]);
  expect(list[0].isDefault).toBe(true);
});

test('their own branch is listed even when it is not in their codes', async () => {
  wire({ branch_id: 4, default_branch_id: '07', branch_ids: '["07"]' });
  expect(ids(await getTechnicianBranches(17))).toEqual([3, 4]);
});

test('a code that matches no branch is left out', async () => {
  wire({ branch_id: null, default_branch_id: null, branch_ids: '["99","04"]' });
  expect(ids(await getTechnicianBranches(17))).toEqual([2]);
});

test('bad data in branch_ids does not break the profile', async () => {
  wire({ branch_id: 1, default_branch_id: null, branch_ids: 'not json' });
  expect(ids(await getTechnicianBranches(17))).toEqual([1]);
});

test('no technician gives an empty list', async () => {
  wire(null);
  expect(await getTechnicianBranches(17)).toEqual([]);
});

// ── technicianIdsAtBranch: whose slots count for a branch ─────────────────────
describe('technicianIdsAtBranch', () => {
  // Branch 2..5 with codes 02..05, branch 9 without a code.
  const BRANCHES = [2, 3, 4, 5].map(id => ({ branch_id: id, branch_code: `0${id}` })).concat({ branch_id: 9, branch_code: null });

  function wireTechs(techs) {
    clearTechnicianBranchCache();
    db.execute.mockReset().mockImplementation(async (sql) => (
      /FROM ip_technicians/.test(sql) ? [techs] : [BRANCHES]
    ));
  }

  test('default branch 2 plus branches 3, 4, 5: the technician counts at all four', async () => {
    wireTechs([{ technician_id: 6, branch_id: 2, default_branch_id: '02', branch_ids: '["03","04","05"]' }]);
    for (const b of [2, 3, 4, 5]) expect(await technicianIdsAtBranch(b)).toEqual([6]);
    expect(await technicianIdsAtBranch(9)).toEqual([]);
  });

  test('codes match regardless of leading zeros, and an unmatched code is ignored', async () => {
    wireTechs([{ technician_id: 7, branch_id: 9, default_branch_id: '3', branch_ids: ['4', '99'] }]);
    expect(await technicianIdsAtBranch(3)).toEqual([7]);
    expect(await technicianIdsAtBranch(4)).toEqual([7]);
    expect(await technicianIdsAtBranch(9)).toEqual([7]); // own branch, even without a code
  });

  test('several technicians at one branch, each listed once', async () => {
    wireTechs([
      { technician_id: 1, branch_id: 3, default_branch_id: '03', branch_ids: '["03"]' },
      { technician_id: 2, branch_id: 2, default_branch_id: '02', branch_ids: '["03"]' },
      { technician_id: 3, branch_id: 5, default_branch_id: null, branch_ids: 'not json' },
    ]);
    expect((await technicianIdsAtBranch(3)).sort()).toEqual([1, 2]);
    expect(await technicianIdsAtBranch(5)).toEqual([3]);
  });

  test('the list is read once and reused until cleared', async () => {
    wireTechs([{ technician_id: 6, branch_id: 2, default_branch_id: '02', branch_ids: null }]);
    await technicianIdsAtBranch(2);
    await technicianIdsAtBranch(3);
    expect(db.execute.mock.calls.filter(c => /FROM ip_technicians/.test(c[0]))).toHaveLength(1);
  });

  test('no branch given: nobody', async () => {
    wireTechs([{ technician_id: 6, branch_id: 2, default_branch_id: '02', branch_ids: null }]);
    expect(await technicianIdsAtBranch(undefined)).toEqual([]);
  });
});
