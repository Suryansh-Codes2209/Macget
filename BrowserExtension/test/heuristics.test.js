// Tests for the extension's pure logic. Run with:
//   node --test BrowserExtension/test/
//
// Only heuristics.js is covered here — it is deliberately the only file with no
// browser API access, so it is the only one testable outside a browser. The
// surfaces that need a real browser (native messaging, popup, content script)
// have a manual QA matrix in BrowserExtension/README.md instead.

const test = require("node:test");
const assert = require("node:assert");
const h = require("../shared/heuristics.js");

test("hostnameOf", async (t) => {
  await t.test("extracts the host", () => {
    assert.strictEqual(h.hostnameOf("https://example.com/a/b?c=d"), "example.com");
  });
  await t.test("returns empty string for garbage rather than throwing", () => {
    assert.strictEqual(h.hostnameOf("not a url"), "");
    assert.strictEqual(h.hostnameOf(undefined), "");
    assert.strictEqual(h.hostnameOf(""), "");
  });
});

test("matchesHost", async (t) => {
  await t.test("matches the host exactly", () => {
    assert.ok(h.matchesHost("bit.ly", ["bit.ly"]));
  });
  await t.test("matches subdomains", () => {
    assert.ok(h.matchesHost("go.bit.ly", ["bit.ly"]));
    assert.ok(h.matchesHost("a.b.bit.ly", ["bit.ly"]));
  });
  await t.test("does NOT match a host that merely ends with the string", () => {
    // The bug a naive endsWith() would have: evil-bit.ly is a different domain.
    assert.ok(!h.matchesHost("evil-bit.ly", ["bit.ly"]));
    assert.ok(!h.matchesHost("notexample.com", ["example.com"]));
  });
  await t.test("is case insensitive and tolerates a leading dot in the list", () => {
    assert.ok(h.matchesHost("GO.BIT.LY", ["bit.ly"]));
    assert.ok(h.matchesHost("go.bit.ly", [".bit.ly"]));
  });
  await t.test("handles empty and malformed input", () => {
    assert.ok(!h.matchesHost("", ["bit.ly"]));
    assert.ok(!h.matchesHost("bit.ly", []));
    assert.ok(!h.matchesHost("bit.ly", null));
    assert.ok(!h.matchesHost("bit.ly", ["", null]));
  });
});

test("isCapturable", async (t) => {
  await t.test("accepts http and https", () => {
    assert.ok(h.isCapturable("http://example.com/f.zip"));
    assert.ok(h.isCapturable("https://example.com/f.zip"));
    assert.ok(h.isCapturable("HTTPS://example.com/f.zip"));
  });
  await t.test("rejects schemes Macget cannot re-fetch", () => {
    assert.ok(!h.isCapturable("blob:https://example.com/uuid"));
    assert.ok(!h.isCapturable("data:text/plain;base64,AAAA"));
    assert.ok(!h.isCapturable("chrome-extension://abc/f.zip"));
    assert.ok(!h.isCapturable("file:///tmp/f.zip"));
    assert.ok(!h.isCapturable(""));
    assert.ok(!h.isCapturable(undefined));
  });
});

test("looksLikeJumplink", async (t) => {
  await t.test("flags known shortener hosts", () => {
    assert.ok(h.looksLikeJumplink("https://bit.ly/xyz"));
    assert.ok(h.looksLikeJumplink("https://ouo.io/abc"));
  });
  await t.test("flags known ad/redirect networks", () => {
    assert.ok(h.looksLikeJumplink("https://ads.doubleclick.net/x"));
    assert.ok(h.looksLikeJumplink("https://popads.net/y"));
  });
  await t.test("flags redirect-shaped URLs", () => {
    assert.ok(h.looksLikeJumplink("https://example.com/out?url=https://evil.test/f.exe"));
    assert.ok(h.looksLikeJumplink("https://example.com/goto/123"));
    assert.ok(h.looksLikeJumplink("https://example.com/away?to=x"));
    assert.ok(h.looksLikeJumplink("https://example.com/x?redirect=y"));
  });
  await t.test("leaves ordinary download URLs alone", () => {
    // These are the false positives that would silently eat real downloads.
    assert.ok(!h.looksLikeJumplink("https://example.com/files/report.pdf"));
    assert.ok(!h.looksLikeJumplink("https://cdn.example.com/v1/video.mp4?token=abc"));
    assert.ok(!h.looksLikeJumplink("https://github.com/o/r/releases/download/v1/app.dmg"));
    assert.ok(!h.looksLikeJumplink("https://example.com/checkout/complete"));
  });
  await t.test("returns false for unparseable input", () => {
    assert.ok(!h.looksLikeJumplink("nonsense"));
    assert.ok(!h.looksLikeJumplink(undefined));
  });
});

