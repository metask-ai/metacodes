// Capture host functions before user code runs. Host admission remains authoritative.
(() => {
  const request = globalThis.__mc_request;
  const log = globalThis.__mc_log;
  delete globalThis.__mc_request;
  delete globalThis.__mc_log;
  Object.defineProperty(globalThis, "tools", {
    value: new Proxy(Object.create(null), {
      get(_, name) {
        if (typeof name !== "string" || name === "then") return undefined;
        return async (args = {}) => request(name, args);
      }
    }),
    writable: false, configurable: false
  });
  Object.defineProperty(globalThis, "console", {
    value: Object.freeze({ log: (...args) => log(...args) }),
    writable: false, configurable: false
  });
})();
