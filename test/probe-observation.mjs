import assert from 'node:assert/strict';

export function verifyParentObservation(before, baseline, after) {
  assert.equal(after.sessionId, before.sessionId, 'Parent Windows session changed');
  assert.equal(after.inputDesktop, before.inputDesktop, 'Parent input desktop changed');
  if (baseline) assert.deepEqual(after, baseline, 'Parent observation changed during background work/stop');
  return {
    sessionAndInputDesktopUnchanged: true,
    backgroundObservation: baseline ? 'unchanged' : 'not-established',
  };
}
