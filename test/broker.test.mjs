import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { EventEmitter } from 'node:events';
import { Broker } from '../src/broker.mjs';

function fixture() {
  const child = new EventEmitter();
  child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = () => { child.emit('exit', 1); return true; };
  const broker = new Broker('unused', { spawnProcess: () => child });
  return { child, broker };
}

test('broker serializes requests, handles chunked UTF-8 NDJSON and propagates errors', async () => {
  const { child, broker } = fixture();
  const requests = [];
  child.stdin.on('data', data => {
    const request = JSON.parse(data.toString()); requests.push(request);
    const response = request.method === 'second' ? { id: request.id, error: { message: 'guest rejected' } } : { id: request.id, result: { text: '中文' } };
    const encoded = Buffer.from(JSON.stringify(response) + '\n');
    child.stdout.write(encoded.subarray(0, encoded.length - 4));
    child.stdout.write(encoded.subarray(encoded.length - 4));
  });
  const one = broker.request('first');
  const two = broker.request('second');
  assert.deepEqual(await one, { text: '中文' });
  await assert.rejects(two, /guest rejected/);
  assert.deepEqual(requests.map(r => r.method), ['first', 'second']);
  child.emit('exit', 0);
  await broker.close();
});

test('broker transport failure rejects every pending operation and never retries', async () => {
  const { child, broker } = fixture();
  let count = 0;
  child.stdin.on('data', () => { count++; child.stdout.write('not-json\n'); });
  await assert.rejects(broker.request('callTool'), /invalid JSON/);
  await assert.rejects(broker.request('callTool'), /closed/);
  assert.equal(count, 1);
});

test('broker timeout makes outcome unknown and closes transport', async () => {
  const { broker } = fixture();
  await assert.rejects(broker.request('callTool', {}, 10), /outcome is unknown/);
  await assert.rejects(broker.request('callTool'), /closed/);
});
