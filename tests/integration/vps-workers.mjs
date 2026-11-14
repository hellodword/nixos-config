import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import path from "node:path";
import {pathToFileURL} from "node:url";
import test from "node:test";

const root = process.env.VPS_DIRECTORY;

test("certificate credentials remain at the Porkbun boundary", async () => {
  const dir = path.join(root, "workers/certificates");
  const worker = (await import(pathToFileURL(path.join(dir, "index.js")))).default;
  const env = JSON.parse(await readFile(path.join(dir, "secrets.json")));
  const metadata = JSON.parse(await readFile(path.join(root, "metadata.json")));
  const certificate = JSON.parse(await readFile(path.join(root, "nodes/edge", metadata.nodes.edge.release, "certificate.json")));
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url, options) => {
    calls++;
    assert.equal(url, "https://api.porkbun.com/api/json/v3/ssl/retrieve/example.com");
    assert.deepEqual(JSON.parse(options.body), {apikey: env.PORKBUN_API_KEY, secretapikey: env.PORKBUN_SECRET_KEY});
    return Response.json({status: "SUCCESS", certificatechain: "fixture-certificate", privatekey: "fixture-key"});
  };
  try {
    const request = new Request(certificate.url, {headers: {authorization: `Bearer ${certificate.token}`}});
    assert.deepEqual(await (await worker.fetch(request, env)).json(), {certificate: "fixture-certificate", key: "fixture-key"});
    env.ACCESS = "{}";
    assert.equal((await worker.fetch(request, env)).status, 401);
    assert.equal(calls, 1);
  } finally { globalThis.fetch = original; }
});
