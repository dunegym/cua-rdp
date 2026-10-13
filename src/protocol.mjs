export function unwrapGuest(value) {
  if (value && typeof value.json === 'string') value = JSON.parse(value.json);
  if (!value || typeof value !== 'object') throw new Error('Invalid desktop-agent response');
  if (value.error) throw Object.assign(new Error(value.error.message || 'Desktop agent rejected the request'), { code: value.error.code });
  if (!Object.hasOwn(value, 'result')) throw new Error('Desktop-agent response is missing its result');
  return value.result;
}

export function assertIdentity(identity, expected) {
  if (!identity || identity.runId !== expected.runId ||
      String(identity.machineGuid).toLowerCase() !== expected.machineGuid.toLowerCase() ||
      identity.sessionId !== expected.sessionId || identity.sessionId <= 0 || identity.userSid !== expected.userSid ||
      (expected.logonTime !== undefined && identity.logonTime !== expected.logonTime)) {
    throw new Error('Desktop-agent identity/session mismatch; refusing desktop access');
  }
}
