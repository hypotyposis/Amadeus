const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

test('the native wallpaper can use the existing animation graph without a browser', () => {
  const context = vm.createContext({ console, setTimeout, clearTimeout });
  const source = fs.readFileSync(path.join(__dirname, '../render/web/renderer.js'), 'utf8');
  vm.runInContext(source, context);
  const acted = [];
  const runtime = new context.SpriteForgeRuntime({
    clearHold() {}, setSpeaking() {}, setEmotion(label) { acted.push(label); },
  });
  runtime.loadGraph({
    rootNodeId: 'root', graph: {
      nodes: [{ id: 'root', label: 'idle' }, { id: 'smile', label: 'smile' }],
      edges: [{ from: 'root', to: 'smile', prob: 0 }, { from: 'smile', to: 'root', prob: 1 }],
    },
  });
  runtime.trigger('smile');
  runtime.onCycleComplete('smile');
  assert.deepEqual(acted, ['idle', 'smile', 'idle']);
});
