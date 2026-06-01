export const REQUESTS_PER_MINUTE_CAP = 60;
let queue = Promise.resolve();
let stamps = [];
let bearer = "";

export function token() {
  return bearer;
}

export function setToken(value) {
  bearer = value || "";
}

export function api(path) {
  queue = queue.then(async () => {
    const now = Date.now();
    stamps = stamps.filter((t) => now - t < 60000);
    if (stamps.length >= REQUESTS_PER_MINUTE_CAP) {
      console.warn("explorer request cap reached");
      throw new Error("request cap reached");
    }
    stamps.push(now);
    const res = await fetch(path, {headers: {Authorization: `Bearer ${token()}`}});
    if (res.status === 401) throw new Error("unauthorized");
    return res.json();
  });
  return queue;
}
