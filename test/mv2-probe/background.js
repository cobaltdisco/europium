// Blocking webRequest is the MV2 capability content blockers depend on and the
// one MV3 removed. Cancel exactly one URL so the smoke page can tell a working
// listener from a missing one.
chrome.webRequest.onBeforeRequest.addListener(
  (details) => ({ cancel: details.url.endsWith("/blockme.txt") }),
  { urls: ["<all_urls>"] },
  ["blocking"]
);
