// Verification probe: register a right-click item in every context an extension
// can target. With the custom patch (ContextMenuMatcher::AppendExtensionItems ->
// early return) NONE of these should ever render.
const mk = (id, contexts, title) => chrome.contextMenus.create({ id, title, contexts });

function register() {
  chrome.contextMenus.removeAll(() => {
    mk("probe-page", ["page"], "TEST • page item");
    mk("probe-selection", ["selection"], "TEST • selection item");
    mk("probe-link", ["link"], "TEST • link item");
    mk("probe-image", ["image"], "TEST • image item");
    mk("probe-tab", ["tab"], "TEST • tab item");
    mk("probe-action", ["action"], "TEST • action item");
  });
}

chrome.runtime.onInstalled.addListener(register);
chrome.runtime.onStartup.addListener(register);
chrome.contextMenus.onClicked.addListener(() => {});
