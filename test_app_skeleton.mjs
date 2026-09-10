import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("application skeleton provides a localized main page", async () => {
  const page = await readFile(new URL("./index.html", import.meta.url), "utf8");

  assert.match(page, /<html lang="zh-Hant">/);
  assert.match(page, /<title>記帳程式<\/title>/);
  assert.match(page, /<main>/);
  assert.match(page, /<h1>記帳程式<\/h1>/);
});
