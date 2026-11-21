// Opens the right-click menus of a running Europium through the macOS
// accessibility API and checks what is in them. Run by
// scripts/context-menu-test.sh, which starts the browser with the
// context-menu-probe extension and test/verify-page.html.
//
// The menus are native NSMenus, which the debugging protocol cannot see, so
// this is the only way to read them without a person looking at the screen.
//
// Checks, in order:
//   action  the probe's toolbar-icon menu DOES list "TEST • action item". The
//           patch keeps that menu on purpose, so this proves the probe
//           registered its items and that this tool can see extension items.
//   page, link, image, tab
//           none of these menus lists a probe item, reading mode or a QR code
//           entry, and each has at least a few built-in entries (so an empty
//           or unread menu cannot pass).
//
// usage: context-menu-check <pid of the browser>

import AppKit
import ApplicationServices

let probeMarker = "TEST •"                   // every item the probe registers starts with this
let probeName = "CtxMenu Probe"              // the submenu Chromium groups several items under
let pageTitle = "Right-click patch verification"
// The browser UI follows the system language; these cover English and Chinese.
// The toolbar button is matched by prefix: 158 calls it "Extensions", the 160
// snapshots "Extensions menu".
let extensionsButtonTitles = ["Extensions", "扩展程序"]
let removedEntries = ["reading mode", "阅读模式", "QR", "二维码"]

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]) else {
  print("usage: context-menu-check <pid>"); exit(2)
}
guard AXIsProcessTrusted() else {
  print("error: no Accessibility permission. Allow the app that runs this terminal under")
  print("       System Settings > Privacy & Security > Accessibility, then run again.")
  exit(2)
}

// The titles above only cover English and Simplified Chinese. In any other
// language a restored "reading mode" entry would go unnoticed, so refuse to run.
let language = Locale.preferredLanguages.first ?? ""
guard language.hasPrefix("en") || language.hasPrefix("zh-Hans") else {
  print("error: the system language is \(language); this check only knows the English and")
  print("       Simplified Chinese menu titles. Run it with one of those as the first language.")
  exit(2)
}

let app = AXUIElementCreateApplication(pid)
// Showing a menu blocks the browser's reply until the menu closes; a short
// timeout lets us carry on and read the menu while it is open.
AXUIElementSetMessagingTimeout(app, 2.0)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }
func role(_ element: AXUIElement) -> String { text(element, "AXRole") }
func title(_ element: AXUIElement) -> String { text(element, "AXTitle") }
func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, "AXChildren") as? [AXUIElement]) ?? [] }
func perform(_ element: AXUIElement, _ action: String) { _ = AXUIElementPerformAction(element, action as CFString) }

/// Depth-first search of the browser's accessibility tree, skipping the menu bar
/// (its menus would otherwise be mistaken for an open context menu).
func find(in root: AXUIElement? = nil, depth: Int = 0, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
  let element = root ?? app
  if matches(element) { return element }
  if depth > 40 { return nil }
  for child in children(element) where role(child) != "AXMenuBar" {
    if let found = find(in: child, depth: depth + 1, where: matches) { return found }
  }
  return nil
}

/// Polls until `body` returns a value or `seconds` pass.
func waitFor<T>(_ seconds: Double, _ body: () -> T?) -> T? {
  let deadline = Date().addingTimeInterval(seconds)
  repeat {
    if let value = body() { return value }
    usleep(200_000)
  } while Date() < deadline
  return nil
}

func openMenu() -> AXUIElement? { find { role($0) == "AXMenu" } }

/// Titles of every item in a menu, submenus included ("---" for separators).
func itemTitles(_ menu: AXUIElement, depth: Int = 0) -> [String] {
  var titles: [String] = []
  for child in children(menu) {
    if role(child) == "AXMenuItem" {
      let name = title(child)
      titles.append(String(repeating: "    ", count: depth) + (name.isEmpty ? "---" : name))
    }
    titles += itemTitles(child, depth: depth + 1)
  }
  return titles
}

func pressEscape() {
  for keyDown in [true, false] {
    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.postToPid(pid)
  }
}

