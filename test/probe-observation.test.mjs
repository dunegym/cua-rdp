import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyParentObservation } from './probe-observation.mjs';

const observation = { sessionId: 1, inputDesktop: 'Default', foregroundWindow: '100', cursor: { x: 0, y: 0 }, clipboardSequence: 1 };

test('interactive failure before a background baseline reports not-established, not changed', () => {
  const after = { ...observation, foregroundWindow: '200' };
  const report = verifyParentObservation(observation, undefined, after);
  assert.equal(report.sessionAndInputDesktopUnchanged, true);
  assert.equal(report.backgroundObservation, 'not-established');
  assert.equal(report.unchanged, undefined);
});

test('a background baseline must match focus, cursor and clipboard as well as session', () => {
  assert.equal(verifyParentObservation(observation, observation, observation).backgroundObservation, 'unchanged');
  for (const change of [{ foregroundWindow: '200' }, { cursor: { x: 1, y: 0 } }, { clipboardSequence: 2 }]) {
    assert.throws(() => verifyParentObservation(observation, observation, { ...observation, ...change }));
  }
});

test('session and input desktop are checked even without a background baseline', () => {
  for (const change of [{ sessionId: 2 }, { inputDesktop: 'Winlogon' }]) {
    assert.throws(() => verifyParentObservation(observation, undefined, { ...observation, ...change }));
  }
});
