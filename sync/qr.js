/* Minimal QR code generator (byte mode, error correction level M, versions 1-10).
   Follows ISO/IEC 18004; structure modelled on Nayuki's reference implementation. */
const QR = (() => {
  const TOTAL = [0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346]; // raw codewords per version
  const ECC   = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26];        // EC codewords per block (level M)
  const BLK   = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];                  // number of blocks (level M)
  const ALIGN = [[], [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

  const mul = (x, y) => { let z = 0; for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; } return z; };
  function rsDiv(deg) {
    const r = new Array(deg).fill(0); r[deg - 1] = 1; let root = 1;
    for (let i = 0; i < deg; i++) { for (let j = 0; j < deg; j++) { r[j] = mul(r[j], root); if (j + 1 < deg) r[j] ^= r[j + 1]; } root = mul(root, 2); }
    return r;
  }
  function rsRem(data, div) {
    const r = new Array(div.length).fill(0);
    for (const b of data) { const f = b ^ r.shift(); r.push(0); div.forEach((c, i) => { r[i] ^= mul(c, f); }); }
    return r;
  }
  const fmtBits = mask => { const d = (0 << 3) | mask; let r = d; for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537); return ((d << 10) | r) ^ 0x5412; };
  const verBits = v => { let r = v; for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1F25); return (v << 12) | r; };

  function codewords(text) {
    const bytes = [...new TextEncoder().encode(text)];
    let v = 1;
    for (; v <= 10; v++) { const cap = TOTAL[v] - ECC[v] * BLK[v]; if (4 + (v < 10 ? 8 : 16) + bytes.length * 8 <= cap * 8) break; }
    if (v > 10) throw new Error('Text too long for QR');
    const dataLen = TOTAL[v] - ECC[v] * BLK[v], bits = [];
    const put = (val, n) => { for (let i = n - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
    put(4, 4); put(bytes.length, v < 10 ? 8 : 16); bytes.forEach(b => put(b, 8));
    put(0, Math.min(4, dataLen * 8 - bits.length)); while (bits.length % 8) bits.push(0);
    const data = []; for (let i = 0; i < bits.length; i += 8) data.push(parseInt(bits.slice(i, i + 8).join(''), 2));
    for (let p = 0xEC; data.length < dataLen; p ^= 0xEC ^ 0x11) data.push(p);
    const nb = BLK[v], ecl = ECC[v], raw = TOTAL[v], nShort = nb - raw % nb, shortLen = Math.floor(raw / nb), div = rsDiv(ecl), blocks = [];
    for (let i = 0, k = 0; i < nb; i++) {
      const d = data.slice(k, k + shortLen - ecl + (i < nShort ? 0 : 1)); k += d.length;
      const e = rsRem(d, div); if (i < nShort) d.push(0); blocks.push(d.concat(e));
    }
    const out = [];
    for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - ecl || j >= nShort) out.push(b[i]); });
    return { v, cw: out };
  }

  function penalty(m, n) {
    let p = 0;
    const line = get => { // runs + finder-like patterns along one line
      let run = 1;
      for (let i = 1; i <= n; i++) {
        if (i < n && get(i) === get(i - 1)) run++;
        else { if (run >= 5) p += 3 + run - 5; run = 1; }
      }
      for (let i = 0; i + 11 <= n; i++) {
        const s = Array.from({ length: 11 }, (_, k) => get(i + k) ? 1 : 0).join('');
        if (s === '10111010000' || s === '00001011101') p += 40;
      }
    };
    for (let y = 0; y < n; y++) line(x => m[y][x]);
    for (let x = 0; x < n; x++) line(y => m[y][x]);
    for (let y = 0; y < n - 1; y++) for (let x = 0; x < n - 1; x++) { const c = m[y][x]; if (c === m[y][x + 1] && c === m[y + 1][x] && c === m[y + 1][x + 1]) p += 3; }
    let dark = 0; m.forEach(r => r.forEach(c => { if (c) dark++; }));
    const total = n * n; p += Math.max(0, Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;
    return p;
  }

  function encode(text) {
    const { v, cw } = codewords(text);
    const n = v * 4 + 17;
    const m = [...Array(n)].map(() => Array(n).fill(false)), fn = [...Array(n)].map(() => Array(n).fill(false));
    const set = (x, y, d) => { m[y][x] = d; fn[y][x] = true; };
    for (let i = 0; i < n; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
    const finder = (cx, cy) => { for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) { const d = Math.max(Math.abs(dx), Math.abs(dy)), x = cx + dx, y = cy + dy; if (x >= 0 && x < n && y >= 0 && y < n) set(x, y, d !== 2 && d !== 4); } };
    finder(3, 3); finder(n - 4, 3); finder(3, n - 4);
    const al = ALIGN[v], L = al.length;
    for (let i = 0; i < L; i++) for (let j = 0; j < L; j++) {
      if ((i === 0 && j === 0) || (i === 0 && j === L - 1) || (i === L - 1 && j === 0)) continue;
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(al[i] + dx, al[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
    const drawFmt = mask => {
      const b = fmtBits(mask), g = i => ((b >>> i) & 1) === 1;
      for (let i = 0; i <= 5; i++) set(8, i, g(i));
      set(8, 7, g(6)); set(8, 8, g(7)); set(7, 8, g(8));
      for (let i = 9; i < 15; i++) set(14 - i, 8, g(i));
      for (let i = 0; i < 8; i++) set(n - 1 - i, 8, g(i));
      for (let i = 8; i < 15; i++) set(8, n - 15 + i, g(i));
      set(8, n - 8, true);
    };
    drawFmt(0);
    if (v >= 7) { const b = verBits(v); for (let i = 0; i < 18; i++) { const bit = ((b >>> i) & 1) === 1, a = n - 11 + i % 3, c = Math.floor(i / 3); set(a, c, bit); set(c, a, bit); } }
    let i = 0;
    for (let right = n - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let vert = 0; vert < n; vert++) for (let j = 0; j < 2; j++) {
        const x = right - j, up = ((right + 1) & 2) === 0, y = up ? n - 1 - vert : vert;
        if (!fn[y][x] && i < cw.length * 8) { m[y][x] = ((cw[i >>> 3] >>> (7 - (i & 7))) & 1) === 1; i++; }
      }
    }
    const MASK = [(x, y) => (x + y) % 2 === 0, (x, y) => y % 2 === 0, (x, y) => x % 3 === 0, (x, y) => (x + y) % 3 === 0,
      (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0, (x, y) => x * y % 2 + x * y % 3 === 0,
      (x, y) => (x * y % 2 + x * y % 3) % 2 === 0, (x, y) => ((x + y) % 2 + x * y % 3) % 2 === 0];
    const apply = k => { for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (!fn[y][x] && MASK[k](x, y)) m[y][x] = !m[y][x]; };
    let best = 0, bestP = Infinity;
    for (let k = 0; k < 8; k++) { apply(k); drawFmt(k); const p = penalty(m, n); if (p < bestP) { bestP = p; best = k; } apply(k); }
    apply(best); drawFmt(best);
    return m;
  }

  function svg(text, dark = '#111', light = '#fff') {
    const m = encode(text), n = m.length, q = 4, size = n + q * 2;
    let d = '';
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (m[y][x]) d += `M${x + q} ${y + q}h1v1h-1z`;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges"><rect width="${size}" height="${size}" fill="${light}"/><path d="${d}" fill="${dark}"/></svg>`;
  }

  return { encode, svg, _test: { rsDiv, rsRem, fmtBits, verBits, codewords } };
})();
if (typeof module !== 'undefined') module.exports = QR;
