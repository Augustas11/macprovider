export const REQUESTS_PER_MINUTE_CAP = 60;
const SESSION_KEY = "explorer_bearer";
let queue = Promise.resolve();
let stamps = [];

// Restore bearer from sessionStorage on load so it survives page refresh.
let bearer = sessionStorage.getItem(SESSION_KEY) || "";

export function token() {
  return bearer;
}

export function setToken(value) {
  bearer = value || "";
  if (bearer) {
    sessionStorage.setItem(SESSION_KEY, bearer);
  } else {
    sessionStorage.removeItem(SESSION_KEY);
  }
}

export function api(path) {
  queue = queue.catch(() => {}).then(async () => {
    const now = Date.now();
    stamps = stamps.filter((t) => now - t < 60000);
    if (stamps.length >= REQUESTS_PER_MINUTE_CAP) {
      console.warn("explorer request cap reached");
      throw new Error("request cap reached");
    }
    stamps.push(now);
    const res = await fetch(path, {headers: {Authorization: `Bearer ${token()}`}});
    if (res.status === 401) throw new Error("unauthorized — check bearer in Unlock field");
    if (!res.ok) throw new Error(`server error ${res.status}`);
    return res.json();
  });
  return queue;
}