/// Closes any open menu. False if one is still open afterwards.
/// Native menus close on AXCancel. The toolbar-icon menu is drawn by Chromium
/// itself and ignores it, so fall back to the Escape key.
func closeMenus() -> Bool {
  for _ in 0..<3 {
    guard let menu = openMenu() else { return true }
    perform(menu, "AXCancel")
    if waitFor(1, { openMenu() == nil ? true : nil }) != nil { return true }
    pressEscape()
    if waitFor(1, { openMenu() == nil ? true : nil }) != nil { return true }
  }
  return false
}

/// Performs `action` on `target`, reads the menu it opens, then closes the menu.
/// Nil if no menu opened, or if an earlier menu could not be closed first:
/// reading a menu left over from another element would check the wrong thing.
/// (The action's own result is not checked: it reports a timeout whenever the
/// browser is busy showing the menu, which is the normal case.)
func readMenu(_ target: AXUIElement, action: String) -> [String]? {
  guard closeMenus() else { return nil }
  perform(target, action)
  guard let menu = waitFor(5, openMenu) else { return nil }
  let titles = itemTitles(menu)
  guard closeMenus() else { return nil }
  return titles
}

var failures = 0
func report(_ surface: String, _ problem: String?, _ items: [String]) {
  if let problem = problem {
    failures += 1
    print("FAIL  \(surface): \(problem)")
    for item in items { print("        \(item)") }
  } else {
    print("ok    \(surface): \(items.filter { !$0.hasSuffix("---") }.count) entries")
  }
}

NSRunningApplication(processIdentifier: pid)?.activate()

// The page's heading shows up once the page has loaded and the renderer has
// published its accessibility tree.
guard waitFor(30, { find { role($0) == "AXHeading" && title($0) == pageTitle } }) != nil else {
  print("FAIL  the test page did not appear in the accessibility tree within 30s"); exit(1)
}

// --- action menu: the positive control -------------------------------------
// Extensions button -> the probe's "More options" button -> its menu. The
// probe registers its items when its service worker first runs, so retry.
func probeMoreButton() -> AXUIElement? { find { role($0) == "AXPopUpButton" && title($0).contains(probeName) } }
func actionMenu() -> [String]? {
  guard let extensions = find(where: { element in role(element) == "AXPopUpButton" && extensionsButtonTitles.contains { title(element).hasPrefix($0) } }) else { return nil }
  perform(extensions, "AXPress")   // opens the extensions bubble
  let items = waitFor(5, probeMoreButton).flatMap { readMenu($0, action: "AXPress") }
  if probeMoreButton() != nil {    // the bubble is still open: pressing again closes it
    perform(extensions, "AXPress")
    _ = waitFor(3) { probeMoreButton() == nil ? true : nil }
  }
  return items
}
var action: [String] = []
for _ in 0..<5 {
  action = actionMenu() ?? []
  if action.contains(where: { $0.contains(probeMarker) }) { break }
  sleep(1)
}
report("action", action.contains(where: { $0.contains(probeMarker) })
  ? nil : "the probe's own toolbar menu does not list its item, so the checks below would prove nothing", action)
if failures > 0 { exit(1) }

// --- menus that must stay free of extension items ---------------------------
let surfaces: [(name: String, target: (AXUIElement) -> Bool)] = [
  ("page", { role($0) == "AXHeading" && title($0) == pageTitle }),
  ("link", { role($0) == "AXLink" }),
  ("image", { role($0) == "AXImage" && text($0, "AXDescription") == "test" }),
  ("tab", { text($0, "AXSubrole") == "AXTabButton" && title($0).hasPrefix(pageTitle) }),
]
for surface in surfaces {
  guard let target = find(where: surface.target) else { report(surface.name, "could not find the element to right-click", []); continue }
  guard let items = readMenu(target, action: "AXShowMenu") else { report(surface.name, "no menu opened, or a menu could not be closed", []); continue }
  var problem: String?
  if items.contains(where: { $0.contains(probeMarker) || $0.contains(probeName) }) {
    problem = "an extension item is in the menu"
  } else if let entry = items.first(where: { item in removedEntries.contains { item.range(of: $0, options: .caseInsensitive) != nil } }) {
    problem = "'\(entry.trimmingCharacters(in: .whitespaces))' should have been removed"
  } else if items.filter({ !$0.hasSuffix("---") }).count < 3 {
    problem = "the menu is nearly empty, so it was probably not read correctly"
  }
  report(surface.name, problem, items)
}

exit(failures == 0 ? 0 : 1)