test("isDenied", async (t) => {
  await t.test("blocks the host and its subdomains", () => {
    assert.ok(h.isDenied("mail.google.com", ["mail.google.com"]));
    assert.ok(h.isDenied("a.intranet.example.com", ["intranet.example.com"]));
  });
  await t.test("does not over-block neighbouring domains", () => {
    assert.ok(!h.isDenied("notgoogle.com", ["google.com"]));
    assert.ok(!h.isDenied("example.com", []));
    assert.ok(!h.isDenied("example.com", undefined));
  });
});

test("filenameFromUrl", async (t) => {
  await t.test("takes the last path segment", () => {
    assert.strictEqual(h.filenameFromUrl("https://example.com/a/b/report.pdf"), "report.pdf");
  });
  await t.test("ignores the query string", () => {
    assert.strictEqual(h.filenameFromUrl("https://example.com/v.mp4?token=abc"), "v.mp4");
  });
  await t.test("percent-decodes", () => {
    assert.strictEqual(h.filenameFromUrl("https://example.com/My%20File.zip"), "My File.zip");
  });
  await t.test("returns undefined when there is no usable segment", () => {
    // undefined, not "" — an empty filename would override Macget's own resolver.
    assert.strictEqual(h.filenameFromUrl("https://example.com/"), undefined);
    assert.strictEqual(h.filenameFromUrl("https://example.com"), undefined);
    assert.strictEqual(h.filenameFromUrl("garbage"), undefined);
  });
});

test("pushHistory", async (t) => {
  await t.test("prepends newest first", () => {
    const out = h.pushHistory([{ id: 1 }], { id: 2 }, 20);
    assert.deepStrictEqual(out.map((e) => e.id), [2, 1]);
  });
  await t.test("clamps to the cap, dropping the oldest", () => {
    let list = [];
    for (let i = 0; i < 30; i += 1) list = h.pushHistory(list, { id: i }, 20);
    assert.strictEqual(list.length, 20);
    assert.strictEqual(list[0].id, 29);
    assert.strictEqual(list[19].id, 10);
  });
  await t.test("does not mutate the input array", () => {
    const original = [{ id: 1 }];
    h.pushHistory(original, { id: 2 }, 20);
    assert.strictEqual(original.length, 1);
  });
  await t.test("tolerates a missing list and a bad cap", () => {
    assert.strictEqual(h.pushHistory(undefined, { id: 1 }, 20).length, 1);
    assert.strictEqual(h.pushHistory([], { id: 1 }, 0).length, 1);
    assert.strictEqual(h.pushHistory([], { id: 1 }, undefined).length, 1);
  });
});

test("formatBytes", async (t) => {
  await t.test("scales through the units", () => {
    assert.strictEqual(h.formatBytes(512), "512 B");
    assert.strictEqual(h.formatBytes(1024), "1 KB");
    assert.strictEqual(h.formatBytes(1536), "1.5 KB");
    assert.strictEqual(h.formatBytes(5 * 1024 * 1024), "5 MB");
    assert.strictEqual(h.formatBytes(3.2 * 1024 * 1024 * 1024), "3.2 GB");
  });
  await t.test("drops the decimal at three digits", () => {
    assert.strictEqual(h.formatBytes(950 * 1024), "950 KB");
  });
  await t.test("returns empty string for unknown sizes", () => {
    assert.strictEqual(h.formatBytes(0), "");
    assert.strictEqual(h.formatBytes(-1), "");
    assert.strictEqual(h.formatBytes(undefined), "");
    assert.strictEqual(h.formatBytes(NaN), "");
  });
});

test("relativeTime", async (t) => {
  const now = 1_000_000_000_000;
  const ago = (ms) => h.relativeTime(now - ms, now);

  await t.test("reports recent times as 'just now'", () => {
    assert.strictEqual(ago(0), "just now");
    assert.strictEqual(ago(30_000), "just now");
  });
  await t.test("scales through minutes, hours, days, weeks", () => {
    assert.strictEqual(ago(60_000), "1m ago");
    assert.strictEqual(ago(45 * 60_000), "45m ago");
    assert.strictEqual(ago(3 * 3_600_000), "3h ago");
    assert.strictEqual(ago(2 * 86_400_000), "2d ago");
    assert.strictEqual(ago(20 * 86_400_000), "2w ago");
  });
  await t.test("never reports a negative future time", () => {
    assert.strictEqual(h.relativeTime(now + 5000, now), "just now");
  });
});
