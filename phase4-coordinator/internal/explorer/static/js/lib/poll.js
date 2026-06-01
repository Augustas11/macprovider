const timers = new Map();

// Schedule fn to run every ms. First run is DELAYED by ms (not immediate)
// so callers can call load() once themselves and then call poll() to schedule
// subsequent refreshes without triggering a second immediate load.
export function poll(name, ms, fn) {
  stop(name);
  const run = async () => {
    if (document.visibilityState === "visible") await fn();
    timers.set(name, setTimeout(run, ms));
  };
  timers.set(name, setTimeout(run, ms));
}

export function stop(name) {
  const id = timers.get(name);
  if (id) clearTimeout(id);
  timers.delete(name);
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") {
    for (const id of timers.values()) clearTimeout(id);
    timers.clear();
  } else {
    // Tab became visible again — timers were cleared on hide.
    // dashboard.js re-polls when visibility returns via its own listener.
  }
});
