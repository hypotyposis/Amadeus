const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../render/web/wallpaper_scene.js'), 'utf8');
const crt = JSON.parse(fs.readFileSync(path.join(__dirname, '../wallpaper/crt_config.json'), 'utf8'));

function slice(from, to) {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start);
  assert.ok(start >= 0 && end > start, `${from} ... ${to}`);
  return source.slice(start, end);
}

// The scene's own mapping methods, evaluated against a screen of the given size.
function scene(width, height) {
  const code = `${slice('function coverTransform(', 'function callRender(')}
    ({ app: { screen: { width: ${width}, height: ${height} } }, cfg: ${JSON.stringify(crt)},
       ${slice('_imageTransform() {', '_computeBounds(points) {')}
       ${slice('_scaledRect(rect) {', '_buildAmbientFromBackground(url) {')} })`;
  return vm.runInNewContext(code, {});
}

function bounds(points) {
  const xs = points.map((p) => p.x), ys = points.map((p) => p.y);
  return { x: Math.min(...xs), y: Math.min(...ys), width: Math.max(...xs) - Math.min(...xs), height: Math.max(...ys) - Math.min(...ys) };
}

const [imageWidth, imageHeight] = crt.img_size;
const artCrt = bounds(crt.crt_polygon.map(([x, y]) => ({ x, y })));

for (const [width, height] of [[1920, 1080], [1920, 1200], [2560, 1600], [1280, 1024], [2560, 1080]]) {
  test(`${width}x${height}: the art covers the screen at its own aspect and the CRT stays whole`, () => {
    const s = scene(width, height);
    const sprite = {};
    s._placeBackdrop(sprite);
    assert.ok(Math.abs(sprite.width / sprite.height - imageWidth / imageHeight) < 1e-9);
    assert.ok(sprite.x <= 1e-9 && sprite.y <= 1e-9);
    assert.ok(sprite.x + sprite.width >= width - 1e-9 && sprite.y + sprite.height >= height - 1e-9);
    assert.ok(Math.abs(sprite.x + sprite.width / 2 - width / 2) < 1e-9);

    const screenCrt = bounds(s._crtPoints());
    assert.ok(Math.abs(screenCrt.width / screenCrt.height - artCrt.width / artCrt.height) < 1e-9);
    assert.ok(screenCrt.x >= 0 && screenCrt.y >= 0);
    assert.ok(screenCrt.x + screenCrt.width <= width && screenCrt.y + screenCrt.height <= height);

    const corner = crt.crt_polygon[0];
    assert.deepEqual(s._scaledPoint(corner), s._crtPoints()[0]);
    const rect = s._scaledRect([corner[0], corner[1], 10, 10]);
    assert.equal(rect.width, rect.height);
  });
}

test('on a 16:9 screen the art fills it exactly, as before', () => {
  const s = scene(1672 * 2, 941 * 2);
  const sprite = {};
  s._placeBackdrop(sprite);
  assert.deepEqual([sprite.x, sprite.y, sprite.width, sprite.height], [0, 0, 1672 * 2, 941 * 2]);
});

function desktopCanvasRect(screen, bounds) {
  const code = `${slice('function desktopCanvasRect(', 'function createDesktopViewport(')}
    desktopCanvasRect(${JSON.stringify(screen)}, ${JSON.stringify(bounds)})`;
  return vm.runInNewContext(code, {});
}

test('the local canvas covers fractional effect bounds on the desktop pixel grid', () => {
  const rect = desktopCanvasRect({ width: 1920, height: 1080 },
    { x: 631.58, y: 223.64, right: 1304.50, bottom: 754.6 });
  assert.deepEqual({ ...rect }, { x: 631, y: 223, width: 674, height: 532 });
});

test('the local canvas clips at the desktop edge and keeps a valid full view for offscreen content', () => {
  const screen = { width: 800, height: 600 };
  assert.deepEqual({ ...desktopCanvasRect(screen, { x: -10, y: 590.5, right: 230.2, bottom: 700 }) },
    { x: 0, y: 590, width: 231, height: 10 });
  assert.deepEqual({ ...desktopCanvasRect(screen, { x: 900, y: 45, right: 950, bottom: 200 }) },
    { x: 0, y: 0, width: 800, height: 600 });
  assert.deepEqual({ ...desktopCanvasRect(screen, null) }, { x: 0, y: 0, width: 800, height: 600 });
});

test('ambient clipping keeps all visible pixels plus a texel for linear sampling', () => {
  const code = `${slice('function ambientClipPath(', 'function createDesktopViewport(')}
    ({ ambientClipPath })`;
  const { ambientClipPath } = vm.runInNewContext(code, {});
  const width = 8;
  const height = 4;
  const data = new Uint8ClampedArray(width * height * 4);
  assert.equal(ambientClipPath({ width, height, data }), 'inset(50%)');
  data[(2 * width + 4) * 4 + 3] = 1;
  data[(3 * width + 6) * 4 + 3] = 255;
  assert.equal(ambientClipPath({ width, height, data }), 'inset(25% 0% 0% 37.5%)');
});
