// Behaviour guard for the managed StarUs star-count loader (KIT #277 / #278).
//
// Imports the REAL loader module passed as argv[2] (staged under a .mjs name
// by the Julia caller so both the template and the dogfooded copy are checked)
// and drives its load() through the transient-failure cases with an injected
// global.fetch and CI=true. Exits non-zero on any failure so
// test/docs_build.jl can assert on it.
//
// The regression this prevents: a future edit that reintroduces `throw` on a
// transient 5xx (the #277 flake, which failed every adopter's docs deploy over
// a decorative star count) makes case 3 / 5 / 6 fail here.
import {pathToFileURL} from "node:url";

const MAX_ATTEMPTS = 3;

process.env.CI = "true"; // the mode that used to hard-throw on any error
const realWarn = console.warn;
console.warn = () => {}; // silence the expected degradation warnings
// Collapse the retry backoff so the test does not actually sleep; the timing
// is not under test, only the retry count and the degrade/throw outcome.
globalThis.setTimeout = (fn) => {
  fn();
  return 0;
};

const {default: loader} = await import(pathToFileURL(process.argv[2]).href);

let pass = 0;
let fail = 0;
let calls = 0;
const check = (cond, msg) =>
  cond ? (pass++, console.log("  ok   " + msg))
       : (fail++, console.log("  FAIL " + msg));
const resp = (status, body = {}) =>
  ({ok: status >= 200 && status < 300, status, json: async () => body});

async function scenario(name, impl, assert) {
  calls = 0;
  globalThis.fetch = async (...a) => {
    calls++;
    return impl(calls, ...a);
  };
  console.log(name);
  await assert();
}

// 1. happy path -> the count, a single call.
await scenario(
  "1) happy",
  () => resp(200, {stargazers_count: 42}),
  async () => {
    const r = await loader.load();
    check(r === 42, `returns 42 (got ${r})`);
    check(calls === 1, `one call (got ${calls})`);
  }
);
// 2. genuine 404 (misconfigured REPO) -> throws, not retried.
await scenario("2) 404", () => resp(404), async () => {
  let status;
  try {
    await loader.load();
  } catch (e) {
    status = e.status;
  }
  check(status === 404, `throws with status 404 (got ${status})`);
  check(calls === 1, `404 not retried (got ${calls})`);
});
// 3. persistent 503 -> NaN after the retries; never fails the build.
await scenario("3) persistent 503", () => resp(503), async () => {
  const r = await loader.load();
  check(Number.isNaN(r), `NaN (got ${r})`);
  check(calls === MAX_ATTEMPTS, `retried to ${MAX_ATTEMPTS} (got ${calls})`);
});
// 4. 503 then 200 -> recovers to the count.
await scenario(
  "4) 503 then 200",
  (n) => (n === 1 ? resp(503) : resp(200, {stargazers_count: 7})),
  async () => {
    const r = await loader.load();
    check(r === 7, `recovers to 7 (got ${r})`);
    check(calls === 2, `two calls (got ${calls})`);
  }
);
// 5. network error (fetch rejects) -> NaN after the retries.
await scenario("5) network error", () => {
  throw new Error("ECONNRESET");
}, async () => {
  const r = await loader.load();
  check(Number.isNaN(r), `NaN (got ${r})`);
  check(calls === MAX_ATTEMPTS, `retried to ${MAX_ATTEMPTS} (got ${calls})`);
});
// 6. 429 rate limit -> NaN (transient).
await scenario("6) 429", () => resp(429), async () => {
  const r = await loader.load();
  check(Number.isNaN(r), `NaN (got ${r})`);
  check(calls === MAX_ATTEMPTS, `retried to ${MAX_ATTEMPTS} (got ${calls})`);
});

console.warn = realWarn;
console.log(`\n${pass} pass / ${fail} fail`);
process.exit(fail ? 1 : 0);
