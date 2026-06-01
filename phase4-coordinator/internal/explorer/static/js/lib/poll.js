const timers = new Map();

export function poll(name, ms, fn) {
  stop(name);
  const run = async () => {
    if (document.visibilityState === "visible") await fn();
    timers.set(name, setTimeout(run, ms));
  };
  run();
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
  }
});
