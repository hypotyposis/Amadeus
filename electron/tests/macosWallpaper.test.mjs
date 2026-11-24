import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { PassThrough } from 'node:stream';
import { EventEmitter } from 'node:events';
import { startNativeWallpaper } from '../src/main/macosWallpaper.ts';

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.stdin = new PassThrough();
  child.kill = () => { child.emit('exit', null, 'SIGTERM'); };
  return child;
}

test('native wallpaper waits for a complete readiness line', async () => {
  const child = fakeChild();
  const session = startNativeWallpaper(child, () => assert.fail('explicit stop must not recover'));
  let settled = false;
  void session.ready.then(() => { settled = true; });
  child.stdout.write('rea');
  await Promise.resolve();
  assert.equal(settled, false);
  child.stdout.write('dy\n');
  assert.equal(await session.ready, true);
  session.stop();
});

test('failure before readiness is reported to the opener', async () => {
  const child = fakeChild();
  const session = startNativeWallpaper(child, () => assert.fail('initial failure is owned by the opener'));
  child.emit('exit', 1, null);
  assert.equal(await session.ready, false);
});

test('unexpected exit after readiness notifies the owner', async () => {
  const child = fakeChild();
  const events = new EventEmitter();
  const session = startNativeWallpaper(child, () => events.emit('recover'));
  child.stdout.write('ready\n');
  assert.equal(await session.ready, true);
  const recover = once(events, 'recover');
  child.emit('exit', 1, null);
  await recover;
});
